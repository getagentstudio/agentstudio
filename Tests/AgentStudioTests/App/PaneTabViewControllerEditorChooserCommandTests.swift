import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneTabViewControllerEditorChooserCommandTests {
    private struct Harness {
        let store: WorkspaceStore
        let controller: PaneTabViewController
        let editorChooser: EditorChooserState
        let tempDir: URL
    }

    init() {
        installTestCoreAtomsIfNeeded()
    }

    private func makeHarness(installedEditorTargets: [ExternalEditorTarget]) -> Harness {
        atom(\.workspaceSidebarState).clear()

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-editor-chooser-command-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let runtimeRegistry = RuntimeRegistry()
        let surfaceManager = MockEditorChooserCommandSurfaceManager(
            createSurfaceResult: .failure(.ghosttyNotInitialized)
        )
        let appLifecycleStore = AppLifecycleAtom()
        let windowLifecycleStore = WindowLifecycleAtom()
        let applicationLifecycleMonitor = ApplicationLifecycleMonitor(
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore
        )
        let bridgePaneAttendance = BridgePaneAttendanceAtom()
        let editorPreference = EditorPreferenceAtom()
        let editorChooserRuntime = EditorChooserRuntimeAtom()
        let editorChooser = EditorChooserState(
            preferenceAtom: editorPreference,
            runtimeAtom: editorChooserRuntime
        )
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: runtimeRegistry,
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: bridgePaneAttendance
        )
        let controller = PaneTabViewController(
            store: store,
            octiconLoader: makeTestOcticonLoader(),
            repoCache: RepoCacheAtom(),
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            appLifecycleStore: appLifecycleStore,
            executor: WorkspaceActionExecutor(coordinator: coordinator, store: store),
            runtimeCommandDispatcher: coordinator,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(), synchronizeRuntimeFocus: { _ in },
            tabBarAdapter: TabBarAdapter(
                store: store,
                repoCache: RepoCacheAtom(),
            ),
            viewRegistry: viewRegistry,
            bridgePaneAttendance: bridgePaneAttendance,
            editorChooser: editorChooser,
            installedEditorTargetsProvider: { installedEditorTargets },
            openEditorHandler: { _, _, _ in true },
            openFinderHandler: { _ in true },
            heldPanePreviewState: HeldPanePreviewState(),
            registersAsCommandHandler: false
        )

        return Harness(
            store: store,
            controller: controller,
            editorChooser: editorChooser,
            tempDir: tempDir
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
        return (repo, worktree)
    }

    @Test("openPaneLocationInEditorMenu refreshes available editor targets before opening")
    func executeOpenPaneLocationInEditorMenu_refreshesTargetsAndOpensChooser() {
        let harness = makeHarness(installedEditorTargets: [.cursor, .vscode])
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            title: "Parent",
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        harness.controller.execute(.openPaneLocationInEditorMenu)

        #expect(harness.editorChooser.openForPaneId == pane.id)
        #expect(harness.editorChooser.availableTargets.map(\.id) == ["cursor", "vscode"])
    }

    @Test("openPaneLocationInEditorMenu toggles closed when already open for the selected pane")
    func executeOpenPaneLocationInEditorMenu_whenAlreadyOpen_closesChooser() {
        let harness = makeHarness(installedEditorTargets: [.cursor, .vscode])
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            title: "Parent",
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.editorChooser.setOpenEditorPane(pane.id)

        harness.controller.execute(.openPaneLocationInEditorMenu)

        #expect(harness.editorChooser.openForPaneId == nil)
    }
}

private final class MockEditorChooserCommandSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    private let createSurfaceResult: Result<ManagedSurface, SurfaceError>

    init(createSurfaceResult: Result<ManagedSurface, SurfaceError>) {
        self.createSurfaceResult = createSurfaceResult
    }

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config _: Ghostty.SurfaceConfiguration,
        metadata _: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        createSurfaceResult
    }

    @discardableResult
    func attach(_: UUID, to _: UUID) -> Ghostty.SurfaceView? { nil }

    func detach(_: UUID, reason _: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }
    func destroy(_: UUID) {}
}
