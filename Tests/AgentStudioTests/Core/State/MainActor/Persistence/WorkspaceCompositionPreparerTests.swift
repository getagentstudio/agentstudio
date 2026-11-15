import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Workspace composition preparer")
struct WorkspaceCompositionPreparerTests {
    @Test("stale worktree metadata cannot discard composition panes")
    func staleWorktreeMetadataCannotDiscardCompositionPanes() async throws {
        // Arrange
        let staleWorktreeID = UUIDv7.generate()
        let storedText = "frozen-zmx-anchor"
        let zmxSessionID = try #require(ZmxSessionID(restoring: storedText))
        let pane = makeCompositionPane(
            worktreeID: staleWorktreeID,
            zmxSessionID: zmxSessionID
        )
        let tab = makeCompositionTab(paneID: pane.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Composition",
            panes: [pane],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        // This test deliberately crosses out of inherited MainActor isolation to prove the preparer is Sendable.
        // swiftlint:disable:next no_task_detached
        let result = await Task.detached {
            WorkspaceCompositionPreparer.prepare(snapshot)
        }.value

        // Assert
        let prepared = try requirePreparedComposition(result)
        #expect(prepared.panes.map(\.id) == [pane.id])
        #expect(prepared.panes[0].worktreeId == staleWorktreeID)
        #expect(prepared.panes[0].terminalState?.zmxSessionID.rawValue == storedText)
        #expect(prepared.paneGraph.replacement.paneStates[pane.id] != nil)
        #expect(prepared.tabs.map(\.id) == [tab.id])
        let activation = try #require(prepared.terminalActivationInput.entries.first)
        #expect(activation.paneID.uuid == pane.id)
        #expect(activation.pane == pane)
        #expect(activation.visibilityPriority == .activeVisible)
        #expect(activation.hostPlacement == .tab(tabID: tab.id))
        guard case .terminal(let terminalState) = activation.pane.content else {
            Issue.record("expected exact terminal pane content")
            return
        }
        #expect(terminalState.provider == .zmx)
        #expect(terminalState.zmxSessionID.rawValue == storedText)
        #expect(activation.pane.metadata.launchDirectory == URL(filePath: "/tmp/composition"))
        #expect(terminalState.lifetime == .persistent)
    }

    @Test("duplicate composition identities reject off-main before apply")
    func duplicateCompositionIdentitiesRejectOffMainBeforeApply() async {
        // Arrange
        let pane = makeCompositionPane()
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            panes: [pane, pane]
        )

        // Act
        // This test deliberately crosses out of inherited MainActor isolation to prove rejection is prepared off-main.
        // swiftlint:disable:next no_task_detached
        let result = await Task.detached {
            WorkspaceCompositionPreparer.prepare(snapshot)
        }.value

        // Assert
        #expect(result == .rejected(.duplicatePaneID(pane.id)))
    }

    @Test("missing drawer membership rejects instead of pruning composition")
    func missingDrawerMembershipRejectsInsteadOfPruningComposition() throws {
        // Arrange
        let firstPane = makeCompositionPane()
        let secondPane = makeCompositionPane()
        let missingPaneID = UUIDv7.generate()
        var parentPane = firstPane
        parentPane.withDrawer { drawer in
            drawer.paneIds = [secondPane.id, missingPaneID]
            drawer.isExpanded = true
        }
        let tab = makeCompositionTab(
            paneID: parentPane.id,
            allPaneIDs: [parentPane.id, secondPane.id, missingPaneID]
        )
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Projection",
            panes: [parentPane, secondPane],
            tabs: [tab],
            activeTabId: tab.id,
            sidebarWidth: 333
        )

        // Act
        let result = WorkspaceCompositionPreparer.prepare(snapshot)

