import AgentStudioInfrastructure
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceCoordinatorTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    private struct WorkspaceSurfaceCoordinatorHarness {
        let store: WorkspaceStore
        let viewRegistry: ViewRegistry
        let runtime: SessionRuntime
        let coordinator: WorkspaceSurfaceCoordinator
        let tempDir: URL
    }

    private func makeHarnessCoordinator() -> WorkspaceSurfaceCoordinatorHarness {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-tests-\(UUIDv7.generate().uuidString)")
        let store: WorkspaceStore
        do { store = try makeWorkspaceJournalTestStore() } catch {
            preconditionFailure("Could not prepare the coordinator harness SQLite store: \(error)")
        }
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let coordinator = {
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
        return WorkspaceSurfaceCoordinatorHarness(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            coordinator: coordinator,
            tempDir: tempDir
        )
    }

    private func withCoordinatorHarness(
        _ harness: WorkspaceSurfaceCoordinatorHarness, operation: () async throws -> Void
    ) async throws {
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        do { try await operation() } catch {
            await harness.coordinator.shutdown()
            throw error
        }
        await harness.coordinator.shutdown()
    }

    private func makeWebviewPane(_ store: WorkspaceStore, title: String) -> Pane {
        let url = URL(string: "https://example.com/\(UUIDv7.generate().uuidString)")!
        return store.createPane(
            content: .webview(WebviewState(url: url, showNavigation: true)),
            metadata: PaneMetadata(title: title)
        )
    }

    func makeFilesystemSyncCoordinator(
        store: WorkspaceStore,
        filesystemSource: some WorkspaceFilesystemSourceManaging,
        paneEventBus: EventBus<RuntimeEnvelope>
    ) -> WorkspaceSurfaceCoordinator {
        let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        return WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: CoordinatorFilesystemMockSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: paneEventBus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: filesystemSource,
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }

    func reconciledWorktree(
        in store: WorkspaceStore,
        repoId: UUID,
        path: URL
    ) throws -> Worktree {
        try #require(store.repo(repoId)?.worktrees.first(where: { $0.path == path }))
    }

    func appendAndActivateSingleTab(
        for paneId: UUID,
        in store: WorkspaceStore
    ) -> Tab {
        let tab = Tab(paneId: paneId)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        return tab
    }

    @Test
    func test_paneCoordinator_exposesExecuteAPI() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let action: WorkspaceActionCommand = .selectTab(tabId: UUID())
            try await harness.coordinator.execute(action)
        }
    }

    @Test("undo close tab restores the tab and activates it")
    func undoCloseTab_restoresAndActivatesClosedTab() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            let paneA = makeWebviewPane(store, title: "A")
            let paneB = makeWebviewPane(store, title: "B")
            let tabA = Tab(paneId: paneA.id)
            let tabB = Tab(paneId: paneB.id)
            store.appendTab(tabA)
            store.appendTab(tabB)
            store.setActiveTab(tabB.id)

            try await coordinator.execute(.closeTab(tabId: tabA.id))
            #expect(store.tab(tabA.id) == nil)
            #expect(store.activeTabId == tabB.id)
            #expect(coordinator.undoStack.count == 1)

            try await coordinator.undoCloseTab()

            #expect(store.tab(tabA.id) != nil)
            #expect(store.activeTabId == tabA.id)
            #expect(coordinator.undoStack.isEmpty)
        }
    }

    @Test("close pane undo round-trips pane in layout")
    func closePane_undo_restoresPane() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            let paneA = makeWebviewPane(store, title: "A")
            let paneB = makeWebviewPane(store, title: "B")
            let tab = Tab(paneId: paneA.id)
            store.appendTab(tab)
            store.insertPane(
                paneB.id,
                inTab: tab.id,
                at: paneA.id,
                direction: .horizontal,
                position: .after, sizingMode: .halveTarget
            )

            try await coordinator.execute(.closePane(tabId: tab.id, paneId: paneB.id))
            guard let afterClose = store.tab(tab.id) else {
                Issue.record("Expected tab to remain after closing one pane")
                return
            }
            #expect(afterClose.paneIds == [paneA.id])
            #expect(coordinator.undoStack.count == 1)

            try await coordinator.undoCloseTab()
            guard let afterUndo = store.tab(tab.id) else {
                Issue.record("Expected tab to exist after undo")
                return
            }
            #expect(afterUndo.paneIds.count == 2)
            #expect(Set(afterUndo.paneIds) == Set([paneA.id, paneB.id]))
        }
    }

    @Test("closePane on the last pane in an active tab produces a TabCloseSnapshot")
    func closePane_lastPaneActive_producesTabSnapshot() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            let pane = makeWebviewPane(store, title: "Solo")
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)

            try await coordinator.execute(.closePane(tabId: tab.id, paneId: pane.id))

            #expect(store.tab(tab.id) == nil)
            #expect(store.pane(pane.id) == nil)
            guard let entry = coordinator.undoStack.last else {
                Issue.record("Expected undo entry after last-pane close")
                return
            }
            switch entry {
            case .tab(let snapshot):
                #expect(snapshot.tab.id == tab.id)
            case .pane:
                Issue.record("Expected tab snapshot when closing the last pane")
            }
        }
    }

    @Test("closePane on the last pane in a background tab still produces a TabCloseSnapshot")
    func closePane_lastPaneBackground_stillProducesTabSnapshot() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            let activePane = makeWebviewPane(store, title: "Active")
            let activeTab = Tab(paneId: activePane.id)
            store.appendTab(activeTab)
            store.setActiveTab(activeTab.id)

            let backgroundPane = makeWebviewPane(store, title: "Background")
            let backgroundTab = Tab(paneId: backgroundPane.id)
            store.appendTab(backgroundTab)

            try await coordinator.execute(.closePane(tabId: backgroundTab.id, paneId: backgroundPane.id))

            #expect(store.tab(backgroundTab.id) == nil)
            guard case .tab(let snapshot)? = coordinator.undoStack.last else {
                Issue.record("Expected TabCloseSnapshot for background last-pane close")
                return
            }
            #expect(snapshot.tab.id == backgroundTab.id)
        }
    }

    @Test("closePane on a non-last pane in an active tab produces a PaneCloseSnapshot")
    func closePane_nonLastPaneActive_producesPaneSnapshot() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            let paneA = makeWebviewPane(store, title: "A")
            let paneB = makeWebviewPane(store, title: "B")
            let tab = Tab(paneId: paneA.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            store.insertPane(
                paneB.id,
                inTab: tab.id,
                at: paneA.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )

            try await coordinator.execute(.closePane(tabId: tab.id, paneId: paneB.id))

            #expect(store.tab(tab.id) != nil)
            guard case .pane(let snapshot)? = coordinator.undoStack.last else {
                Issue.record("Expected PaneCloseSnapshot")
                return
            }
            #expect(snapshot.pane.id == paneB.id)
        }
    }

    @Test("filesystem projection ignores non-projectable worktree events before deriving topology maps")
    func filesystemProjectionIgnoresNonProjectableWorktreeEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-filesystem-ignore-\(UUIDv7.generate().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WorkspaceStore()
        let coordinator = makeFilesystemSyncCoordinator(
            store: store,
            filesystemSource: RecordingFilesystemSourceHarness(),
            paneEventBus: EventBus<RuntimeEnvelope>()
        )

        let envelope = RuntimeEnvelope.worktree(
            WorktreeEnvelope(
                source: .system(.builtin(.gitWorkingDirectoryProjector)),
                seq: 1,
                timestamp: ContinuousClock().now,
                repoId: UUID(),
                worktreeId: UUID(),
                event: .gitWorkingDirectory(.originChanged(repoId: UUID(), from: "", to: "origin"))
            )
        )

        #expect(await coordinator.handleFilesystemEnvelopeIfNeeded(envelope) == false)
    }

    @Test("closing tab with drawer children snapshots all panes for undo")
    func closeTab_withDrawerChildren_snapshotsUndo() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            let parentPane = makeWebviewPane(store, title: "Parent")
            let tab = Tab(paneId: parentPane.id)
            store.appendTab(tab)
            guard
                let drawerPane = store.addDrawerPane(
                    to: parentPane.id,
                    parentFallbackCWD: FileManager.default.homeDirectoryForCurrentUser
                )
            else {
                Issue.record("Expected drawer pane creation to succeed")
                return
            }

            try await coordinator.execute(.closeTab(tabId: tab.id))

            #expect(store.tab(tab.id) == nil)
            #expect(store.tabs.allSatisfy { !$0.paneIds.contains(parentPane.id) })
            #expect(store.tabs.allSatisfy { !$0.paneIds.contains(drawerPane.id) })

            guard case .tab(let snapshot)? = coordinator.undoStack.last else {
                Issue.record("Expected tab close snapshot in undo stack")
                return
            }
            let snapshottedPaneIds = Set(snapshot.panes.map(\.id))
            #expect(snapshottedPaneIds.contains(parentPane.id))
            #expect(snapshottedPaneIds.contains(drawerPane.id))
        }
    }

    @Test("terminal drawer creation from a locationless webview uses the user home directory")
    func addDrawerPaneFromLocationlessWebviewUsesHomeDirectory() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let parentPane = makeWebviewPane(harness.store, title: "Locationless")
            harness.store.appendTab(Tab(paneId: parentPane.id))

            try await harness.coordinator.execute(.addDrawerPane(parentPaneId: parentPane.id))

            let drawerPaneID = try #require(harness.store.pane(parentPane.id)?.drawer?.paneIds.single)
            let drawerPane = try #require(harness.store.pane(drawerPaneID))
            #expect(drawerPane.metadata.cwd == FileManager.default.homeDirectoryForCurrentUser)
            #expect(drawerPane.metadata.launchDirectory == FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    @Test("terminal drawer insertion from a locationless webview uses the user home directory")
    func insertDrawerPaneFromLocationlessWebviewUsesHomeDirectory() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let parentPane = makeWebviewPane(harness.store, title: "Locationless")
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            let targetPane = try #require(
                harness.store.paneAtom.addDrawerPane(
                    to: parentPane.id,
                    content: .webview(WebviewState(url: URL(string: "https://example.com/drawer")!)),
                    metadata: PaneMetadata(title: "Target")
                )
            )

            let drawerID = try #require(harness.store.pane(parentPane.id)?.drawer?.drawerId)
            harness.store.tabArrangementAtom.addDrawerPaneView(
                drawerId: drawerID, parentPaneId: parentPane.id, drawerPaneId: targetPane.id, inTab: tab.id)

            try await harness.coordinator.executeInsertDrawerPane(
                parentPaneId: parentPane.id,
                targetDrawerPaneId: targetPane.id,
                direction: .right,
                sizingMode: .halveTarget
            )

            let drawerPaneIDs = try #require(harness.store.pane(parentPane.id)?.drawer?.paneIds)
            let insertedPaneID = try #require(drawerPaneIDs.first { $0 != targetPane.id })
            let insertedPane = try #require(harness.store.pane(insertedPaneID))
            #expect(insertedPane.metadata.cwd == FileManager.default.homeDirectoryForCurrentUser)
            #expect(insertedPane.metadata.launchDirectory == FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    @Test("openWebview creates and activates a new tab")
    func openWebview_createsAndActivatesTab() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator

            let opened = coordinator.openWebview(url: URL(string: "https://example.com/open-webview-test")!)
            guard let opened else {
                Issue.record("Expected webview pane to open")
                return
            }

            #expect(store.tabs.count == 1)
            #expect(store.activeTabId == store.tabs.first?.id)
            #expect(store.tab(store.tabs[0].id)?.paneIds == [opened.id])
            #expect(viewRegistry.view(for: opened.id) != nil)
        }
    }

    @Test("teardownView unregisters runtime from RuntimeRegistry")
    func teardownViewUnregistersRuntime() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {

            let runtimePaneId = PaneId.generateUUIDv7()
            let metadata = PaneMetadata(
                paneId: runtimePaneId,
                contentType: .browser,
                title: "Runtime Teardown"
            )
            let runtime = WebviewRuntime(
                paneId: runtimePaneId,
                metadata: metadata
            )
            runtime.transitionToReady()
            harness.coordinator.registerRuntime(runtime)

            #expect(harness.coordinator.runtimeForPane(runtimePaneId) != nil)
            harness.coordinator.teardownView(for: runtimePaneId.uuid)
            #expect(harness.coordinator.runtimeForPane(runtimePaneId) == nil)
        }
    }

    @Test("focusPane auto-expands minimized pane")
    func focusPane_autoExpandsMinimizedPane() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            let paneA = makeWebviewPane(store, title: "A")
            let paneB = makeWebviewPane(store, title: "B")
            let tab = Tab(paneId: paneA.id)
            store.appendTab(tab)
            store.insertPane(
                paneB.id,
                inTab: tab.id,
                at: paneA.id,
                direction: .horizontal,
                position: .after, sizingMode: .halveTarget
            )

            try await coordinator.execute(.minimizePane(tabId: tab.id, paneId: paneB.id))
            #expect(store.tab(tab.id)?.activeMinimizedPaneIds.contains(paneB.id) == true)

            try await coordinator.execute(.expandPane(tabId: tab.id, paneId: paneB.id))

            #expect(store.tab(tab.id)?.activeMinimizedPaneIds.contains(paneB.id) == false)
            #expect(store.tab(tab.id)?.activePaneId == paneB.id)
        }
    }

    @Test("undo preserves a still-valid entry when its target tab no longer exists")
    func undo_skipsStalePaneEntryWhenTabMissing() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            let paneA = makeWebviewPane(store, title: "A")
            let paneB = makeWebviewPane(store, title: "B")
            let tab = Tab(paneId: paneA.id)
            store.appendTab(tab)
            store.insertPane(
                paneB.id,
                inTab: tab.id,
                at: paneA.id,
                direction: .horizontal,
                position: .after, sizingMode: .halveTarget
            )

            try await coordinator.execute(.closePane(tabId: tab.id, paneId: paneB.id))
            #expect(coordinator.undoStack.count == 1)

            store.removeTab(tab.id)
            try await coordinator.undoCloseTab()

            #expect(store.tab(tab.id) == nil)
            #expect(coordinator.undoStack.count == 1)
            let recovery = try await store.recoverUndoJournal(time: nil)
            #expect(recovery.availableCloses.count == 1)
        }
    }

    @Test("undo stack keeps only max configured entries")
    func undoStack_capsAtMaxEntries() async throws {
        let harness = makeHarnessCoordinator()
        try await withCoordinatorHarness(harness) {
            let store = harness.store
            let coordinator = harness.coordinator

            for index in 0..<12 {
                let pane = makeWebviewPane(store, title: "Pane-\(index)")
                let tab = Tab(paneId: pane.id)
                store.appendTab(tab)
                try await coordinator.execute(.closeTab(tabId: tab.id))
            }

            #expect(coordinator.undoStack.count == 10)
        }
    }

}
