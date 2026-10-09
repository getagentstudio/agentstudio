import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneTabViewControllerZoomCommandTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("targeted Zoom enters Zoom on the target tab's active durable pane")
    func targetedZoomUsesTargetTabActivePane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let targetFirstPane = harness.store.createPane()
        let targetActivePane = harness.store.createPane()
        let sourceTab = Tab(paneId: sourcePane.id)
        let targetTab = Tab(paneId: targetFirstPane.id)
        harness.store.appendTab(sourceTab)
        harness.store.appendTab(targetTab)
        harness.store.insertPane(
            targetActivePane.id,
            inTab: targetTab.id,
            at: targetFirstPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.store.setActivePane(targetActivePane.id, inTab: targetTab.id)
        harness.store.setActiveTab(sourceTab.id)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try attachPaneHost(paneId: targetActivePane.id, in: harness, to: window)
        await harness.executeCommand(.zoomPane, target: targetActivePane.id, targetType: .pane)

        #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id) == nil)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: targetTab.id)?.sourcePaneId
                == targetActivePane.id
        )
        #expect(harness.store.activeTabId == targetTab.id)
    }

    @Test("Arrangement-panel Zoom toggle cancels the active Zoom source instead of retargeting")
    func arrangementPanelZoomToggleCancelsActiveZoom() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let durableActivePane = harness.store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)
        harness.store.insertPane(
            durableActivePane.id,
            inTab: tab.id,
            at: sourcePane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durableActivePane.id, inTab: tab.id)
        enterZoom(in: tab, sourcePaneId: sourcePane.id, harness: harness)

        harness.controller.handleArrangementPanelZoomToggle(
            tabId: tab.id,
            sourcePaneId: nil
        )
        _ = await harness.executor.submitGesture { _ in true }.value

        #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id) == nil)
        #expect(harness.store.tab(tab.id)?.activePaneId == durableActivePane.id)
    }

    @Test("untargeted Zoom enters and cancels without changing durable arrangement state")
    func untargetedZoomEntersAndCancelsWithoutDurableMutation() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane()
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(pane.id, inTab: tab.id)
        let durableArrangementId = try #require(harness.store.tab(tab.id)?.activeArrangementId)
        let durableActivePaneId = try #require(harness.store.tab(tab.id)?.activePaneId)

        #expect(harness.controller.canExecute(.zoomPane))
        await harness.executeCommand(.zoomPane)

        let enteredPresentation = try #require(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)
        )
        #expect(enteredPresentation.sourcePaneId == pane.id)
        #expect(enteredPresentation.viewerPresentation == .unavailable)
        #expect(harness.store.tab(tab.id)?.activeArrangementId == durableArrangementId)
        #expect(harness.store.tab(tab.id)?.activePaneId == durableActivePaneId)

        await harness.executeCommand(.zoomPane)

        #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id) == nil)
        #expect(harness.store.tab(tab.id)?.activeArrangementId == durableArrangementId)
        #expect(harness.store.tab(tab.id)?.activePaneId == durableActivePaneId)
    }

    @Test("Worktree Viewer outside watched worktrees enters Zoom and toggles its unavailable surface")
    func worktreeViewerShowsUnavailableSurfaceOutsideWatchedWorktrees() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane(
            launchDirectory: harness.tempDir.appending(path: "unwatched")
        )
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(sourcePane.id, inTab: tab.id)

        #expect(harness.controller.canExecute(.showViewer))
        await harness.executeCommand(.showViewer)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?
                .viewerPresentation == .unavailableVisible
        )

        await harness.executeCommand(.showViewer)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?
                .viewerPresentation == .unavailable
        )
    }

    @Test("Zoom reattaches a minimized terminal source without expanding its durable arrangement")
    func zoomReattachesMinimizedTerminalSource() async throws {
        // Mutation caught: Zoom enters presentation state without reattaching the hidden terminal surface.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let visiblePane = harness.store.createPane()
        let minimizedPane = harness.store.createPane()
        let tab = Tab(paneId: visiblePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                minimizedPane.id,
                inTab: tab.id,
                at: visiblePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        #expect(harness.store.minimizePane(minimizedPane.id, inTab: tab.id))
        harness.store.setActiveTab(tab.id)
        let surfaceId = UUID()
        let terminalView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(),
            restoredSurfaceId: surfaceId,
            paneId: minimizedPane.id
        )
        let paneHost = PaneHostView(paneId: minimizedPane.id)
        paneHost.mountContentView(terminalView)
        harness.viewRegistry.register(paneHost, for: minimizedPane.id)

        await harness.executeCommand(
            .zoomPane,
            target: minimizedPane.id,
            targetType: .pane
        )

        #expect(
            harness.surfaceManager.attachedSurfaceRequests.contains {
                $0.surfaceId == surfaceId && $0.paneId == minimizedPane.id
            }
        )
        #expect(harness.store.tab(tab.id)?.activeMinimizedPaneIds.contains(minimizedPane.id) == true)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?.sourcePaneId
                == minimizedPane.id
        )
    }

    @Test("Zoom Viewer does not replace a missing explicit worktree with an unrelated sole worktree")
    func zoomViewerRejectsUnrelatedSoleWorktreeFallback() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let (sourceRepo, sourceWorktree) = makeRepoAndWorktree(
            harness.store,
            root: harness.tempDir
        )
        let (_, unrelatedWorktree) = makeRepoAndWorktree(
            harness.store,
            root: harness.tempDir
        )
        let sourcePane = makeWorktreePane(in: harness, worktree: sourceWorktree)
        let sourceTab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(sourceTab)
        harness.store.setActiveTab(sourceTab.id)
        harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
        harness.store.reconcileDiscoveredWorktrees(sourceRepo.id, worktrees: [])

        await harness.executeCommand(.zoomPane)

        #expect(harness.store.repositoryTopologyAtom.worktree(sourceWorktree.id) == nil)
        #expect(harness.store.repositoryTopologyAtom.worktree(unrelatedWorktree.id) != nil)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                .viewerPresentation == .unavailable
        )
    }

    @Test("Zoom Viewer renders unavailable for a dangling association without CWD recovery")
    func zoomViewerDoesNotRecoverDanglingAssociationFromCWD() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let (staleRepo, staleWorktree) = makeRepoAndWorktree(
            harness.store,
            root: harness.tempDir
        )
        let (_, replacementWorktree) = makeRepoAndWorktree(
            harness.store,
            root: harness.tempDir
        )
        let sourcePane = Pane(
            id: PaneId.generateUUIDv7().uuid,
            content: .terminal(
                TerminalState(
                    provider: .zmx,
                    lifetime: .persistent,
                    zmxSessionID: .generateUUIDv7()
                )
            ),
            metadata: PaneMetadata(
                launchDirectory: replacementWorktree.path,
                title: "Dangling",
                facets: PaneContextFacets(
                    repoId: staleRepo.id,
                    worktreeId: staleWorktree.id,
                    cwd: replacementWorktree.path
                )
            )
        )
        #expect(harness.store.paneAtom.insertRestoredPane(sourcePane))
        let sourceTab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(sourceTab)
        harness.store.setActiveTab(sourceTab.id)
        harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
        harness.store.reconcileDiscoveredWorktrees(staleRepo.id, worktrees: [])

        #expect(harness.store.repositoryTopologyAtom.worktree(staleWorktree.id) == nil)
        await harness.executeCommand(.zoomPane, target: sourcePane.id, targetType: .pane)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                .viewerPresentation == .unavailable
        )
    }

    @Test("same-tab explicit Zoom retargets, then an equal target cancels")
    func explicitSameTabZoomRetargetsThenCancels() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let firstPane = harness.store.createPane()
        let secondPane = harness.store.createPane()
        let tab = Tab(paneId: firstPane.id)
        harness.store.appendTab(tab)
        harness.store.insertPane(
            secondPane.id,
            inTab: tab.id,
            at: firstPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(firstPane.id, inTab: tab.id)
        await harness.executeCommand(.zoomPane)
        let durableActivePaneId = try #require(harness.store.tab(tab.id)?.activePaneId)

        #expect(harness.controller.canExecute(.zoomPane, target: secondPane.id, targetType: .pane))
        await harness.executeCommand(.zoomPane, target: secondPane.id, targetType: .pane)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?.sourcePaneId
                == secondPane.id
        )
        #expect(harness.store.tab(tab.id)?.activePaneId == durableActivePaneId)

        await harness.executeCommand(.zoomPane, target: secondPane.id, targetType: .pane)

        #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id) == nil)
        #expect(harness.store.tab(tab.id)?.activePaneId == durableActivePaneId)
    }

    @Test("cross-tab explicit Zoom preserves source Zoom and enters, resumes, or retargets destination")
    func explicitCrossTabZoomPreservesSourceAndResolvesDestination() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let destinationFirstPane = harness.store.createPane()
        let destinationSecondPane = harness.store.createPane()
        let sourceTab = Tab(paneId: sourcePane.id)
        let destinationTab = Tab(paneId: destinationFirstPane.id)
        harness.store.appendTab(sourceTab)
        harness.store.appendTab(destinationTab)
        harness.store.insertPane(
            destinationSecondPane.id,
            inTab: destinationTab.id,
            at: destinationFirstPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.store.setActiveTab(sourceTab.id)
        harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
        await harness.executeCommand(.zoomPane)
        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try attachPaneHost(paneId: destinationFirstPane.id, in: harness, to: window)
        try attachPaneHost(paneId: destinationSecondPane.id, in: harness, to: window)

        await harness.executeCommand(.zoomPane, target: destinationFirstPane.id, targetType: .pane)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?.sourcePaneId == sourcePane.id)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: destinationTab.id)?.sourcePaneId
                == destinationFirstPane.id
        )
        #expect(harness.store.activeTabId == destinationTab.id)

        harness.store.setActiveTab(sourceTab.id)
        await harness.executeCommand(.zoomPane, target: destinationFirstPane.id, targetType: .pane)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: destinationTab.id)?.sourcePaneId
                == destinationFirstPane.id
        )
        #expect(harness.store.activeTabId == destinationTab.id)

        harness.store.setActiveTab(sourceTab.id)
        await harness.executeCommand(.zoomPane, target: destinationSecondPane.id, targetType: .pane)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: destinationTab.id)?.sourcePaneId
                == destinationSecondPane.id
        )
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?.sourcePaneId == sourcePane.id)
        #expect(harness.store.activeTabId == destinationTab.id)
        #expect(harness.store.tab(destinationTab.id)?.activePaneId == destinationSecondPane.id)
    }

    @Test("Zoom rejects drawer children and is unavailable without a durable main-pane target")
    func zoomRejectsDrawerChildrenAndMissingTargets() throws {
        let emptyHarness = makeHarness()
        defer { try? FileManager.default.removeItem(at: emptyHarness.tempDir) }
        #expect(!emptyHarness.controller.canExecute(.zoomPane))
        emptyHarness.controller.execute(.zoomPane)
        #expect(emptyHarness.store.panePresentationAtom.zoomPresentationsByTabId.isEmpty)

        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let parentPane = harness.store.createPane()
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

        #expect(!harness.controller.canExecute(.zoomPane, target: drawerPane.id, targetType: .pane))
        harness.controller.execute(.zoomPane, target: drawerPane.id, targetType: .pane)

        #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id) == nil)
    }

    @Test("Webview panes reject Zoom for untargeted, shortcut, explicit pane, and IPC-targeted capability")
    func webviewPanesRejectZoomAcrossCommandSurfaces() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let webviewPane = harness.store.createPane(
            content: .webview(
                WebviewState(url: URL(string: "https://example.com/browser-zoom")!)
            ),
            metadata: PaneMetadata(contentType: .browser, title: "Browser")
        )
        let tab = Tab(paneId: webviewPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(webviewPane.id, inTab: tab.id)

        #expect(!harness.controller.canExecute(.zoomPane))
        #expect(!harness.controller.canExecute(.zoomPane, target: webviewPane.id, targetType: .pane))

        harness.controller.execute(.zoomPane)
        harness.controller.execute(.zoomPane, target: webviewPane.id, targetType: .pane)

        #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id) == nil)
    }

    @Test("Bridge, code viewer, and unsupported panes reject Zoom across command surfaces")
    func nonTerminalPanesRejectZoomAcrossCommandSurfaces() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let panes = [
            harness.store.createPane(
                content: .bridgePanel(BridgePaneState(panelKind: .diffViewer, source: nil)),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Review",
                    facets: PaneContextFacets(cwd: harness.tempDir)
                )
            ),
            harness.store.createPane(
                content: .codeViewer(
                    CodeViewerState(filePath: URL(filePath: "/tmp/zoom-source.swift"), scrollToLine: nil)
                ),
                metadata: PaneMetadata(contentType: .codeViewer, title: "Source")
            ),
            harness.store.createPane(
                content: .unsupported(UnsupportedContent(type: "future", version: 1, rawState: nil)),
                metadata: PaneMetadata(contentType: .terminal, title: "Unsupported")
            ),
        ]

        for pane in panes {
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(pane.id, inTab: tab.id)

            #expect(!harness.controller.canExecute(.zoomPane))
            #expect(!harness.controller.canExecute(.zoomPane, target: pane.id, targetType: .pane))
            harness.controller.execute(.zoomPane)
            harness.controller.execute(.zoomPane, target: pane.id, targetType: .pane)
            #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id) == nil)
        }
    }

    @Test("Zoom rejects main-pane creation while preserving source Drawer creation")
    func zoomRejectsMainPaneCreationAndAllowsSourceDrawerCreation() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        try await withWorkspaceCommandHarness(harness) {
            let pane = harness.store.createPane()
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(pane.id, inTab: tab.id)
            enterZoom(in: tab, sourcePaneId: pane.id, viewerPresentation: .unavailable, harness: harness)
            let durablePaneIdsBefore = Set(try #require(harness.store.tab(tab.id)).activePaneIds)
            let tabIdsBefore = harness.store.tabs.map(\.id)

            #expect(!harness.controller.canExecute(.newTerminalInTab))
            #expect(!harness.controller.canExecute(.openWebview))
            #expect(harness.controller.canExecute(.addDrawerPane))

            harness.controller.execute(.newTerminalInTab)
            harness.controller.execute(.openWebview)
            harness.controller.execute(.addDrawerPane)
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(harness.store.tabs.map(\.id) == tabIdsBefore)
            #expect(Set(try #require(harness.store.tab(tab.id)).activePaneIds) == durablePaneIdsBefore)

            let drawer = try #require(harness.store.pane(pane.id)?.drawer)
            #expect(drawer.paneIds.count == 1)
            let drawerPaneId = try #require(drawer.paneIds.first)
            #expect(drawer.isExpanded)
            #expect(harness.store.pane(drawerPaneId) != nil)
            #expect(harness.store.tabs.allSatisfy { !$0.activePaneIds.contains(drawerPaneId) })
        }
    }

    @Test("Zoom-local Viewer toggles only the retained source companion")
    func zoomLocalViewerTogglesRetainedSourceCompanion() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(sourcePane.id, inTab: tab.id)
        let companion = ZoomCompanionMetadata(
            owningTabId: tab.id,
            resolvedWorktreeId: UUID(),
            companionPaneId: UUID(),
            lastZoomVisibility: .visible
        )
        harness.store.panePresentationAtom.cacheZoomCompanion(
            companion,
            forSourcePane: sourcePane.id
        )
        harness.store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: sourcePane.id,
            viewerPresentation: .retainedVisible(companionPaneId: companion.companionPaneId)
        )

        await harness.executeCommand(.showViewer)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?.viewerPresentation
                == .retainedHidden(companionPaneId: companion.companionPaneId)
        )
        #expect(
            harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?.lastZoomVisibility
                == .hidden
        )

        await harness.executeCommand(.showViewer, target: sourcePane.id, targetType: .pane)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?.viewerPresentation
                == .retainedVisible(companionPaneId: companion.companionPaneId)
        )
        #expect(
            harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?.lastZoomVisibility
                == .visible
        )
    }

    @Test("explicit pane Viewer rejects targets other than the active Zoom source")
    func explicitPaneViewerRejectsNonSourceTargets() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let (_, sourceWorktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let (_, destinationWorktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let sourcePane = makeWorktreePane(in: harness, worktree: sourceWorktree)
        let destinationPane = makeWorktreePane(in: harness, worktree: destinationWorktree)
        let sourceTab = Tab(paneId: sourcePane.id)
        let destinationTab = Tab(paneId: destinationPane.id)
        harness.store.appendTab(sourceTab)
        harness.store.appendTab(destinationTab)
        enterZoom(in: sourceTab, sourcePaneId: sourcePane.id, harness: harness)
        enterZoom(in: destinationTab, sourcePaneId: destinationPane.id, harness: harness)
        harness.store.setActiveTab(sourceTab.id)
        harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
        let durablePaneIdsBefore = harness.store.paneAtom.graphAtom.paneIDs

        #expect(!harness.controller.canExecute(.showViewer, target: destinationPane.id, targetType: .pane))
        harness.controller.execute(.showViewer, target: destinationPane.id, targetType: .pane)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?.sourcePaneId
                == sourcePane.id
        )
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: destinationTab.id)?.sourcePaneId
                == destinationPane.id
        )
        #expect(harness.store.activeTabId == sourceTab.id)
        #expect(harness.store.tab(destinationTab.id)?.activePaneId == destinationPane.id)
        #expect(harness.store.paneAtom.graphAtom.paneIDs == durablePaneIdsBefore)
    }

    @Test("Viewer rejects explicit worktree targets")
    func viewerRejectsExplicitWorktreeTargets() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let sourcePane = makeWorktreePane(in: harness, worktree: worktree)
        let sourceTab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(sourceTab)
        let companion = ZoomCompanionMetadata(
            owningTabId: sourceTab.id,
            resolvedWorktreeId: worktree.id,
            companionPaneId: UUID(),
            lastZoomVisibility: .visible
        )
        harness.store.panePresentationAtom.cacheZoomCompanion(companion, forSourcePane: sourcePane.id)
        enterZoom(
            in: sourceTab,
            sourcePaneId: sourcePane.id,
            viewerPresentation: .retainedVisible(companionPaneId: companion.companionPaneId),
            harness: harness
        )
        harness.store.setActiveTab(sourceTab.id)
        harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
        let paneIdsBefore = harness.store.paneAtom.graphAtom.paneIDs
        let tabIdsBefore = Set(harness.store.tabs.map(\.id))

        #expect(!harness.controller.canExecute(.showViewer, target: worktree.id, targetType: .worktree))
        harness.controller.execute(.showViewer, target: worktree.id, targetType: .worktree)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?.viewerPresentation
                == .retainedVisible(companionPaneId: companion.companionPaneId)
        )
        #expect(harness.store.activeTabId == sourceTab.id)
        #expect(harness.store.paneAtom.graphAtom.paneIDs == paneIdsBefore)
        #expect(Set(harness.store.tabs.map(\.id)) == tabIdsBefore)
        #expect(
            harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?.companionPaneId
                == companion.companionPaneId
        )
    }

    @Test("untargeted Viewer enters Zoom and ensures the Viewer is visible")
    func untargetedViewerEntersZoomAndEnsuresViewerIsVisible() async throws {
        let activePaneHarness = makeHarness()
        defer { try? FileManager.default.removeItem(at: activePaneHarness.tempDir) }
        _ = makeRepoAndWorktree(activePaneHarness.store, root: activePaneHarness.tempDir)
        let (_, activeWorktree) = makeRepoAndWorktree(activePaneHarness.store, root: activePaneHarness.tempDir)
        let activePane = makeWorktreePane(in: activePaneHarness, worktree: activeWorktree)
        let activeTab = Tab(paneId: activePane.id)
        activePaneHarness.store.appendTab(activeTab)
        activePaneHarness.store.setActiveTab(activeTab.id)
        activePaneHarness.store.setActivePane(activePane.id, inTab: activeTab.id)

        #expect(activePaneHarness.controller.canExecute(.showViewer))
        await activePaneHarness.executeCommand(.showViewer)

        let presentation = try #require(
            activePaneHarness.store.panePresentationAtom.zoomPresentation(forTab: activeTab.id)
        )
        #expect(presentation.sourcePaneId == activePane.id)
        guard case .retainedVisible = presentation.viewerPresentation else {
            Issue.record("Viewer command did not make the Zoom Viewer visible")
            return
        }
    }

    @Test("Zoom companion metadata never becomes a durable Viewer reuse candidate")
    func zoomCompanionIsExcludedFromDurableViewerReuse() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let sourcePane = makeWorktreePane(in: harness, worktree: worktree)
        let sourceTab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(sourceTab)
        harness.store.setActiveTab(sourceTab.id)
        harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
        let companion = ZoomCompanionMetadata(
            owningTabId: sourceTab.id,
            resolvedWorktreeId: worktree.id,
            companionPaneId: UUID(),
            lastZoomVisibility: .visible
        )
        harness.store.panePresentationAtom.cacheZoomCompanion(companion, forSourcePane: sourcePane.id)

        let target = try #require(harness.controller.bridgePaneCommandTarget(worktreeId: worktree.id))

        #expect(target.resolution == .create)
        #expect(harness.store.paneAtom.pane(companion.companionPaneId) == nil)
        #expect(harness.store.tabContaining(paneId: companion.companionPaneId) == nil)
    }

    @Test("targeted arrangement traversal activates its tab, preserves Zoom, and traverses durable layouts")
    func targetedArrangementTraversalActivatesTargetAndPreservesZoom() async throws {
        // Mutation caught: targeted arrangement commands fall through instead of applying to their explicit tab.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        try await withWorkspaceCommandHarness(harness) {
            let sourcePane = harness.store.createPane()
            let targetPane = harness.store.createPane()
            let sourceTab = Tab(paneId: sourcePane.id)
            let targetTab = Tab(paneId: targetPane.id)
            harness.store.appendTab(sourceTab)
            harness.store.appendTab(targetTab)
            let targetDefaultArrangementId = targetTab.activeArrangementId
            let targetUserArrangementId = try #require(
                harness.store.createArrangement(name: "Layout 2", inTab: targetTab.id)
            )
            enterZoom(in: sourceTab, sourcePaneId: sourcePane.id, harness: harness)
            enterZoom(in: targetTab, sourcePaneId: targetPane.id, harness: harness)
            harness.store.setActiveTab(sourceTab.id)

            #expect(
                harness.controller.canExecute(
                    .nextArrangement,
                    target: targetTab.id,
                    targetType: .tab
                )
            )
            harness.controller.execute(
                .nextArrangement,
                target: targetTab.id,
                targetType: .tab
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(harness.store.activeTabId == targetTab.id)
            #expect(harness.store.tab(targetTab.id)?.activeArrangementId == targetDefaultArrangementId)
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: targetTab.id)?.sourcePaneId
                    == targetPane.id
            )
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?.sourcePaneId
                    == sourcePane.id
            )

            #expect(
                harness.controller.canExecute(
                    .previousArrangement,
                    target: targetTab.id,
                    targetType: .tab
                )
            )
            harness.controller.execute(
                .previousArrangement,
                target: targetTab.id,
                targetType: .tab
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(harness.store.tab(targetTab.id)?.activeArrangementId == targetUserArrangementId)
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: targetTab.id)?.sourcePaneId
                    == targetPane.id
            )
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?.sourcePaneId
                    == sourcePane.id
            )
        }
    }

    @Test("targeted arrangement traversal rejects stale and wrong-kind targets")
    func targetedArrangementTraversalRejectsInvalidTargets() {
        // Mutation caught: target metadata is trusted without validating tab identity and target kind.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane()
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let activeArrangementId = tab.activeArrangementId

        #expect(
            !harness.controller.canExecute(
                .nextArrangement,
                target: UUID(),
                targetType: .tab
            )
        )
        #expect(
            !harness.controller.canExecute(
                .nextArrangement,
                target: tab.id,
                targetType: .pane
            )
        )
        harness.controller.execute(
            .nextArrangement,
            target: pane.id,
            targetType: .pane
        )

        #expect(harness.store.activeTabId == tab.id)
        #expect(harness.store.tab(tab.id)?.activeArrangementId == activeArrangementId)
    }

    @Test("rejected Review request preserves a reused durable Viewer")
    func rejectedReviewRequestPreservesReusedDurableViewer() async throws {
        var requestedPaneIds: [UUID] = []
        let harness = makeHarness(
            bridgeViewerSurfaceRequestHandler: { surface, paneId in
                #expect(surface == .review)
                requestedPaneIds.append(paneId)
                return false
            }
        )
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let sourcePane = makeWorktreePane(in: harness, worktree: worktree)
        let durableViewerPane = makeDurableViewerPane(in: harness, worktree: worktree)
        let sourceTab = Tab(paneId: sourcePane.id)
        let durableViewerTab = Tab(paneId: durableViewerPane.id)
        harness.store.appendTab(sourceTab)
        harness.store.appendTab(durableViewerTab)
        harness.store.setActiveTab(sourceTab.id)
        harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        _ = try attachPaneHost(
            paneId: durableViewerPane.id,
            in: harness,
            to: window,
            mountedContent: FocusablePaneTabCommandMountedContentView()
        )
        window.makeKeyAndOrderFront(nil)
        let paneIdsBefore = harness.store.paneAtom.graphAtom.paneIDs
        let tabIdsBefore = Set(harness.store.tabLayoutAtom.tabs.map(\.id))

        await harness.executeCommand(.showBridgeReview, target: worktree.id, targetType: .worktree)

        #expect(requestedPaneIds == [durableViewerPane.id])
        #expect(harness.store.paneAtom.graphAtom.paneIDs == paneIdsBefore)
        #expect(Set(harness.store.tabLayoutAtom.tabs.map(\.id)) == tabIdsBefore)
        #expect(harness.store.paneAtom.pane(durableViewerPane.id) != nil)
        #expect(harness.store.tabContaining(paneId: durableViewerPane.id)?.id == durableViewerTab.id)
        #expect(harness.store.activeTabId == durableViewerTab.id)
        #expect(harness.store.tab(durableViewerTab.id)?.activePaneId == durableViewerPane.id)
    }

    @Test("reusing a durable Viewer preserves active Pane Zoom")
    func reusedDurableViewerPreservesActivePaneZoom() async throws {
        let harness = makeHarness(
            bridgeViewerSurfaceRequestHandler: { _, _ in true }
        )
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let initiatingPane = makeWorktreePane(in: harness, worktree: worktree)
        let zoomSourcePane = makeWorktreePane(in: harness, worktree: worktree)
        let durableViewerPane = makeDurableViewerPane(in: harness, worktree: worktree)
        let initiatingTab = Tab(paneId: initiatingPane.id)
        let zoomTab = Tab(paneId: zoomSourcePane.id)
        harness.store.appendTab(initiatingTab)
        harness.store.appendTab(zoomTab)
        #expect(
            harness.store.insertPane(
                durableViewerPane.id,
                inTab: zoomTab.id,
                at: zoomSourcePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        enterZoom(in: zoomTab, sourcePaneId: zoomSourcePane.id, harness: harness)
        harness.store.setActiveTab(initiatingTab.id)
        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        _ = try attachPaneHost(
            paneId: durableViewerPane.id,
            in: harness,
            to: window,
            mountedContent: FocusablePaneTabCommandMountedContentView()
        )
        window.makeKeyAndOrderFront(nil)

        await harness.executeCommand(.showBridgeFiles, target: worktree.id, targetType: .worktree)

        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: zoomTab.id)?
                .sourcePaneId == zoomSourcePane.id
        )
    }
}