        // Assert
        #expect(
            result
                == .rejected(
                    .drawerContainsMissingPane(
                        drawerID: try #require(parentPane.drawer?.drawerId),
                        paneID: missingPaneID
                    ))
        )
    }

    @Test("invalid active tab rejects instead of selecting fallback")
    func invalidActiveTabRejectsInsteadOfSelectingFallback() {
        // Arrange
        let pane = makeCompositionPane()
        let tab = makeCompositionTab(paneID: pane.id)
        let missingTabID = UUIDv7.generate()
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            panes: [pane],
            tabs: [tab],
            activeTabId: missingTabID
        )

        // Act
        let result = WorkspaceCompositionPreparer.prepare(snapshot)

        // Assert
        #expect(result == .rejected(.activeTabNotFound(missingTabID)))
    }

    @Test("inexact tab membership rejects instead of rebuilding membership")
    func inexactTabMembershipRejectsInsteadOfRebuildingMembership() {
        // Arrange
        let pane = makeCompositionPane()
        let unreferencedPane = makeCompositionPane()
        let tab = makeCompositionTab(
            paneID: pane.id,
            allPaneIDs: [pane.id, unreferencedPane.id]
        )
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            panes: [pane, unreferencedPane],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let result = WorkspaceCompositionPreparer.prepare(snapshot)

        // Assert
        #expect(
            result
                == .rejected(
                    .tabPaneMissingFromArrangements(
                        tabID: tab.id,
                        paneID: unreferencedPane.id
                    ))
        )
    }

    @Test("accepted composition preserves pane and tab values exactly")
    func acceptedCompositionPreservesPaneAndTabValuesExactly() throws {
        // Arrange
        let pane = makeCompositionPane()
        let tab = makeCompositionTab(paneID: pane.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Projection",
            panes: [pane],
            tabs: [tab],
            activeTabId: tab.id,
            sidebarWidth: 333
        )

        // Act
        let prepared = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(snapshot)
        )

        // Assert
        #expect(prepared.panes == snapshot.panes)
        #expect(prepared.tabs == snapshot.tabs)
        #expect(prepared.activeTabID == snapshot.activeTabId)
        #expect(prepared.identity.workspaceID == snapshot.id)
        #expect(prepared.windowMemory.sidebarWidth == 333)
    }

    @Test("recoverable unowned panes remain in pane graph without tab or mount composition")
    func recoverableUnownedPanesRemainInPaneGraphWithoutTabOrMountComposition() throws {
        // Arrange
        let ownedPane = makeCompositionPane(
            title: "Owned code viewer",
            content: .codeViewer(
                CodeViewerState(filePath: URL(filePath: "/tmp/composition-owned.swift"), scrollToLine: 1)
            )
        )
        let backgroundedPane = makeCompositionPane(
            title: "Backgrounded code viewer",
            content: .codeViewer(
                CodeViewerState(filePath: URL(filePath: "/tmp/composition-backgrounded.swift"), scrollToLine: 2)
            ),
            residency: .backgrounded
        )
        let orphanedPane = makeCompositionPane(
            title: "Orphaned code viewer",
            content: .codeViewer(
                CodeViewerState(filePath: URL(filePath: "/tmp/composition-orphaned.swift"), scrollToLine: 3)
            ),
            residency: .orphaned(
                reason: .worktreeNotFound(path: "/tmp/composition-orphaned-worktree")
            )
        )
        let tab = makeCompositionTab(paneID: ownedPane.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Recoverable pane pool",
            panes: [ownedPane, backgroundedPane, orphanedPane],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let prepared = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(snapshot)
        )

        // Assert
        #expect(Set(prepared.paneGraph.replacement.paneStates.keys) == Set(snapshot.panes.map(\.id)))
        #expect(prepared.tabGraph.tabIDByPaneID == [ownedPane.id: tab.id])
        #expect(prepared.terminalActivationInput.entries.isEmpty)
        #expect(prepared.nonterminalContentMountInput.entries.map(\.paneID.uuid) == [ownedPane.id])
    }

    @Test("recoverable unowned drawer cohorts remain dormant")
    func recoverableUnownedDrawerCohortsRemainDormant() throws {
        // Arrange
        let orphanedResidency = SessionResidency.orphaned(
            reason: .worktreeNotFound(path: "/tmp/composition-orphaned-drawer")
        )
        let cases:
            [(
                parentResidency: SessionResidency,
                childResidency: SessionResidency,
                shouldPrepare: Bool
            )] = [
                (.backgrounded, .backgrounded, true),
                (orphanedResidency, orphanedResidency, true),
                (.backgrounded, orphanedResidency, true),
                (.backgrounded, .active, false),
            ]

        for testCase in cases {
            let ownedPane = makeCompositionPane(title: "Owned terminal")
            var dormantParent = makeCompositionPane(
                title: "Dormant drawer parent",
                residency: testCase.parentResidency
            )
            var dormantChild = makeCompositionPane(
                title: "Dormant drawer child",
                residency: testCase.childResidency
            )
            dormantChild.kind = .drawerChild(parentPaneId: dormantParent.id)
            dormantParent.withDrawer { drawer in
                drawer.paneIds = [dormantChild.id]
            }
            let tab = makeCompositionTab(paneID: ownedPane.id)
            let snapshot = WorkspaceSQLiteSnapshot(
                id: UUIDv7.generate(),
                name: "Recoverable drawer cohort",
                panes: [ownedPane, dormantParent, dormantChild],
                tabs: [tab],
                activeTabId: tab.id
            )

            // Act
            let result = WorkspaceCompositionPreparer.prepare(snapshot)

            // Assert
            if testCase.shouldPrepare {
                let prepared = try requirePreparedComposition(result)
                #expect(Set(prepared.paneGraph.replacement.paneStates.keys) == Set(snapshot.panes.map(\.id)))
                #expect(prepared.tabGraph.tabIDByPaneID == [ownedPane.id: tab.id])
                #expect(prepared.terminalActivationInput.entries.map(\.paneID.uuid) == [ownedPane.id])
                #expect(prepared.nonterminalContentMountInput.entries.isEmpty)
            } else {
                #expect(result == .rejected(.paneNotOwnedByTab(dormantChild.id)))
            }
        }
    }

    @Test(
        "backgrounded canonical pane families remain durable and receive hidden terminal descriptors, excluded only from nonterminal mounts"
    )
    func backgroundedCanonicalPaneFamiliesRemainDurableAndReceiveHiddenTerminalDescriptors() throws {
        let activePane = makeCompositionPane(title: "Active terminal")
        var backgroundedParent = makeCompositionPane(
            title: "Backgrounded parent",
            residency: .backgrounded
        )
        var backgroundedChild = makeCompositionPane(
            title: "Backgrounded drawer child",
            residency: .backgrounded
        )
        backgroundedChild.kind = .drawerChild(parentPaneId: backgroundedParent.id)
        backgroundedParent.withDrawer { drawer in
            drawer.paneIds = [backgroundedChild.id]
            drawer.isExpanded = true
        }
        let drawerID = try #require(backgroundedParent.drawer?.drawerId)
        let mainLayout = Layout(paneId: activePane.id)
            .inserting(
                paneId: backgroundedParent.id,
                at: activePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )!
        let arrangement = PaneArrangement(
            id: UUIDv7.generate(),
            name: "Default",
            isDefault: true,
            layout: mainLayout,
            activePaneId: activePane.id,
            drawerViews: [
                drawerID: DrawerView(
                    layout: DrawerGridLayout(topRow: Layout(paneId: backgroundedChild.id)),
                    activeChildId: backgroundedChild.id
                )
            ]
        )
        let tab = Tab(
            id: UUIDv7.generate(),
            name: "Foreground tab",
            allPaneIds: [activePane.id, backgroundedParent.id, backgroundedChild.id],
            arrangements: [arrangement],
            activeArrangementId: arrangement.id
        )
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Retained background family",
            panes: [activePane, backgroundedParent, backgroundedChild],
            tabs: [tab],
            activeTabId: tab.id
        )

        let prepared = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(snapshot)
        )

        #expect(prepared.tabs == [tab])
        #expect(
            prepared.tabGraph.tabIDByPaneID == [
                activePane.id: tab.id,
                backgroundedParent.id: tab.id,
                backgroundedChild.id: tab.id,
            ])
        // SPEC R1: a residency-backgrounded terminal still receives a
        // descriptor — classified `.hidden`, sorted after the active one —
        // rather than being excluded outright.
        #expect(
            prepared.terminalActivationInput.entries.map(\.paneID.uuid) == [
                activePane.id, backgroundedParent.id, backgroundedChild.id,
            ]
        )
        #expect(
            prepared.terminalActivationInput.entries.map(\.visibilityPriority) == [
                .activeVisible, .hidden, .hidden,
            ]
        )
        #expect(prepared.nonterminalContentMountInput.entries.isEmpty)
    }

    @Test("residency-backgrounded terminals receive hidden descriptors rather than exclusion")
    func residencyBackgroundedTerminalsReceiveHiddenDescriptorsRatherThanExclusion() throws {
        // Arrange
        let backgroundedTerminal = makeCompositionPane(
            title: "Backgrounded terminal",
            residency: .backgrounded
        )
        let tab = makeCompositionTab(paneID: backgroundedTerminal.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Residency-backgrounded terminal",
            panes: [backgroundedTerminal],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let prepared = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(snapshot)
        )

        // Assert: strictly valid tab and resolved host placement are the only
        // requirements for terminal inclusion — residency only affects the
        // computed priority.
        #expect(prepared.terminalActivationInput.entries.map(\.paneID.uuid) == [backgroundedTerminal.id])
        #expect(prepared.terminalActivationInput.entries.first?.visibilityPriority == .hidden)
    }

    @Test("a drawer child of a backgrounded parent still receives a terminal descriptor")
    func aDrawerChildOfABackgroundedParentStillReceivesATerminalDescriptor() throws {
        // Arrange: the parent's own residency is backgrounded; the child's is
        // active. The removed guard used to exclude the child purely because
        // its parent was backgrounded — this isolates that specific claim
        // from the child's own residency (covered by the prior test).
        let activePane = makeCompositionPane(title: "Active terminal")
        var backgroundedParent = makeCompositionPane(
            title: "Backgrounded parent",
            residency: .backgrounded
        )
        var activeChild = makeCompositionPane(title: "Active drawer child")
        activeChild.kind = .drawerChild(parentPaneId: backgroundedParent.id)
        backgroundedParent.withDrawer { drawer in
            drawer.paneIds = [activeChild.id]
            drawer.isExpanded = true
        }
        let drawerID = try #require(backgroundedParent.drawer?.drawerId)
        let mainLayout = Layout(paneId: activePane.id)
            .inserting(
                paneId: backgroundedParent.id,
                at: activePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )!
        let arrangement = PaneArrangement(
            id: UUIDv7.generate(),
            name: "Default",
            isDefault: true,
            layout: mainLayout,
            activePaneId: activePane.id,
            drawerViews: [
                drawerID: DrawerView(
                    layout: DrawerGridLayout(topRow: Layout(paneId: activeChild.id)),
                    activeChildId: activeChild.id
                )
            ]
        )
        let tab = Tab(
            id: UUIDv7.generate(),
            name: "Foreground tab",
            allPaneIds: [activePane.id, backgroundedParent.id, activeChild.id],
            arrangements: [arrangement],
            activeArrangementId: arrangement.id
        )
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Backgrounded drawer parent, active child",
            panes: [activePane, backgroundedParent, activeChild],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let prepared = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(snapshot)
        )

        // Assert: the active child still receives a descriptor even though
        // its parent's residency is backgrounded — the parent-residency
        // guard no longer gates terminal inclusion.
        #expect(
            Set(prepared.terminalActivationInput.entries.map(\.paneID.uuid))
                == [activePane.id, backgroundedParent.id, activeChild.id]
        )
        let childEntry = try #require(
            prepared.terminalActivationInput.entries.first { $0.paneID.uuid == activeChild.id }
        )
        #expect(childEntry.visibilityPriority == .activeVisible)
    }

    @Test("nonterminal descriptors keep their active residency filter")
    func nonterminalDescriptorsKeepTheirActiveResidencyFilter() throws {
        // Arrange
        // A main-layout nonterminal pane; browsers live only in drawers.
        let backgroundedNonterminal = makeCompositionPane(
            title: "Backgrounded code viewer",
            content: .codeViewer(
                CodeViewerState(filePath: URL(filePath: "/tmp/backgrounded-nonterminal.swift"), scrollToLine: 4)
            ),
            residency: .backgrounded
        )
        let tab = makeCompositionTab(paneID: backgroundedNonterminal.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Residency-backgrounded nonterminal",
            panes: [backgroundedNonterminal],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let prepared = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(snapshot)
        )

        // Assert: unlike terminals, a backgrounded nonterminal pane is still
        // excluded outright — S7 narrows the residency guard to nonterminal
        // descriptors only, it does not remove it there.
        #expect(prepared.nonterminalContentMountInput.entries.isEmpty)
        #expect(prepared.terminalActivationInput.entries.isEmpty)
    }

    @Test("an unowned recoverable pane still receives no descriptor")
    func anUnownedRecoverablePaneStillReceivesNoDescriptor() throws {
        // Arrange: `backgroundedUnownedTerminal` is a terminal pane with no
        // tab membership at all — the new terminal-inclusion rule requires a
        // strictly valid tab, so removing the residency guard must not widen
        // inclusion to unowned panes.
        let ownedPane = makeCompositionPane(title: "Owned terminal")
        let backgroundedUnownedTerminal = makeCompositionPane(
            title: "Backgrounded unowned terminal",
            residency: .backgrounded
        )
        let tab = makeCompositionTab(paneID: ownedPane.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Unowned recoverable terminal",
            panes: [ownedPane, backgroundedUnownedTerminal],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let prepared = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(snapshot)
        )

        // Assert
        #expect(Set(prepared.paneGraph.replacement.paneStates.keys) == Set(snapshot.panes.map(\.id)))
        #expect(prepared.tabGraph.tabIDByPaneID == [ownedPane.id: tab.id])
        #expect(prepared.terminalActivationInput.entries.map(\.paneID.uuid) == [ownedPane.id])
    }

    @Test("a strictly invalid composition is still rejected before any descriptor exists")
    func aStrictlyInvalidCompositionIsStillRejectedBeforeAnyDescriptorExists() throws {
        // Arrange: an active-residency terminal pane with no tab membership
        // is not "recoverable" (recoverable requires backgrounded/orphaned
        // residency) — this must still reject during validation, before
        // `makePreparedContentInputs` ever runs, regardless of the
        // descriptor-inclusion rule change.
        let ownedPane = makeCompositionPane(title: "Owned terminal")
        let activeUnownedTerminal = makeCompositionPane(title: "Active unowned terminal")
        let tab = makeCompositionTab(paneID: ownedPane.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Invalid active unowned terminal",
            panes: [ownedPane, activeUnownedTerminal],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let result = WorkspaceCompositionPreparer.prepare(snapshot)

        // Assert
        #expect(result == .rejected(.paneNotOwnedByTab(activeUnownedTerminal.id)))
    }

    @Test("unowned drawer child rejects when its parent remains owned")
    func unownedDrawerChildRejectsWhenParentRemainsOwned() throws {
        // Arrange
        var ownedParent = makeCompositionPane(title: "Owned drawer parent")
        var detachedChild = makeCompositionPane(
            title: "Detached drawer child",
            residency: .backgrounded
        )
        detachedChild.kind = .drawerChild(parentPaneId: ownedParent.id)
        ownedParent.withDrawer { drawer in
            drawer.paneIds = [detachedChild.id]
        }
        let tab = makeCompositionTab(paneID: ownedParent.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Detached drawer child",
            panes: [ownedParent, detachedChild],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let result = WorkspaceCompositionPreparer.prepare(snapshot)

        // Assert
        #expect(result == .rejected(.paneNotOwnedByTab(detachedChild.id)))
    }

    @Test("active unowned pane rejects instead of entering recoverable pane pool")
    func activeUnownedPaneRejectsInsteadOfEnteringRecoverablePanePool() throws {
        // Arrange
        let ownedPane = makeCompositionPane()
        let activeUnownedPane = makeCompositionPane()
        let tab = makeCompositionTab(paneID: ownedPane.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Invalid active pane pool",
            panes: [ownedPane, activeUnownedPane],
            tabs: [tab],
            activeTabId: tab.id
        )

        // Act
        let result = WorkspaceCompositionPreparer.prepare(snapshot)

        // Assert
        #expect(result == .rejected(.paneNotOwnedByTab(activeUnownedPane.id)))
    }

    @Test("prepared content inputs exhaustively partition canonically owned panes in stable priority order")
    func preparedContentInputsExhaustivelyPartitionPanesInStablePriorityOrder() throws {
        // Arrange
        let fixture = try makePreparedContentPartitionFixture()

        // Act
        let firstPreparation = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(fixture.snapshot)
        )
        let repeatedPreparation = try requirePreparedComposition(
            WorkspaceCompositionPreparer.prepare(fixture.snapshot)
        )

        // Assert
        let terminalEntries = firstPreparation.terminalActivationInput.entries
        let nonterminalEntries = firstPreparation.nonterminalContentMountInput.entries
        let terminalPaneIDs = terminalEntries.map(\.paneID.uuid)
        let nonterminalPaneIDs = nonterminalEntries.map(\.paneID.uuid)
        #expect(terminalPaneIDs == [fixture.activeTerminal.id, fixture.hiddenTerminal.id])
        #expect(
            nonterminalPaneIDs == [
                fixture.visibleTabContent.id,
                fixture.hiddenBridge.id,
                fixture.hiddenCodeViewer.id,
                fixture.hiddenUnsupported.id,
            ]
        )
        #expect(Set(terminalPaneIDs).isDisjoint(with: Set(nonterminalPaneIDs)))
        #expect(Set(terminalPaneIDs + nonterminalPaneIDs) == Set(fixture.snapshot.panes.map(\.id)))
        #expect(terminalEntries.map(\.pane) == [fixture.activeTerminal, fixture.hiddenTerminal])
        #expect(firstPreparation.terminalActivationInput == repeatedPreparation.terminalActivationInput)
        #expect(firstPreparation.nonterminalContentMountInput == repeatedPreparation.nonterminalContentMountInput)

        let webviewEntry = try #require(nonterminalEntries.first)
        guard case .codeViewer(let acceptedWebviewPane) = webviewEntry.content else {
            Issue.record("expected first nonterminal entry to preserve the visible tab member's content")
            return
        }
        #expect(acceptedWebviewPane == fixture.visibleTabContent)
        #expect(webviewEntry.visibilityPriority == .visible)
        #expect(webviewEntry.hostPlacement == .tab(tabID: fixture.activeTab.id))

        guard case .bridgePanel(let acceptedBridgePane) = nonterminalEntries[1].content else {
            Issue.record("expected bridge content")
            return
        }
        #expect(acceptedBridgePane == fixture.hiddenBridge)
        guard case .codeViewer(let acceptedCodeViewerPane) = nonterminalEntries[2].content else {
            Issue.record("expected code-viewer content")
            return
        }
        #expect(acceptedCodeViewerPane == fixture.hiddenCodeViewer)
        guard case .unsupported(let acceptedUnsupportedPane) = nonterminalEntries[3].content else {
            Issue.record("expected unsupported content")
            return
        }
        #expect(acceptedUnsupportedPane == fixture.hiddenUnsupported)
        #expect(nonterminalEntries.dropFirst().allSatisfy { $0.visibilityPriority == .hidden })
    }
}

