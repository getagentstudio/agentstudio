import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct WorkspaceMutationCoordinatorTests {
    @Test
    func reactivatePane_failedInsert_keepsPaneBackgrounded() {
        let topologyAtom = RepositoryTopologyAtom()
        let paneAtom = WorkspacePaneAtom()
        let tabShellAtom = WorkspaceTabShellAtom()
        let tabArrangementAtom = WorkspaceTabArrangementAtom()
        let coordinator = WorkspaceMutationCoordinator(
            repositoryTopologyAtom: topologyAtom,
            workspacePaneAtom: paneAtom,
            workspaceTabShellAtom: tabShellAtom,
            workspaceTabArrangementAtom: tabArrangementAtom
        )

        let pane = makePane(residency: .backgrounded)
        paneAtom.addPane(pane)

        let didReactivate = coordinator.reactivatePane(
            pane.id,
            inTab: UUID(),
            at: UUID(),
            direction: .horizontal,
            position: .after, sizingMode: .halveTarget
        )

        #expect(!didReactivate)
        #expect(paneAtom.pane(pane.id)?.residency == .backgrounded)
        #expect(!tabArrangementAtom.allPaneIds.contains(pane.id))
    }

    @Test
    func restoreFromPaneSnapshot_failedLayoutInsertion_cleansUpRestoredPaneState() {
        let topologyAtom = RepositoryTopologyAtom()
        let paneAtom = WorkspacePaneAtom()
        let tabShellAtom = WorkspaceTabShellAtom()
        let tabArrangementAtom = WorkspaceTabArrangementAtom()
        let coordinator = WorkspaceMutationCoordinator(
            repositoryTopologyAtom: topologyAtom,
            workspacePaneAtom: paneAtom,
            workspaceTabShellAtom: tabShellAtom,
            workspaceTabArrangementAtom: tabArrangementAtom
        )

        let pane = makePane()
        let snapshot = WorkspaceMutationCoordinator.PaneCloseSnapshot(
            pane: pane,
            drawerChildPanes: [],
            tabId: UUID(),
            anchorPaneId: UUID(),
            direction: .horizontal
        )

        let result = coordinator.restoreFromPaneSnapshot(snapshot)

        #expect(
            result
                == .failedLayoutInsertion(
                    tabId: snapshot.tabId,
                    anchorPaneId: snapshot.anchorPaneId
                )
        )
        #expect(paneAtom.pane(pane.id) == nil)
    }

    @Test
    func restoreFromPaneSnapshot_failedDrawerParent_cleansUpRestoredDrawerPaneState() {
        let topologyAtom = RepositoryTopologyAtom()
        let paneAtom = WorkspacePaneAtom()
        let tabShellAtom = WorkspaceTabShellAtom()
        let tabArrangementAtom = WorkspaceTabArrangementAtom()
        let coordinator = WorkspaceMutationCoordinator(
            repositoryTopologyAtom: topologyAtom,
            workspacePaneAtom: paneAtom,
            workspaceTabShellAtom: tabShellAtom,
            workspaceTabArrangementAtom: tabArrangementAtom
        )

        let parentPaneId = UUID()
        let drawerPane = Pane(
            content: .terminal(
                TerminalState(
                    provider: .zmx,
                    lifetime: .persistent,
                    zmxSessionID: .generateUUIDv7()
                )
            ),
            metadata: PaneMetadata(title: "Drawer"),
            kind: .drawerChild(parentPaneId: parentPaneId)
        )
        let snapshot = WorkspaceMutationCoordinator.PaneCloseSnapshot(
            pane: drawerPane,
            drawerChildPanes: [],
            tabId: UUID(),
            anchorPaneId: parentPaneId,
            direction: .horizontal
        )

        let result = coordinator.restoreFromPaneSnapshot(snapshot)

        #expect(result == .failedMissingDrawerParent(parentPaneId))
        #expect(paneAtom.pane(drawerPane.id) == nil)
    }

    @Test
    func restoreDrawerPane_forcesDetachedPaneBackToDrawerChildKind() throws {
        let paneAtom = WorkspacePaneAtom()
        let parentPane = makePane(
            title: "Parent",
            facets: PaneContextFacets(cwd: URL(filePath: "/tmp/restore-drawer-parent"))
        )
        paneAtom.addPane(parentPane)
        let drawerPane = try #require(
            paneAtom.addDrawerPane(
                to: parentPane.id,
                parentFallbackCWD: nil,
                zmxSessionID: .generateUUIDv7()
            )
        )

        let detachedPane = try #require(paneAtom.detachDrawerPane(drawerPane.id, from: parentPane.id))
        guard case .layout(let detachedDrawer) = detachedPane.kind else {
            Issue.record("Expected detached drawer pane to become a layout pane")
            return
        }
        #expect(detachedDrawer.parentPaneId == drawerPane.id)

        #expect(paneAtom.restoreDrawerPane(detachedPane, to: parentPane.id))

        let restoredPane = try #require(paneAtom.pane(drawerPane.id))
        #expect(restoredPane.kind == .drawerChild(parentPaneId: parentPane.id))
        #expect(paneAtom.pane(parentPane.id)?.drawer?.paneIds == [drawerPane.id])
    }

    @Test
    func restoreFromPaneSnapshot_parentPaneRestoresDrawerViewsAndTabMembership() throws {
        let store = WorkspaceStore()
        let anchorPane = makePane(title: "Anchor")
        let parentPane = makePane(
            title: "Parent",
            facets: PaneContextFacets(cwd: URL(filePath: "/tmp/restore-parent-drawer-views"))
        )
        store.paneAtom.addPane(anchorPane)
        store.paneAtom.addPane(parentPane)

        let tab = Tab(paneId: anchorPane.id)
        store.appendTab(tab)
        #expect(
            store.insertPane(
                parentPane.id,
                inTab: tab.id,
                at: anchorPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        let firstDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let secondDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(store.pane(parentPane.id)?.drawer?.drawerId)
        store.setActiveDrawerPane(secondDrawerPane.id, in: parentPane.id)
        let focusArrangementId = try #require(store.createArrangement(name: "Drawer focus", inTab: tab.id))
        let untouchedArrangementId = try #require(store.createArrangement(name: "Untouched", inTab: tab.id))
        store.switchArrangement(to: focusArrangementId, inTab: tab.id)

        let snapshot = try #require(store.snapshotForPaneClose(paneId: parentPane.id, inTab: tab.id))
        let tabBeforeClose = try #require(store.tab(tab.id))
        let drawerViewsBeforeClose = tabBeforeClose.arrangements.compactMap {
            $0.drawerViews[drawerId]
        }

        #expect(store.mutationCoordinator.removePane(parentPane.id))
        let restoreResult = store.mutationCoordinator.restoreFromPaneSnapshot(snapshot)

        let restoredTab = try #require(store.tab(tab.id))
        #expect(restoreResult == .restored)
        #expect(restoredTab.allPaneIds.contains(parentPane.id))
        #expect(restoredTab.allPaneIds.contains(firstDrawerPane.id))
        #expect(restoredTab.allPaneIds.contains(secondDrawerPane.id))
        #expect(restoredTab.arrangements.contains { $0.id == untouchedArrangementId })
        #expect(
            restoredTab.arrangements.compactMap { $0.drawerViews[drawerId] }
                == drawerViewsBeforeClose
        )
    }

    @Test
    func snapshotForClose_withDrawerChildrenCapturesEachPaneExactlyOnce() throws {
        let store = WorkspaceStore()
        let parentPane = makePane(
            title: "Parent",
            facets: PaneContextFacets(cwd: URL(filePath: "/tmp/snapshot-drawer-children"))
        )
        store.paneAtom.addPane(parentPane)
        let tab = Tab(paneId: parentPane.id)
        store.appendTab(tab)
        let firstDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let secondDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))

        let snapshot = try #require(store.mutationCoordinator.snapshotForClose(tabId: tab.id))

        let snapshottedPaneIds = snapshot.panes.map(\.id)
        #expect(
            snapshottedPaneIds == [
                parentPane.id,
                firstDrawerPane.id,
                secondDrawerPane.id,
            ]
        )
        #expect(Set(snapshottedPaneIds).count == snapshottedPaneIds.count)
    }

    @Test
    func backgroundPane_retainsOwnedDrawerViewsInCanonicalTabGraph() throws {
        let store = WorkspaceStore()
        let anchorPane = makePane(title: "Anchor")
        let parentPane = makePane(
            title: "Parent",
            facets: PaneContextFacets(cwd: URL(filePath: "/tmp/background-parent-drawer"))
        )
        store.paneAtom.addPane(anchorPane)
        store.paneAtom.addPane(parentPane)
        let tab = Tab(paneId: anchorPane.id)
        store.appendTab(tab)
        #expect(
            store.insertPane(
                parentPane.id,
                inTab: tab.id,
                at: anchorPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        let drawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(store.pane(parentPane.id)?.drawer?.drawerId)

        #expect(store.mutationCoordinator.backgroundPane(parentPane.id))

        let backgroundedTab = try #require(store.tab(tab.id))
        #expect(
            backgroundedTab.allPaneIds
                == [anchorPane.id, parentPane.id, drawerPane.id]
        )
        #expect(
            backgroundedTab.arrangements.allSatisfy {
                $0.drawerViews[drawerId]?.layout.paneIds == [drawerPane.id]
            }
        )
        #expect(store.pane(parentPane.id)?.residency == .backgrounded)
        #expect(store.pane(drawerPane.id)?.residency == .backgrounded)
        #expect(store.pane(drawerPane.id)?.kind == .drawerChild(parentPaneId: parentPane.id))
        #expect(store.orphanedPanes.isEmpty)
    }

    @Test
    func backgroundPane_reactivatePane_restoresOwnedDrawerViewsAndChildMembership() throws {
        let store = WorkspaceStore()
        let anchorPane = makePane(title: "Anchor")
        let parentPane = makePane(
            title: "Parent",
            facets: PaneContextFacets(cwd: URL(filePath: "/tmp/reactivate-parent-drawer"))
        )
        store.paneAtom.addPane(anchorPane)
        store.paneAtom.addPane(parentPane)
        let tab = Tab(paneId: anchorPane.id)
        store.appendTab(tab)
        #expect(
            store.insertPane(
                parentPane.id,
                inTab: tab.id,
                at: anchorPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        let firstDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let secondDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(store.pane(parentPane.id)?.drawer?.drawerId)
        store.setActiveDrawerPane(secondDrawerPane.id, in: parentPane.id)
        let tabBeforeBackground = try #require(store.tab(tab.id))
        let drawerViewsBeforeBackground = Dictionary(
            uniqueKeysWithValues: tabBeforeBackground.arrangements.compactMap { arrangement in
                arrangement.drawerViews[drawerId].map { (arrangement.id, $0) }
            }
        )

        #expect(store.mutationCoordinator.backgroundPane(parentPane.id))
        #expect(
            store.mutationCoordinator.reactivatePane(
                parentPane.id,
                inTab: tab.id,
                at: anchorPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )

        let restoredTab = try #require(store.tab(tab.id))
        #expect(restoredTab.allPaneIds.count == Set(restoredTab.allPaneIds).count)
        #expect(restoredTab.allPaneIds.contains(parentPane.id))
        #expect(restoredTab.allPaneIds.contains(firstDrawerPane.id))
        #expect(restoredTab.allPaneIds.contains(secondDrawerPane.id))
        #expect(store.pane(parentPane.id)?.residency == .active)
        #expect(store.pane(firstDrawerPane.id)?.residency == .active)
        #expect(store.pane(secondDrawerPane.id)?.residency == .active)
        #expect(
            Dictionary(
                uniqueKeysWithValues: restoredTab.arrangements.compactMap { arrangement in
                    arrangement.drawerViews[drawerId].map { (arrangement.id, $0) }
                }
            ) == drawerViewsBeforeBackground
        )
    }
    @Test("restoring a captured tab clears unavailable context and preserves its pane and terminal")
    func restoreTabClearsUnavailableContext() throws {
        let topology = RepositoryTopologyAtom()
        let panes = WorkspacePaneAtom()
        let shells = WorkspaceTabShellAtom()
        let arrangements = WorkspaceTabArrangementAtom()
        let coordinator = WorkspaceMutationCoordinator(
            repositoryTopologyAtom: topology, workspacePaneAtom: panes,
            workspaceTabShellAtom: shells, workspaceTabArrangementAtom: arrangements
        )
        let repo = coordinator.addRepo(at: URL(fileURLWithPath: "/tmp/restored-unavailable-pane"))
        let worktree = try #require(repo.worktrees.first)
        let pane = makePane(facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path))
        let tab = Tab(paneId: pane.id)
        let snapshot = WorkspaceMutationCoordinator.TabCloseSnapshot(tab: tab, panes: [pane], tabIndex: 0)
        #expect(
            coordinator.recordRepositoryAbsence(
                repo.id,
                at: .init(utc: Date(timeIntervalSince1970: 1_700_000_000), bootID: "fixture", uptimeNanoseconds: 1)
            ))

        coordinator.restoreFromSnapshot(snapshot)

        let restored = try #require(panes.pane(pane.id))
        let facets = try #require(panes.graphAtom.paneState(pane.id)?.durableContextFacets)
        #expect(facets.repoId == nil)
        #expect(facets.worktreeId == nil)
        #expect(facets.cwd == worktree.path)
        #expect(restored.content == pane.content)
        #expect(restored.residency == pane.residency)
        #expect(restored.metadata.launchDirectory == pane.metadata.launchDirectory)
        #expect(arrangements.allPaneIds.contains(pane.id))
    }

    @Test(
        "a background drawer terminal creation preserves a drawer selection a human made after its capture"
    )
    func applyCommittedTerminalCreation_backgroundDrawerInsertion_preservesLiveDrawerSelection() throws {
        let store = WorkspaceStore(startsObserving: false)
        let anchorPane = makePane(title: "Anchor")
        let parentPane = makePane(
            title: "Parent",
            facets: PaneContextFacets(cwd: URL(filePath: "/tmp/f1-background-drawer-cursor-race"))
        )
        store.paneAtom.addPane(anchorPane)
        store.paneAtom.addPane(parentPane)
        let tab = Tab(paneId: anchorPane.id)
        store.appendTab(tab)
        #expect(
            store.insertPane(
                parentPane.id, inTab: tab.id, at: anchorPane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget
            )
        )

        let childA = try #require(store.addDrawerPane(to: parentPane.id))
        let childB = try #require(store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(store.pane(parentPane.id)?.drawer?.drawerId)
        store.setActiveDrawerPane(childA.id, in: parentPane.id)
        // `addDrawerPane` defaults to expanding the drawer; collapse it back so
        // the background creation below has a deterministic "not expanded" to
        // prove it leaves alone, matching `DrawerChildPresentation.background`.
        store.paneAtom.toggleDrawer(for: parentPane.id)
        #expect(store.pane(parentPane.id)?.drawer?.isExpanded == false)

        // Capture the tab exactly as `commitTerminalCreation` would before its
        // awaited off-main prepare and SQLite save: A selected, no C yet.
        let capturedTab = try #require(store.tab(tab.id))
        let capturedState = TabArrangementState(
            tabId: capturedTab.id, allPaneIds: capturedTab.allPaneIds,
            arrangements: capturedTab.arrangements, activeArrangementId: capturedTab.activeArrangementId
        )
        let childC = Pane(
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(title: "Drawer"),
            kind: .drawerChild(parentPaneId: parentPane.id)
        )
        // Build the published proposal's tab the same way production's
        // off-main composition does (`preparePlacementOffMain`): insert the
        // new child without selecting it, since this is a background creation.
        let insertedState = try #require(
            TabArrangementMutationRules.insertingNewDrawerPane(
                childC.id, in: capturedState,
                insertion: .init(
                    parentPaneId: parentPane.id, drawerId: drawerId, targetDrawerPaneId: nil,
                    direction: .right, sizingMode: .halveTarget, selectsInsertedChild: false
                )
            )
        )
        let publishedTab = Tab(
            id: capturedTab.id, name: capturedTab.name,
            allPaneIds: insertedState.allPaneIds, arrangements: insertedState.arrangements,
            activeArrangementId: insertedState.activeArrangementId, colorHex: capturedTab.colorHex
        )

        // The race: a human selects B in the drawer after the capture above,
        // while the background creation's save is still (hypothetically)
        // in flight.
        store.setActiveDrawerPane(childB.id, in: parentPane.id)

        let proposal = WorkspaceTerminalCreationProposal(
            bundle: .init(workspace: .init(id: UUIDv7.generate())),
            pane: childC, tab: publishedTab, associationOutcome: .freeNil,
            placement: .drawer(
                .init(
                    tabID: tab.id, parentID: parentPane.id, anchorID: nil,
                    direction: .right, sizingMode: .halveTarget,
                    childID: childC.id, presentation: .background
                ))
        )

        store.mutationCoordinator.applyCommittedTerminalCreation(proposal)

        let drawerView = try #require(store.drawerView(forParent: parentPane.id))
        #expect(drawerView.layout.contains(childC.id))
        #expect(store.pane(parentPane.id)?.drawer?.isExpanded == false)
        #expect(drawerView.activeChildId == childB.id)
    }

}
