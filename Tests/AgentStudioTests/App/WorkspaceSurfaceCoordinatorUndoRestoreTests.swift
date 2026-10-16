import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceCoordinatorUndoRestoreTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    private let trustedBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test("undo eviction preserves a pane still owned by another retained snapshot")
    func undoEvictionPreservesPaneOwnedByAnotherSnapshot() async throws {
        // Arrange
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let retainedPane = makeWebviewPane(harness.store, title: "Retained snapshot pane")
        let retainedTab = Tab(paneId: retainedPane.id)
        harness.store.appendTab(retainedTab)
        let earlierSnapshot = try #require(
            harness.store.mutationCoordinator.snapshotForClose(tabId: retainedTab.id)
        )
        let time = try await WorkspaceUndoJournalClock.current()
        let snapshot = WorkspaceUndoCloseSnapshot(entry: .tab(earlierSnapshot))
        let saveCoordinator = WorkspaceSQLiteSaveCoordinator(
            identityAtom: harness.store.identityAtom, windowMemoryAtom: harness.store.windowMemoryAtom,
            workspacePaneAtom: harness.store.paneAtom, workspaceTabLayoutAtom: harness.store.tabLayoutAtom,
            sqliteDatastore: harness.datastore
        )
        let bundle = await saveCoordinator.captureCurrentSaveBundle(persistedAt: time.utc)
        try harness.backend.replaceWorkspaceSnapshot(
            bundle, updatesActiveSelection: true,
            undoChange: .record(
                .init(
                    closeID: UUIDv7.generate(), workspaceID: harness.store.identityAtom.workspaceId, kind: .tab,
                    closedAt: time.utc, expiresAt: time.utc.addingTimeInterval(300), deadlineBootID: time.bootID,
                    deadlineUptimeNanoseconds: time.uptimeNanoseconds + 300_000_000_000,
                    snapshotVersion: 1, snapshotPayload: try JSONEncoder().encode(snapshot), members: snapshot.members
                )))
        harness.coordinator.installUndoJournalRecovery(try await harness.store.recoverUndoJournal(time: time))
        try await harness.coordinator.execute(.closeTab(tabId: retainedTab.id))

        // Act: evict only the earlier snapshot; the second snapshot remains undoable.
        for index in 0..<9 {
            let pane = makeWebviewPane(harness.store, title: "Later close \(index)")
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        }

        // Assert
        #expect(harness.coordinator.undoStack.count == 10)
        #expect(harness.coordinator.undoStack.contains { $0.panes.contains { $0.id == retainedPane.id } })
        #expect(!harness.surfaceManager.releasedUndoPaneIDs.contains(retainedPane.id))
        await harness.coordinator.shutdown()
    }

    private struct Harness {
        let store: WorkspaceStore
        let viewRegistry: ViewRegistry
        let runtime: SessionRuntime
        let coordinator: WorkspaceSurfaceCoordinator
        let tempDir: URL
        let surfaceManager: UndoRestoreSurfaceManager
        let datastore: WorkspaceSQLiteDatastoreActor
        let backend: WorkspaceSQLiteStoreBackend
    }

    private func makeHarness(
        createSurfaceResult: Result<ManagedSurface, SurfaceError> = .failure(.ghosttyNotInitialized),
        undoCloseResults: [ManagedSurface] = []
    ) throws -> Harness {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-undo-restore-\(UUID().uuidString)")
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let surfaceManager = UndoRestoreSurfaceManager(
            createSurfaceResult: createSurfaceResult,
            undoCloseResults: undoCloseResults
        )
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        return Harness(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            coordinator: coordinator,
            tempDir: tempDir,
            surfaceManager: surfaceManager,
            datastore: datastore, backend: fixture.backend
        )
    }

    private func makeRepoAndWorktree(_ store: WorkspaceStore, root: URL) -> (Repo, Worktree) {
        let repoPath = root.appending(path: "repo-\(UUID().uuidString)")
        let worktreePath = repoPath.appending(path: "wt-main")
        try? FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)

        let repo = store.addRepo(at: repoPath)
        let worktree = Worktree(repoId: repo.id, name: "wt-main", path: worktreePath)
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [worktree])
        return store.repositoryTopologyAtom.repoAndWorktree(containing: worktreePath) ?? (repo, worktree)
    }

    /// Returns a repo/worktree pair whose worktree is admitted into the topology atom, unlike
    /// `makeRepoAndWorktree`'s nested "wt-main" candidate: reconciling that nested candidate alone
    /// (without also carrying forward the auto-created root worktree) leaves the repo without a
    /// worktree at its root path, so `reconcileWorktrees` marks the repo unavailable and pane
    /// creation never stamps `worktreeId`/`repoId` onto the resulting pane. Callers that need a
    /// pane whose `worktreeId`/`repoId` actually resolve through `RepositoryTopologyAtom` (e.g.
    /// undo paths that look up `pane.worktreeId`) should use this helper instead.
    private func makeAdmittedRepoAndWorktree(_ store: WorkspaceStore, root: URL) -> (Repo, Worktree) {
        let repoPath = root.appending(path: "repo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        let repo = store.addRepo(at: repoPath)
        return (repo, repo.worktrees[0])
    }

    private func makeWebviewPane(_ store: WorkspaceStore, title: String) -> Pane {
        let url = URL(string: "https://example.com/\(UUID().uuidString)")!
        return store.createPane(
            content: .webview(WebviewState(url: url, showNavigation: true)),
            metadata: PaneMetadata(title: title)
        )
    }

    private func makeWorktreePane(
        _ store: WorkspaceStore,
        repo: Repo,
        worktree: Worktree,
        title: String
    ) -> Pane {
        store.createPane(
            launchDirectory: worktree.path,
            title: title,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
    }

    @Test("close moves pane ownership to the journal and undo restores live ownership")
    func closeTab_marksSnapshotPanesPendingUndo_andUndoRestoresActiveOwnership() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let firstPane = makeWebviewPane(harness.store, title: "First")
        let secondPane = makeWebviewPane(harness.store, title: "Second")
        let tab = Tab(paneId: firstPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.insertPane(
            secondPane.id,
            inTab: tab.id,
            at: firstPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )

        try await harness.coordinator.execute(.closeTab(tabId: tab.id))

        #expect(harness.store.tab(tab.id) == nil)
        for paneId in [firstPane.id, secondPane.id] {
            #expect(harness.store.pane(paneId) == nil)
            #expect(harness.coordinator.undoStack.contains { $0.panes.contains { $0.id == paneId } })
        }

        try await harness.coordinator.undoCloseTab()

        let restoredTab = try #require(harness.store.tab(tab.id))
        #expect(Set(restoredTab.allPaneIds) == Set([firstPane.id, secondPane.id]))
        for paneId in [firstPane.id, secondPane.id] {
            #expect(harness.store.pane(paneId)?.residency == .active)
        }
    }

    @Test("undoTabClose preserves restored ownership when a terminal renderer fails")
    func undoTabClose_partialRestore_preservesFailedPaneOwnership() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let terminalPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Terminal")
        let webviewPane = makeWebviewPane(harness.store, title: "Web")
        let tab = Tab(paneId: terminalPane.id)
        harness.store.appendTab(tab)
        harness.store.insertPane(
            webviewPane.id,
            inTab: tab.id,
            at: terminalPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        guard let restoredTab = harness.store.tab(tab.id) else {
            Issue.record("Expected tab to remain after partial restore")
            return
        }
        #expect(Set(restoredTab.paneIds) == [terminalPane.id, webviewPane.id])
        #expect(
            harness.store.pane(terminalPane.id)?.terminalState?.zmxSessionID == terminalPane.terminalState?.zmxSessionID
        )
        #expect(harness.viewRegistry.view(for: webviewPane.id) != nil)
    }

    @Test("undoTabClose preserves drawer state when terminal restore is deferred by missing geometry")
    func undoTabClose_deferredTerminalRestore_preservesDrawerState() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeAdmittedRepoAndWorktree(harness.store, root: harness.tempDir)
        let parentPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Parent")
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let firstDrawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
        let secondDrawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(harness.store.pane(parentPane.id)?.drawer?.drawerId)
        harness.store.setActiveDrawerPane(secondDrawerPane.id, in: parentPane.id)
        for paneId in [parentPane.id, firstDrawerPane.id, secondDrawerPane.id] {
            let facets = try #require(
                harness.store.paneAtom.graphAtom.paneState(paneId)?.durableContextFacets
            )
            #expect(facets.repoId == repo.id)
            #expect(facets.worktreeId == worktree.id)
            #expect(facets.cwd?.standardizedFileURL.path == worktree.path.standardizedFileURL.path)
        }

        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        let restoredTab = try #require(harness.store.tab(tab.id))
        let restoredParent = try #require(harness.store.pane(parentPane.id))
        let restoredDrawerView = try #require(harness.store.drawerView(forParent: parentPane.id))
        #expect(restoredTab.allPaneIds == [parentPane.id, firstDrawerPane.id, secondDrawerPane.id])
        #expect(restoredParent.drawer?.paneIds == [firstDrawerPane.id, secondDrawerPane.id])
        #expect(restoredDrawerView.layout.paneIds == [firstDrawerPane.id, secondDrawerPane.id])
        #expect(restoredDrawerView.activeChildId == secondDrawerPane.id)
        #expect(harness.store.drawerCursorAtom.isExpanded(drawerId: drawerId))
        #expect(harness.viewRegistry.terminalStatusPlaceholderView(for: parentPane.id)?.mode == .preparing)
        for paneId in [parentPane.id, firstDrawerPane.id, secondDrawerPane.id] {
            let facets = try #require(
                harness.store.paneAtom.graphAtom.paneState(paneId)?.durableContextFacets
            )
            #expect(facets.repoId == repo.id)
            #expect(facets.worktreeId == worktree.id)
            #expect(facets.cwd?.standardizedFileURL.path == worktree.path.standardizedFileURL.path)
        }
    }

    @Test("deferred undo restore persists drawer graph and matched local cursor through fresh SQLite restore")
    func deferredUndoRestore_persistsDrawerStateThroughFreshSQLiteRestore() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceId)
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-undo-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let identityAtom = WorkspaceIdentityAtom(
            workspaceId: workspaceId,
            workspaceName: "Deferred Drawer Restore",
            createdAt: Date(timeIntervalSince1970: 1_700_000_088)
        )
        let sqliteDatastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        try fixture.coreRepository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: identityAtom.workspaceName,
                createdAt: identityAtom.createdAt,
                updatedAt: identityAtom.createdAt
            )
        )
        let store = WorkspaceStore(
            identityAtom: identityAtom,
            sqliteDatastore: sqliteDatastore
        )
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let coordinator = {
            let fixtureSurfaceManager = UndoRestoreSurfaceManager(
                createSurfaceResult: .failure(.ghosttyNotInitialized)
            )
            return WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: viewRegistry,
                runtime: runtime,
                surfaceManager: fixtureSurfaceManager,
                terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
                terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: fixtureSurfaceManager),
                runtimeRegistry: RuntimeRegistry(),
                windowLifecycleStore: WindowLifecycleAtom(),
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
        }()
        let (repo, worktree) = makeRepoAndWorktree(store, root: tempDir)
        let topologyStore = RepositoryTopologyStore(
            atom: store.repositoryTopologyAtom,
            sqliteDatastore: sqliteDatastore
        )
        try await topologyStore.flushAsync()
        let parentPane = makeWorktreePane(store, repo: repo, worktree: worktree, title: "Parent")
        let tab = Tab(paneId: parentPane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let firstDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let secondDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(store.pane(parentPane.id)?.drawer?.drawerId)
        store.setActiveDrawerPane(secondDrawerPane.id, in: parentPane.id)

        try await coordinator.execute(.closeTab(tabId: tab.id))
        try await coordinator.undoCloseTab()
        let flushOutcome = await store.flushAsync()

        #expect(flushOutcome.succeeded)
        let restoredStore = WorkspaceStore(
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        )
        _ = await restoredStore.loadCanonicalComposition()

        let restoredTab = try #require(restoredStore.tab(tab.id))
        let restoredParent = try #require(restoredStore.pane(parentPane.id))
        let restoredDrawerView = try #require(restoredStore.drawerView(forParent: parentPane.id))
        #expect(restoredTab.allPaneIds == [parentPane.id, firstDrawerPane.id, secondDrawerPane.id])
        #expect(restoredParent.drawer?.paneIds == [firstDrawerPane.id, secondDrawerPane.id])
        #expect(restoredDrawerView.layout.paneIds == [firstDrawerPane.id, secondDrawerPane.id])
        #expect(restoredDrawerView.activeChildId == secondDrawerPane.id)
        #expect(restoredStore.drawerCursorAtom.isExpanded(drawerId: drawerId))
    }

    @Test("undoTabClose preserves tab ownership when all renderers fail")
    func undoTabClose_allRestoreFailures_preservesTab() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let terminalPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Terminal")
        let tab = Tab(paneId: terminalPane.id)
        harness.store.appendTab(tab)
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        #expect(harness.store.tab(tab.id) != nil)
        #expect(harness.store.activeTabId == tab.id)
        #expect(harness.store.pane(terminalPane.id) != nil)
    }

    @Test("undoTabClose restore failure preserves the restored pane and rendered slot")
    func undoTabClose_restoreFailure_preservesRenderedSlot() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let terminalPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Terminal")
        let tab = Tab(paneId: terminalPane.id)
        harness.store.appendTab(tab)
        let originalSlot = harness.viewRegistry.ensureSlot(for: terminalPane.id)
        harness.viewRegistry.surfaceRenderedIds("tab:\(tab.id)", ids: [terminalPane.id])
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        #expect(harness.store.pane(terminalPane.id) != nil)
        #expect(!harness.viewRegistry.isRetiredForTesting(terminalPane.id))
        #expect(harness.viewRegistry.peekSlotForTesting(terminalPane.id) === originalSlot)
    }

    @Test("drawer undo preserves ownership and slot through deferred or failed rendering", arguments: [false, true])
    func undoPaneClose_preservesStaleRenderedDrawerSlot(geometryAvailable: Bool) async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let parent = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Parent")
        let tab = Tab(paneId: parent.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let child = try #require(harness.store.addDrawerPane(to: parent.id))
        let originalSlot = harness.viewRegistry.ensureSlot(for: child.id)
        harness.viewRegistry.surfaceRenderedIds("drawer:\(parent.id)", ids: [child.id])
        if geometryAvailable {
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        }

        try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: child.id))
        try await harness.coordinator.undoCloseTab()

        #expect(harness.store.pane(child.id) != nil)
        #expect(!harness.viewRegistry.isRetiredForTesting(child.id))
        #expect(harness.viewRegistry.peekSlotForTesting(child.id) === originalSlot)
        #expect(
            harness.viewRegistry.terminalStatusPlaceholderView(for: child.id)?.mode
                == (geometryAvailable ? .failedToStart : .preparing)
        )
    }

    @Test("undoPaneClose renderer failure preserves the restored main pane")
    func undoPaneClose_hardFailure_preservesMainPane() async throws {
        let harness = try makeHarness(createSurfaceResult: .failure(.ghosttyNotInitialized))
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let anchor = makeWebviewPane(harness.store, title: "Anchor")
        let terminal = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Terminal")
        let tab = Tab(paneId: anchor.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.insertPane(
            terminal.id,
            inTab: tab.id,
            at: anchor.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        let originalSlot = harness.viewRegistry.ensureSlot(for: terminal.id)
        harness.viewRegistry.surfaceRenderedIds("tab:\(tab.id)", ids: [terminal.id])
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: terminal.id))
        try await harness.coordinator.undoCloseTab()

        #expect(harness.store.pane(terminal.id) != nil)
        #expect(Set(harness.store.tab(tab.id)?.paneIds ?? []) == [anchor.id, terminal.id])
        #expect(!harness.viewRegistry.isRetiredForTesting(terminal.id))
        #expect(harness.viewRegistry.peekSlotForTesting(terminal.id) === originalSlot)
    }

    @Test("undoTabClose preserves the active arrangement when a renderer fails")
    func undoTabClose_preservesActiveArrangementOnRendererFailure() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let terminalPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Terminal")
        let webviewPane = makeWebviewPane(harness.store, title: "Web")
        let tab = Tab(paneId: terminalPane.id)
        harness.store.appendTab(tab)
        harness.store.insertPane(
            webviewPane.id,
            inTab: tab.id,
            at: terminalPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        guard
            let terminalOnlyArrangementId = harness.store.createArrangement(
                name: "Terminal only",
                inTab: tab.id
            )
        else {
            Issue.record("Expected arrangement creation to succeed")
            return
        }
        harness.store.switchArrangement(to: terminalOnlyArrangementId, inTab: tab.id)
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        guard let restoredTab = harness.store.tab(tab.id) else {
            Issue.record("Expected tab to remain after fallback arrangement recovery")
            return
        }
        #expect(Set(restoredTab.panes) == [terminalPane.id, webviewPane.id])
        #expect(restoredTab.activeArrangementId == terminalOnlyArrangementId)
        #expect(restoredTab.activeArrangement.layout.contains(webviewPane.id))
    }

    @Test("undoCloseTab skips orphaned drawer-child pane snapshots safely")
    func undoCloseTab_skipsOrphanedDrawerChildSnapshot() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let anchorPane = makeWebviewPane(harness.store, title: "Anchor")
        let parentPane = makeWebviewPane(harness.store, title: "Parent")
        let tab = Tab(paneId: anchorPane.id)
        harness.store.appendTab(tab)
        harness.store.insertPane(
            parentPane.id,
            inTab: tab.id,
            at: anchorPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )

        guard
            let drawerPane = harness.store.addDrawerPane(
                to: parentPane.id,
                parentFallbackCWD: FileManager.default.homeDirectoryForCurrentUser
            )
        else {
            Issue.record("Expected drawer pane creation")
            return
        }

        try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: drawerPane.id))
        #expect(harness.coordinator.undoStack.count == 1)

        harness.store.removePaneFromLayout(parentPane.id, inTab: tab.id)
        harness.store.removePane(parentPane.id)

        try await harness.coordinator.undoCloseTab()

        #expect(harness.coordinator.undoStack.count == 1)
        #expect(harness.store.pane(drawerPane.id) == nil)
    }

    @Test("undoTabClose preserves all arrangements after renderer failures")
    func undoTabClose_preservesAllArrangementsAfterFailures() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let terminalPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Terminal")
        let tab = Tab(paneId: terminalPane.id)
        harness.store.appendTab(tab)
        guard
            let terminalOnlyArrangementId = harness.store.createArrangement(
                name: "Terminal only",
                inTab: tab.id
            )
        else {
            Issue.record("Expected arrangement creation to succeed")
            return
        }
        harness.store.switchArrangement(to: terminalOnlyArrangementId, inTab: tab.id)
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        #expect(harness.store.tab(tab.id)?.activeArrangementId == terminalOnlyArrangementId)
    }

    @Test("tab close undo reattaches the retained surface without repository enrichment")
    func tabCloseUndoReattachesRetainedSurfaceWithoutRepositoryEnrichment() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        // Arrange: a floating terminal pane (no worktree/repo) with a mounted view, closed via tab close.
        let pane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        let mountedView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: pane.id, title: "Terminal")
        harness.coordinator.registerHostedView(mountedView: mountedView, for: pane.id)

        let retainedSurface = ManagedSurface(
            surface: Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(),
                appCommandDispatcher: NoOpAppCommandDispatcher()
            ),
            metadata: SurfaceMetadata(paneId: pane.id)
        )
        harness.surfaceManager.undoCloseResults = [retainedSurface]

        // Act
        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        // Assert: the retained surface is reattached; no fresh surface is created.
        #expect(harness.surfaceManager.attachCalls.map(\.surfaceID) == [retainedSurface.id])
        #expect(harness.surfaceManager.createSurfaceCallCount == 0)
    }

    @Test("pane close undo still reattaches the retained surface")
    func paneCloseUndoStillReattachesRetainedSurface() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        // Arrange: a worktree-bound terminal pane with a mounted view, closed via pane close.
        // Uses the repo's admitted main worktree (not `makeRepoAndWorktree`'s synthetic nested
        // worktree, which reconciles to an unavailable repo and never stamps facets onto the pane).
        let (repo, worktree) = makeAdmittedRepoAndWorktree(harness.store, root: harness.tempDir)
        let anchor = makeWebviewPane(harness.store, title: "Anchor")
        let terminal = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Terminal")
        let tab = Tab(paneId: anchor.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.insertPane(
            terminal.id,
            inTab: tab.id,
            at: anchor.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        let mountedView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: terminal.id, title: "Terminal")
        harness.coordinator.registerHostedView(mountedView: mountedView, for: terminal.id)

        let retainedSurface = ManagedSurface(
            surface: Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(),
                appCommandDispatcher: NoOpAppCommandDispatcher()
            ),
            metadata: SurfaceMetadata(paneId: terminal.id)
        )
        harness.surfaceManager.undoCloseResults = [retainedSurface]

        // Act
        try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: terminal.id))
        try await harness.coordinator.undoCloseTab()

        // Assert: pane-close undo already reuses the retained surface — pin this today and after the fix.
        #expect(harness.surfaceManager.attachCalls.map(\.surfaceID) == [retainedSurface.id])
        #expect(harness.surfaceManager.createSurfaceCallCount == 0)
    }

    @Test("tab close undo reuses retained surfaces when stack order differs from snapshot order")
    func tabCloseUndoReusesRetainedSurfacesWhenStackOrderDiffersFromSnapshotOrder() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        // Arrange: two floating terminal panes in one tab, each with a mounted view and a
        // retained surface. The mock's retained list is ordered so LIFO popping yields the
        // wrong pane first for the coordinator's reversed snapshot-panes iteration.
        let firstPane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let secondPane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let tab = Tab(paneId: firstPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.insertPane(
            secondPane.id,
            inTab: tab.id,
            at: firstPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        let firstMountedView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: firstPane.id, title: "First")
        harness.coordinator.registerHostedView(mountedView: firstMountedView, for: firstPane.id)
        let secondMountedView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: secondPane.id, title: "Second")
        harness.coordinator.registerHostedView(mountedView: secondMountedView, for: secondPane.id)

        let retainedFirst = ManagedSurface(
            surface: Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(),
                appCommandDispatcher: NoOpAppCommandDispatcher()
            ),
            metadata: SurfaceMetadata(paneId: firstPane.id)
        )
        let retainedSecond = ManagedSurface(
            surface: Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(),
                appCommandDispatcher: NoOpAppCommandDispatcher()
            ),
            metadata: SurfaceMetadata(paneId: secondPane.id)
        )
        // The mock pops LIFO from the end of this array (mirroring SurfaceManager's undo stack).
        // Ordered [retainedSecond, retainedFirst], the first pop yields retainedFirst, which
        // mismatches the coordinator's reversed snapshot.panes iteration (secondPane restores
        // first).
        harness.surfaceManager.undoCloseResults = [retainedSecond, retainedFirst]

        // Act
        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        // Assert: both retained surfaces are reused by pane id; no fresh surface is created.
        #expect(harness.surfaceManager.createSurfaceCallCount == 0)
        #expect(
            Set(harness.surfaceManager.attachCalls.map(\.surfaceID))
                == Set([retainedFirst.id, retainedSecond.id])
        )
    }

    @Test("undo without a retained surface falls back to fresh creation")
    func undoWithoutRetainedSurfaceFallsBackToFreshCreation() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        // Arrange: a floating terminal pane with no retained surface available on undo.
        let pane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        let mountedView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: pane.id, title: "Terminal")
        harness.coordinator.registerHostedView(mountedView: mountedView, for: pane.id)

        // Act
        try await harness.coordinator.execute(.closeTab(tabId: tab.id))
        try await harness.coordinator.undoCloseTab()

        // Assert: with no retained surface to pop, restore falls back to fresh surface creation.
        #expect(harness.surfaceManager.createSurfaceCallCount == 1)
    }
}