private enum WorkspaceCompositionPreparerTestError: Error {
    case preparationRejected(WorkspaceCompositionPreparationRejection)
}

private struct PreparedContentPartitionFixture {
    let snapshot: WorkspaceSQLiteSnapshot
    let activeTab: Tab
    let activeTerminal: Pane
    let hiddenTerminal: Pane
    let visibleTabContent: Pane
    let hiddenCodeViewer: Pane
    let hiddenBridge: Pane
    let hiddenUnsupported: Pane
}

private func makePreparedContentPartitionFixture() throws -> PreparedContentPartitionFixture {
    let activeTerminal = makeCompositionPane(title: "Active terminal")
    let hiddenTerminal = makeCompositionPane(title: "Hidden terminal")
    // Browsers live only in drawers, so the visible tab member is a code viewer.
    let visibleTabContent = makeCompositionPane(
        title: "Visible code viewer",
        content: .codeViewer(
            CodeViewerState(filePath: URL(filePath: "/tmp/prepared-visible.swift"), scrollToLine: 5)
        )
    )
    let hiddenCodeViewer = makeCompositionPane(
        title: "Hidden code viewer",
        content: .codeViewer(
            CodeViewerState(
                filePath: URL(filePath: "/tmp/prepared-content.swift"),
                scrollToLine: 42
            )
        )
    )
    let hiddenBridge = makeCompositionPane(
        title: "Hidden bridge",
        content: .bridgePanel(
            BridgePaneState(
                panelKind: .diffViewer,
                source: .commit(sha: "prepared-content")
            )
        )
    )
    let hiddenUnsupported = makeCompositionPane(
        title: "Hidden unsupported",
        content: .unsupported(
            UnsupportedContent(
                type: "future-prepared-content",
                version: 7,
                rawState: .object(["preserved": .bool(true)])
            )
        )
    )
    let activeTab = makeCompositionTab(
        paneIDs: [activeTerminal.id, visibleTabContent.id],
        activePaneID: activeTerminal.id
    )
    let hiddenTab = makeCompositionTab(
        paneIDs: [hiddenTerminal.id, hiddenCodeViewer.id, hiddenBridge.id, hiddenUnsupported.id],
        activePaneID: hiddenTerminal.id
    )
    let panes = [
        hiddenBridge,
        hiddenTerminal,
        hiddenCodeViewer,
        activeTerminal,
        hiddenUnsupported,
        visibleTabContent,
    ]
    return PreparedContentPartitionFixture(
        snapshot: WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Prepared content partition",
            panes: panes,
            tabs: [hiddenTab, activeTab],
            activeTabId: activeTab.id
        ),
        activeTab: activeTab,
        activeTerminal: activeTerminal,
        hiddenTerminal: hiddenTerminal,
        visibleTabContent: visibleTabContent,
        hiddenCodeViewer: hiddenCodeViewer,
        hiddenBridge: hiddenBridge,
        hiddenUnsupported: hiddenUnsupported
    )
}

