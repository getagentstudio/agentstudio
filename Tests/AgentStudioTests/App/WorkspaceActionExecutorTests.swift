import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
final class WorkspaceActionExecutorTests {

    private var store: WorkspaceStore!
    private var viewRegistry: ViewRegistry!
    private var coordinator: WorkspaceSurfaceCoordinator!
    private var runtime: SessionRuntime!
    private var executor: WorkspaceActionExecutor!
    private var tempDir: URL!

    init() throws {
        installTestCoreAtomsIfNeeded()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "executor-tests-\(UUID().uuidString)")
        store = try makeWorkspaceJournalTestStore()
        viewRegistry = ViewRegistry()
        runtime = SessionRuntime(store: store)
        coordinator = {
            let fixtureSurfaceManager = makeAppTerminalFixtureSurfaceManager()
            return WorkspaceSurfaceCoordinator(
                store: store, viewRegistry: viewRegistry, runtime: runtime,
                surfaceManager: fixtureSurfaceManager, terminalSurfaceCommandDispatcher: fixtureSurfaceManager,
                terminalSurfaceOperations: fixtureSurfaceManager.makeTerminalPaneSurfaceOperations(),
                runtimeRegistry: RuntimeRegistry(),
                windowLifecycleStore: WindowLifecycleAtom(),
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
        }()
        executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
    }

    deinit {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        executor = nil
        coordinator = nil
        runtime = nil
        viewRegistry = nil
        store = nil
    }

    // MARK: - Execute: selectTab

    @Test
    func test_execute_selectTab_setsActiveTab() async throws {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)
        store.setActiveTab(tab1.id)

        // Act
        await executor.execute(.selectTab(tabId: tab2.id))