@MainActor
private func makeWorktreePane(
    in harness: PaneTabViewControllerCommandHarness,
    worktree: Worktree
) -> Pane {
    harness.store.createPane(
        launchDirectory: worktree.path,
        facets: PaneContextFacets(
            repoId: worktree.repoId,
            worktreeId: worktree.id,
            cwd: worktree.path
        )
    )
}

@MainActor
private func makeDurableViewerPane(
    in harness: PaneTabViewControllerCommandHarness,
    worktree: Worktree
) -> Pane {
    harness.store.createPane(
        content: .bridgePanel(
            BridgePaneState(
                panelKind: .diffViewer,
                source: nil
            )
        ),
        metadata: PaneMetadata(
            contentType: .diff,
            title: "Durable Viewer",
            facets: PaneContextFacets(
                repoId: worktree.repoId,
                worktreeId: worktree.id,
                cwd: worktree.path
            )
        )
    )
}

@MainActor
private func enterZoom(
    in tab: Tab,
    sourcePaneId: UUID,
    viewerPresentation: ZoomViewerPresentation = .retryable,
    harness: PaneTabViewControllerCommandHarness
) {
    harness.store.panePresentationAtom.enterZoom(
        inTab: tab.id,
        sourcePaneId: sourcePaneId,
        viewerPresentation: viewerPresentation
    )
}