private func requirePreparedComposition(
    _ result: WorkspaceCompositionPreparationResult
) throws -> PreparedWorkspaceComposition {
    switch result {
    case .prepared(let prepared):
        return prepared
    case .rejected(let rejection):
        throw WorkspaceCompositionPreparerTestError.preparationRejected(rejection)
    }
}

private func makeCompositionPane(
    id: UUID = UUIDv7.generate(),
    title: String = "Terminal",
    worktreeID: UUID? = nil,
    zmxSessionID: ZmxSessionID = .generateUUIDv7(),
    content: PaneContent? = nil,
    residency: SessionResidency = .active
) -> Pane {
    let resolvedContent =
        content
        ?? .terminal(
            TerminalState(
                provider: .zmx,
                lifetime: .persistent,
                zmxSessionID: zmxSessionID
            ))
    return Pane(
        id: id,
        content: resolvedContent,
        metadata: PaneMetadata(
            launchDirectory: URL(filePath: "/tmp/composition"),
            title: title,
            facets: PaneContextFacets(worktreeId: worktreeID)
        ),
        residency: residency
    )
}

private func makeCompositionTab(
    paneID: UUID,
    allPaneIDs: [UUID]? = nil
) -> Tab {
    let arrangement = PaneArrangement(
        id: UUIDv7.generate(),
        name: "Default",
        isDefault: true,
        layout: Layout(paneId: paneID),
        activePaneId: paneID
    )
    return Tab(
        id: UUIDv7.generate(),
        name: "Tab",
        allPaneIds: allPaneIDs ?? [paneID],
        arrangements: [arrangement],
        activeArrangementId: arrangement.id
    )
}

private func makeCompositionTab(
    paneIDs: [UUID],
    activePaneID: UUID
) -> Tab {
    let arrangement = PaneArrangement(
        id: UUIDv7.generate(),
        name: "Default",
        isDefault: true,
        layout: Layout.autoTiled(paneIDs),
        activePaneId: activePaneID
    )
    return Tab(
        id: UUIDv7.generate(),
        name: "Tab",
        allPaneIds: paneIDs,
        arrangements: [arrangement],
        activeArrangementId: arrangement.id
    )
}