        // Assert
        #expect(store.activeTabId == tab2.id)
    }

    // MARK: - Execute: closeTab

    @Test
    func test_execute_closeTab_removesTab() async throws {
        // Arrange
        let p1 = store.createPane()
        let tab = Tab(paneId: p1.id)
        store.appendTab(tab)
        #expect(store.tabs.count == 1)

        // Act
        await executor.execute(.closeTab(tabId: tab.id))

        // Assert
        #expect(store.tabs.isEmpty)
    }

    @Test
    func test_execute_closeTab_pushesToUndoStack() async throws {
        // Arrange
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)

        // Act
        await executor.execute(.closeTab(tabId: tab.id))

        // Assert
        #expect(executor.undoStack.count == 1)
        if case .tab(let snapshot) = executor.undoStack[0] {
            #expect(snapshot.tab.id == tab.id)
        } else {
            Issue.record("Expected .tab entry")
        }
    }

    @Test
    func test_execute_closeTab_multipleCloses_stacksUndo() async throws {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        // Act
        await executor.execute(.closeTab(tabId: tab1.id))
        await executor.execute(.closeTab(tabId: tab2.id))

        // Assert
        #expect(executor.undoStack.count == 2)
        if case .tab(let s1) = executor.undoStack[0] {
            #expect(s1.tab.id == tab1.id)
        } else {
            Issue.record("Expected .tab entry at index 0")
        }
        if case .tab(let s2) = executor.undoStack[1] {
            #expect(s2.tab.id == tab2.id)
        } else {
            Issue.record("Expected .tab entry at index 1")
        }
    }

    // MARK: - Undo Close Tab

    @Test
    func test_undoCloseTab_restoresTab() async throws {
        // Arrange
        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://undo.example")!)),
            metadata: PaneMetadata(title: "Undoable")
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        await executor.execute(.closeTab(tabId: tab.id))
        #expect(store.tabs.isEmpty)

        // Act
        await executor.undoCloseTab()

        // Assert
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].id == tab.id)
        #expect(executor.undoStack.isEmpty)
    }

    @Test
    func test_undoCloseTab_emptyStack_noOp() async throws {
        // Act — should not crash
        await executor.undoCloseTab()

        // Assert
        #expect(executor.undoStack.isEmpty)
    }

    // MARK: - Execute: breakUpTab

    @Test
    func test_execute_breakUpTab_splitsIntoIndividualTabs() async throws {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let layout = Layout(paneId: p1.id)
            .inserting(paneId: p2.id, at: p1.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)!
        let arrangement = PaneArrangement(
            name: "Default",
            isDefault: true,
            layout: layout
        )
        let tab = Tab(
            panes: layout.paneIds,
            arrangements: [arrangement],
            activeArrangementId: arrangement.id,
            activePaneId: p1.id
        )
        store.appendTab(tab)

        // Act
        await executor.execute(.breakUpTab(tabId: tab.id))

        // Assert
        #expect(store.tabs.count == 2)
        #expect(store.tabs[0].paneIds == [p1.id])
        #expect(store.tabs[1].paneIds == [p2.id])
    }

    @Test
    func test_execute_breakUpTab_namesNewTabsFromPaneContext() async throws {
        let p1 = store.createPane(title: "Left")
        let p2 = store.createPane(title: "Right")
        let layout = Layout(paneId: p1.id)
            .inserting(paneId: p2.id, at: p1.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)!
        let arrangement = PaneArrangement(
            name: "Default",
            isDefault: true,
            layout: layout
        )
        let tab = Tab(
            panes: layout.paneIds,
            arrangements: [arrangement],
            activeArrangementId: arrangement.id,
            activePaneId: p1.id
        )
        store.appendTab(tab)

        await executor.execute(.breakUpTab(tabId: tab.id))

        #expect(store.tabs.count == 2)
        #expect(store.tabs[0].name == "Left")
        #expect(store.tabs[1].name == "Right")
    }

    // MARK: - Execute: extractPaneToTab

    @Test
    func test_execute_extractPaneToTab_createsNewTab() async throws {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let layout = Layout(paneId: p1.id)
            .inserting(paneId: p2.id, at: p1.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)!
        let arrangement = PaneArrangement(
            name: "Default",
            isDefault: true,
            layout: layout
        )
        let tab = Tab(
            panes: layout.paneIds,
            arrangements: [arrangement],
            activeArrangementId: arrangement.id,
            activePaneId: p1.id
        )
        store.appendTab(tab)

        // Act
        await executor.execute(.extractPaneToTab(tabId: tab.id, paneId: p2.id))

        // Assert
        #expect(store.tabs.count == 2)
    }

    @Test
    func test_execute_extractPaneToTab_namesNewTabFromExtractedPane() async throws {
        let p1 = store.createPane(title: "First")
        let p2 = store.createPane(title: "Second")
        let layout = Layout(paneId: p1.id)
            .inserting(paneId: p2.id, at: p1.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)!
        let arrangement = PaneArrangement(
            name: "Default",
            isDefault: true,
            layout: layout
        )
        let tab = Tab(
            panes: layout.paneIds,
            arrangements: [arrangement],
            activeArrangementId: arrangement.id,
            activePaneId: p1.id
        )
        store.appendTab(tab)

        await executor.execute(.extractPaneToTab(tabId: tab.id, paneId: p2.id))

        #expect(store.tabs.count == 2)
        #expect(store.tabs[1].name == "Second")
    }

    // MARK: - Execute: resizePane

    @Test
    func test_execute_resizePane_updatesRatio() async throws {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab = Tab(paneId: p1.id)
        store.appendTab(tab)
        store.insertPane(
            p2.id, inTab: tab.id, at: p1.id,
            direction: .horizontal, position: .after, sizingMode: .halveTarget
        )

        guard let dividerId = store.tabs[0].layout.dividerIds.first else {
            Issue.record("Expected divider")
            return
        }

        // Act
        await executor.execute(.resizePane(tabId: tab.id, splitId: dividerId, ratio: 0.3))

        // Assert
        #expect(abs((store.tabs[0].layout.ratioForSplit(dividerId) ?? 0.0) - 0.3) < 0.001)
    }

    @Test
    func test_execute_resizeVisiblePanePair_updatesVisiblePair() async throws {
        let p1 = store.createPane()
        let p2 = store.createPane()
        let p3 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id, p3.id], activePaneId: p1.id)
        store.appendTab(tab)
        store.minimizePane(p2.id, inTab: tab.id)
        let before = store.tabs[0].layout

        await executor.execute(.resizeVisiblePanePair(tabId: tab.id, leftPaneId: p1.id, rightPaneId: p3.id, ratio: 0.3))

        let after = store.tabs[0].layout
        #expect(abs((after.ratioForPanePair(leftPaneId: p1.id, rightPaneId: p3.id) ?? 0) - 0.3) < 0.001)
        #expect(abs((after.paneRatio(p2.id) ?? 0) - (before.paneRatio(p2.id) ?? 0)) < 1e-9)
    }

    // MARK: - Execute: equalizePanes

    @Test
    func test_execute_equalizePanes_resetsRatios() async throws {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab = Tab(paneId: p1.id)
        store.appendTab(tab)
        store.insertPane(
            p2.id, inTab: tab.id, at: p1.id,
            direction: .horizontal, position: .after, sizingMode: .halveTarget
        )

        // Resize first
        guard let dividerId = store.tabs[0].layout.dividerIds.first else {
            Issue.record("Expected divider")
            return
        }
        store.resizePane(tabId: tab.id, splitId: dividerId, ratio: 0.3)

        // Act
        await executor.execute(.equalizePanes(tabId: tab.id))

        // Assert
        #expect(abs((store.tabs[0].layout.ratioForSplit(dividerId) ?? 0.0) - 0.5) < 0.001)
    }

    // MARK: - Execute: closePane

    @Test
    func test_execute_closePane_removesFromLayout() async throws {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let layout = Layout(paneId: p1.id)
            .inserting(paneId: p2.id, at: p1.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)!
        let arrangement = PaneArrangement(
            name: "Default",
            isDefault: true,
            layout: layout
        )
        let tab = Tab(
            panes: layout.paneIds,
            arrangements: [arrangement],
            activeArrangementId: arrangement.id,
            activePaneId: p1.id
        )
        store.appendTab(tab)

        // Act
        await executor.execute(.closePane(tabId: tab.id, paneId: p1.id))

        // Assert
        #expect(store.tabs[0].paneIds == [p2.id])
        #expect(!(store.tabs[0].isSplit))
    }

    // MARK: - Execute: movePaneAcrossTabs

    @Test
    func test_execute_movePaneAcrossTabs_movesPaneBetweenTabs() async throws {
        // Arrange — p2 in tab2, move to tab1 next to p1
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        // Act
        await executor.execute(
            .movePaneAcrossTabs(
                CrossTabPaneMoveRequest(
                    paneId: p2.id,
                    sourceTabId: tab2.id,
                    destTabId: tab1.id,
                    targetPaneId: p1.id,
                    direction: .horizontal,
                    position: .after
                )
            )
        )

        // Assert — tab2 was removed (last pane extracted), tab1 now has split
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].isSplit)
        #expect(store.tabs[0].paneIds.contains(p1.id))
        #expect(store.tabs[0].paneIds.contains(p2.id))
    }

    @Test
    func test_execute_insertPane_existingPane_sameTabMovesPane() async throws {
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab = Tab(paneId: p1.id)
        store.appendTab(tab)
        store.insertPane(
            p2.id,
            inTab: tab.id,
            at: p1.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )

        await executor.execute(
            .insertPane(
                source: .existingPane(paneId: p2.id, sourceTabId: tab.id),
                targetTabId: tab.id,
                targetPaneId: p1.id,
                direction: .left,
                sizingMode: .halveTarget
            )
        )

        #expect(store.tabs.count == 1)
        #expect(store.tab(tab.id)?.paneIds == [p2.id, p1.id])
    }

    @Test
    func test_executeInsertPane_existingPane_rollsBackSourceTabOnInsertFailure() async throws {
        let p1 = store.createPane()
        let tab = Tab(paneId: p1.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let tabBeforeMove = try #require(store.tab(tab.id))

        try await coordinator.executeInsertPane(
            source: .existingPane(paneId: p1.id, sourceTabId: tab.id),
            targetTabId: tab.id,
            targetPaneId: p1.id,
            direction: .left,
            sizingMode: .halveTarget
        )

        #expect(store.tab(tab.id) == tabBeforeMove)
        #expect(store.activeTabId == tab.id)
        #expect(store.tabContaining(paneId: p1.id)?.id == tab.id)
    }

    @Test
    func test_execute_insertPane_existingPane_crossTabRequest_isRejected() async throws {
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        await executor.execute(
            .insertPane(
                source: .existingPane(paneId: p2.id, sourceTabId: tab2.id),
                targetTabId: tab1.id,
                targetPaneId: p1.id,
                direction: .right,
                sizingMode: .halveTarget
            )
        )

        #expect(store.tabs.count == 2)
        #expect(store.tab(tab1.id)?.paneIds == [p1.id])
        #expect(store.tab(tab2.id)?.paneIds == [p2.id])
    }

    // MARK: - Execute: mergeTab

    @Test
    func test_execute_mergeTab_combinesTabs() async throws {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        // Act
        await executor.execute(
            .mergeTab(
                sourceTabId: tab2.id,
                targetTabId: tab1.id,
                targetPaneId: p1.id,
                direction: .right
            ))

        // Assert
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].isSplit)
    }

    // MARK: - OpenTerminal

    @Test
    func test_openTerminal_withoutTrustedGeometry_keepsPanePendingUntilBoundsExist() async throws {
        // Arrange — no trusted terminal container bounds are available in this harness,
        // so zmx pane creation should defer instead of rolling back.
        let worktree = makeWorktree()
        let repo = makeRepo()
        store.addRepo(at: repo.repoPath)

        // Act
        let pane = await executor.openTerminal(for: worktree, in: repo)

        // Assert — the pane exists in canonical state and shows a preparing placeholder
        // until trusted geometry arrives.
        #expect(pane != nil)
        #expect(store.tabs.count == 1)
        #expect(store.panes.count == 1)
        #expect(pane.flatMap { viewRegistry.terminalStatusPlaceholderView(for: $0.id) } != nil)
    }

    @Test
    func test_openTerminal_existingPane_selectsTab() async throws {
        // Arrange
        let launchDirectory = URL(filePath: "/tmp/worktree", directoryHint: .isDirectory)
        let repo = store.addRepo(at: launchDirectory)
        guard let worktree = repo.worktrees.first else {
            Issue.record("Expected store-admitted main worktree")
            return
        }

        // Create first pane manually
        let existingPane = store.createPane(
            launchDirectory: worktree.path,
            title: "Existing",
            facets: PaneContextFacets(cwd: worktree.path)
        )
        let tab = Tab(paneId: existingPane.id)
        store.appendTab(tab)

        // Act — try to open same worktree
        let result = await executor.openTerminal(for: worktree, in: repo)

        // Assert — returns nil (already exists), tab selected
        #expect(result == nil)
        #expect(store.tabs.count == 1)
        #expect(store.activeTabId == tab.id)
    }

    // MARK: - Undo GC

    @Test
    func test_undoStack_expiresOldEntries() async throws {
        // Arrange — close 12 tabs (exceeds maxUndoStackSize of 10)
        var closedPaneIds: [UUID] = []
        for _ in 0..<12 {
            let pane = store.createPane()
            closedPaneIds.append(pane.id)
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            await executor.execute(.closeTab(tabId: tab.id))
        }

        // Assert — undo stack is capped at 10
        #expect(executor.undoStack.count == 10)

        // The 2 oldest panes should be GC'd from the store
        // (they were in the expired undo entries and not in any layout)
        #expect(store.pane(closedPaneIds[0]) == nil)
        #expect(store.pane(closedPaneIds[1]) == nil)

        // Available undo owns the closed panes; live composition does not retain them.
        let undoPaneIDs = Set(executor.undoStack.flatMap { $0.panes.map(\.id) })
        #expect(undoPaneIDs.contains(closedPaneIds[2]))
        #expect(undoPaneIDs.contains(closedPaneIds[11]))
    }

    // MARK: - Execute: switchArrangement

    @Test
    func test_computeSwitchArrangementTransitions_includesPreviouslyMinimizedVisiblePaneInReattachSet() async throws {
        // Arrange
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()
        let previousVisiblePaneIds: Set<UUID> = [paneA, paneB]
        let previouslyMinimizedPaneIds: Set<UUID> = [paneB]
        let newVisiblePaneIds: Set<UUID> = [paneB, paneC]

        // Act
        let transitions = WorkspaceActionExecutor.computeSwitchArrangementTransitions(
            previousVisiblePaneIds: previousVisiblePaneIds,
            previouslyMinimizedPaneIds: previouslyMinimizedPaneIds,
            newVisiblePaneIds: newVisiblePaneIds,
            newMinimizedPaneIds: []
        )

        // Assert
        #expect(transitions.hiddenPaneIds == Set([paneA]))
        #expect(transitions.paneIdsToReattach == Set([paneB, paneC]))
    }

    @Test
    func test_computeSwitchArrangementTransitions_whenNoMinimizedPanes_reattachesOnlyRevealedPanes() async throws {
        // Arrange
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()
        let previousVisiblePaneIds: Set<UUID> = [paneA, paneB]
        let previouslyMinimizedPaneIds: Set<UUID> = []
        let newVisiblePaneIds: Set<UUID> = [paneB, paneC]

        // Act
        let transitions = WorkspaceActionExecutor.computeSwitchArrangementTransitions(
            previousVisiblePaneIds: previousVisiblePaneIds,
            previouslyMinimizedPaneIds: previouslyMinimizedPaneIds,
            newVisiblePaneIds: newVisiblePaneIds,
            newMinimizedPaneIds: []
        )

        // Assert
        #expect(transitions.hiddenPaneIds == Set([paneA]))
        #expect(transitions.paneIdsToReattach == Set([paneC]))
    }

    @Test
    func test_computeSwitchArrangementTransitions_skipsTargetMinimizedPaneFromReattachSet() async throws {
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()
        let previousVisiblePaneIds: Set<UUID> = [paneA, paneB]
        let previouslyMinimizedPaneIds: Set<UUID> = []
        let newVisiblePaneIds: Set<UUID> = [paneB, paneC]
        let newMinimizedPaneIds: Set<UUID> = [paneC]

        let transitions = WorkspaceActionExecutor.computeSwitchArrangementTransitions(
            previousVisiblePaneIds: previousVisiblePaneIds,
            previouslyMinimizedPaneIds: previouslyMinimizedPaneIds,
            newVisiblePaneIds: newVisiblePaneIds,
            newMinimizedPaneIds: newMinimizedPaneIds
        )

        #expect(transitions.hiddenPaneIds == Set([paneA]))
        #expect(transitions.paneIdsToReattach.isEmpty)
    }

    @Test
    func test_computeSwitchArrangementTransitions_keepsZoomSourcePresented() async throws {
        let sourcePaneId = UUID()

        let transitions = WorkspaceActionExecutor.computeSwitchArrangementTransitions(
            previousVisiblePaneIds: [sourcePaneId],
            previouslyMinimizedPaneIds: [],
            newVisiblePaneIds: [sourcePaneId],
            newMinimizedPaneIds: [sourcePaneId],
            retainedVisiblePaneIds: [sourcePaneId]
        )

        #expect(transitions.hiddenPaneIds.isEmpty)
        #expect(transitions.paneIdsToReattach.isEmpty)
    }

    @Test
    func test_execute_switchArrangement_updatesStoreState() async throws {
        // Arrange: tab with panes A, B, C. Default arrangement has all 3.
        let pA = store.createPane()
        let pB = store.createPane()
        let pC = store.createPane()

        let tab = Tab(paneId: pA.id)
        store.appendTab(tab)
        store.insertPane(
            pB.id, inTab: tab.id, at: pA.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)
        store.insertPane(
            pC.id, inTab: tab.id, at: pB.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)

        // Create custom arrangement as another complete view over A, B, C.
        let arrId = store.createArrangement(
            name: "Focus",
            inTab: tab.id
        )!

        // Act: switch to custom arrangement via executor
        await executor.execute(.switchArrangement(tabId: tab.id, arrangementId: arrId))

        // Assert: arrangements are complete views; switching changes arrangement identity, not membership.
        let updatedTab = store.tab(tab.id)!
        #expect(updatedTab.activeArrangementId == arrId)
        #expect(Set(updatedTab.paneIds) == Set([pA.id, pB.id, pC.id]))
        #expect(updatedTab.panes.contains(pC.id))
    }

    @Test
    func test_execute_switchArrangement_backToDefault_restoresAllPanes() async throws {
        // Arrange: tab with panes A, B, C
        let pA = store.createPane()
        let pB = store.createPane()
        let pC = store.createPane()

        let tab = Tab(paneId: pA.id)
        store.appendTab(tab)
        store.insertPane(
            pB.id, inTab: tab.id, at: pA.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)
        store.insertPane(
            pC.id, inTab: tab.id, at: pB.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)

        let customArrId = store.createArrangement(
            name: "Focus",
            inTab: tab.id
        )!

        // Switch to custom; it remains a complete view over all panes.
        await executor.execute(.switchArrangement(tabId: tab.id, arrangementId: customArrId))
        #expect(Set(store.tab(tab.id)!.paneIds) == Set([pA.id, pB.id, pC.id]))

        // Act: switch back to default
        let defaultArrId = store.tab(tab.id)!.defaultArrangement.id
        await executor.execute(.switchArrangement(tabId: tab.id, arrangementId: defaultArrId))

        // Assert: all three panes visible again
        let updatedTab = store.tab(tab.id)!
        #expect(updatedTab.activeArrangementId == defaultArrId)
        #expect(Set(updatedTab.paneIds) == Set([pA.id, pB.id, pC.id]))
    }

    @Test
    func test_execute_switchArrangement_sameArrangement_noOp() async throws {
        // Arrange
        let pA = store.createPane()
        let tab = Tab(paneId: pA.id)
        store.appendTab(tab)

        let defaultArrId = store.tab(tab.id)!.activeArrangementId

        // Act: switch to same arrangement (should be no-op)
        await executor.execute(.switchArrangement(tabId: tab.id, arrangementId: defaultArrId))

        // Assert: unchanged
        #expect(store.tab(tab.id)!.activeArrangementId == defaultArrId)
        #expect(store.tab(tab.id)!.paneIds == [pA.id])
    }

    @Test
    func test_execute_switchArrangement_invalidTabId_noOp() async throws {
        // Act: should not crash
        await executor.execute(.switchArrangement(tabId: UUID(), arrangementId: UUID()))

        // Assert: no tabs affected
        #expect(store.tabs.isEmpty)
    }

    // MARK: - Execute: switchArrangement (ViewRegistry integration)

    @Test
    func test_execute_switchArrangement_viewRegistryRetainsAllViews() async throws {
        // Arrange: tab with 3 panes, each registered in ViewRegistry
        let pA = store.createPane()
        let pB = store.createPane()
        let pC = store.createPane()

        let tab = Tab(paneId: pA.id)
        store.appendTab(tab)
        store.insertPane(
            pB.id, inTab: tab.id, at: pA.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)
        store.insertPane(
            pC.id, inTab: tab.id, at: pB.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)

        // Register stub PaneViews for all 3 panes
        let viewA = PaneHostView(paneId: pA.id)
        let viewB = PaneHostView(paneId: pB.id)
        let viewC = PaneHostView(paneId: pC.id)
        viewRegistry.register(viewA, for: pA.id)
        viewRegistry.register(viewB, for: pB.id)
        viewRegistry.register(viewC, for: pC.id)

        // Create custom arrangement as another complete view over all panes.
        let customArrId = store.createArrangement(
            name: "Focus",
            inTab: tab.id
        )!

        // Act: switch to custom arrangement
        await executor.execute(.switchArrangement(tabId: tab.id, arrangementId: customArrId))

        // Assert: all 3 views are still in the ViewRegistry
        #expect(viewRegistry.view(for: pA.id) != nil)  // View A should still be registered after arrangement switch
        #expect(viewRegistry.view(for: pB.id) != nil)  // View B should still be registered after arrangement switch
        #expect(viewRegistry.view(for: pC.id) != nil)
        #expect(viewRegistry.registeredPaneIds == Set([pA.id, pB.id, pC.id]))

        // Verify the store keeps all panes in the active arrangement.
        let updatedTab = store.tab(tab.id)!
        #expect(Set(updatedTab.paneIds) == Set([pA.id, pB.id, pC.id]))
        #expect(updatedTab.panes.contains(pC.id))
    }

    @Test
    func test_execute_switchArrangement_backToDefault_viewsStillRegistered() async throws {
        // Arrange: tab with 3 panes, each registered in ViewRegistry
        let pA = store.createPane()
        let pB = store.createPane()
        let pC = store.createPane()

        let tab = Tab(paneId: pA.id)
        store.appendTab(tab)
        store.insertPane(
            pB.id, inTab: tab.id, at: pA.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)
        store.insertPane(
            pC.id, inTab: tab.id, at: pB.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)

        // Register stub PaneViews for all 3 panes
        let viewA = PaneHostView(paneId: pA.id)
        let viewB = PaneHostView(paneId: pB.id)
        let viewC = PaneHostView(paneId: pC.id)
        viewRegistry.register(viewA, for: pA.id)
        viewRegistry.register(viewB, for: pB.id)
        viewRegistry.register(viewC, for: pC.id)

        // Create a complete custom arrangement.
        let customArrId = store.createArrangement(
            name: "Solo",
            inTab: tab.id
        )!

        // Act: switch to custom, then back to default
        await executor.execute(.switchArrangement(tabId: tab.id, arrangementId: customArrId))
        let defaultArrId = store.tab(tab.id)!.defaultArrangement.id
        await executor.execute(.switchArrangement(tabId: tab.id, arrangementId: defaultArrId))

        // Assert: all 3 views are still registered after round-trip
        #expect(viewRegistry.view(for: pA.id) != nil)  // View A should survive round-trip arrangement switch
        #expect(viewRegistry.view(for: pB.id) != nil)  // View B should survive round-trip arrangement switch
        #expect(viewRegistry.view(for: pC.id) != nil)  // View C should survive round-trip arrangement switch
        #expect(viewRegistry.registeredPaneIds == Set([pA.id, pB.id, pC.id]))

        // Verify all panes are visible again in the default arrangement
        let updatedTab = store.tab(tab.id)!
        #expect(Set(updatedTab.paneIds) == Set([pA.id, pB.id, pC.id]))
    }

    // MARK: - Execute: repair

    @Test
    func test_executeRepair_recreateSurface_replacesExistingView() async throws {
        // Arrange
        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/recreate")!)),
            metadata: PaneMetadata(title: "Recreate")
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        let stubView = PaneHostView(paneId: pane.id)
        viewRegistry.register(stubView, for: pane.id)

        // Act
        await executor.execute(.repair(.recreateSurface(paneId: pane.id)))

        // Assert
        let repairedView = viewRegistry.view(for: pane.id)
        #expect(repairedView != nil)
        #expect(repairedView !== stubView)
    }

    @Test
    func test_executeRepair_createMissingView_registersView() async throws {
        // Arrange
        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/missing")!)),
            metadata: PaneMetadata(title: "Missing")
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        #expect(viewRegistry.view(for: pane.id) == nil)

        // Act
        await executor.execute(.repair(.createMissingView(paneId: pane.id)))

        // Assert
        #expect(viewRegistry.view(for: pane.id) != nil)
    }

    @Test
    func test_executeRepair_unknownPane_doesNotRegisterView() async throws {
        // Arrange
        let unknownId = UUID()
        #expect(viewRegistry.view(for: unknownId) == nil)

        // Act
        await executor.execute(.repair(.recreateSurface(paneId: unknownId)))

        // Assert — guard early-returns, no registration
        #expect(viewRegistry.view(for: unknownId) == nil)
    }
}