@MainActor
private final class UndoRestoreSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    private(set) var releasedUndoPaneIDs = Set<UUID>()
    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) { releasedUndoPaneIDs.formUnion(paneIDs) }

    private let createSurfaceResult: Result<ManagedSurface, SurfaceError>
    /// Retained surfaces looked up by pane id via `undoClose(forPaneId:)`, mirroring `SurfaceManager`'s undo stack.
    var undoCloseResults: [ManagedSurface]
    private(set) var attachCalls: [(surfaceID: UUID, paneID: UUID)] = []
    private(set) var createSurfaceCallCount = 0

    init(
        createSurfaceResult: Result<ManagedSurface, SurfaceError>,
        undoCloseResults: [ManagedSurface] = []
    ) {
        self.createSurfaceResult = createSurfaceResult
        self.undoCloseResults = undoCloseResults
    }

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        createSurfaceCallCount += 1
        return createSurfaceResult
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        attachCalls.append((surfaceID: surfaceId, paneID: paneId))
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? {
        guard let index = undoCloseResults.lastIndex(where: { $0.metadata.paneId == paneId }) else {
            return nil
        }
        return undoCloseResults.remove(at: index)
    }

    func destroy(_ surfaceId: UUID) {}
}

/// No-op dispatcher used only to satisfy `Ghostty.SurfaceView`'s bare test initializer.
@MainActor
private final class NoOpAppCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
