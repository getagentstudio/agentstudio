import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
struct BridgePaneActivityTestHarness {
    let store: WorkspaceStore
    let viewRegistry: ViewRegistry
    let appLifecycleStore: AppLifecycleAtom
    let windowLifecycleStore: WindowLifecycleAtom
    let paneEventBus: EventBus<RuntimeEnvelope>
    let coordinator: WorkspaceSurfaceCoordinator
    let bridgePane: Pane
    let siblingPane: Pane
    let tabId: UUID
    let alternateArrangementId: UUID
    let owningWindowId: UUID
    let tempDirectory: URL

    func finish() async {
        await coordinator.shutdown()
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

@MainActor
func makeBridgePaneActivityTestHarness(
    includeSiblingInTab: Bool = true,
    store: WorkspaceStore = WorkspaceStore(),
    filesystemProjectionIndex: (any WorkspaceFilesystemProjectionIndexing)? = nil,
    traceRuntime: AgentStudioTraceRuntime? = nil,
    worktreeProductConstructionCoordinator: BridgeWorktreeProductConstructionCoordinator =
        BridgeWorktreeProductConstructionCoordinator()
) -> BridgePaneActivityTestHarness {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "agentstudio-bridge-pane-activity-\(UUID().uuidString)")
    let bridgePane = store.createPane(
        content: .bridgePanel(
            BridgePaneState(
                panelKind: .diffViewer,
                source: .commit(sha: "activity-integration")
            )
        ),
        metadata: PaneMetadata(
            title: "Review",
            facets: PaneContextFacets(cwd: tempDirectory)
        )
    )
    let siblingPane = store.createPane(
        content: .webview(
            WebviewState(url: URL(string: "https://example.com/activity-sibling")!)
        ),
        metadata: PaneMetadata(title: "Sibling")
    )
    let tab: Tab
    let alternateArrangementId: UUID
    if includeSiblingInTab {
        let defaultArrangement = PaneArrangement(
            name: "Default",
            isDefault: true,
            layout: .autoTiled([bridgePane.id, siblingPane.id]),
            activePaneId: bridgePane.id
        )
        let alternateArrangement = PaneArrangement(
            name: "Sibling only",
            isDefault: false,
            layout: Layout(paneId: siblingPane.id),
            activePaneId: siblingPane.id
        )
        tab = Tab(
            name: "Activity",
            allPaneIds: [bridgePane.id, siblingPane.id],
            arrangements: [defaultArrangement, alternateArrangement],
            activeArrangementId: defaultArrangement.id
        )
        alternateArrangementId = alternateArrangement.id
    } else {
        tab = Tab(paneId: bridgePane.id, name: "Activity")
        alternateArrangementId = tab.activeArrangementId
    }
    store.appendTab(tab)
    store.setActiveTab(tab.id)

    let viewRegistry = ViewRegistry()
    viewRegistry.ensureSlot(for: bridgePane.id)
    viewRegistry.ensureSlot(for: siblingPane.id)
    let appLifecycleStore = AppLifecycleAtom()
    let windowLifecycleStore = WindowLifecycleAtom()
    let owningWindowId = UUID()
    let paneEventBus = makeTestPaneRuntimeEventBus()
    let coordinator = WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: viewRegistry,
        runtime: SessionRuntime(store: store),
        surfaceManager: BridgeActivityIntegrationSurfaceManager(),
        terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
        terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
        runtimeRegistry: RuntimeRegistry(),
        paneEventBus: paneEventBus,
        worktreeProductConstructionCoordinator: worktreeProductConstructionCoordinator,
        filesystemProjectionIndex: filesystemProjectionIndex,
        windowLifecycleStore: windowLifecycleStore,
        appLifecycleStore: appLifecycleStore,
        ipcLifecycle: .testUnavailable,
        bridgePaneAttendance: BridgePaneAttendanceAtom(),
        traceRuntime: traceRuntime
    )
    coordinator.startBridgePaneActivityObservation()

    return BridgePaneActivityTestHarness(
        store: store,
        viewRegistry: viewRegistry,
        appLifecycleStore: appLifecycleStore,
        windowLifecycleStore: windowLifecycleStore,
        paneEventBus: paneEventBus,
        coordinator: coordinator,
        bridgePane: bridgePane,
        siblingPane: siblingPane,
        tabId: tab.id,
        alternateArrangementId: alternateArrangementId,
        owningWindowId: owningWindowId,
        tempDirectory: tempDirectory
    )
}

@MainActor
func installBridgeControllerAndEnterForeground(
    _ harness: BridgePaneActivityTestHarness
) async throws {
    enterForegroundNativeEnvironment(harness)
    _ = try #require(harness.coordinator.createViewForContent(pane: harness.bridgePane))
    await expectBridgePaneActivity(
        .foreground,
        for: harness.bridgePane.id,
        in: harness.coordinator,
        because: "the controller is installed in the active native surface"
    )
}

func initializeBridgeReviewGitFixture(at repositoryURL: URL) async throws {
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["init"])
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["symbolic-ref", "HEAD", "refs/heads/main"])
    try await FilesystemTestGitRepo.runGit(
        at: repositoryURL,
        args: [
            "-c", "user.name=Bridge Fixture", "-c", "user.email=bridge-fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial fixture snapshot",
        ])
}

@MainActor
func enterForegroundNativeEnvironment(_ harness: BridgePaneActivityTestHarness) {
    harness.appLifecycleStore.setActive(true)
    harness.windowLifecycleStore.recordWindowRegistered(harness.owningWindowId)
    harness.windowLifecycleStore.recordWindowPresentation(
        WindowPresentationFacts(
            isVisible: true,
            isMiniaturized: false,
            isOccluded: false
        ),
        for: harness.owningWindowId
    )
}

@MainActor
func expectBridgePaneActivity(
    _ expectedActivity: BridgePaneActivity,
    for paneId: UUID,
    in coordinator: WorkspaceSurfaceCoordinator,
    because description: String,
    maxTurns: Int = 200
) async {
    for _ in 0..<maxTurns {
        if coordinator.bridgePaneActivity(for: paneId) == expectedActivity {
            return
        }
        await Task.yield()
    }
    #expect(
        coordinator.bridgePaneActivity(for: paneId) == expectedActivity,
        "Expected \(expectedActivity.rawValue) because \(description)"
    )
}

@MainActor
final class BridgeActivityIntegrationSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {}
}
