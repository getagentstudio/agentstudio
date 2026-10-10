import Foundation

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
struct WorkspaceSurfaceCoordinatorViewFactoryHarness {
    let store: WorkspaceStore
    let viewRegistry: ViewRegistry
    let runtime: SessionRuntime
    let coordinator: WorkspaceSurfaceCoordinator
    let tempDir: URL
}

@MainActor
func makeWorkspaceSurfaceCoordinatorViewFactoryHarness(
    paneEventBus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared
) -> WorkspaceSurfaceCoordinatorViewFactoryHarness {
    let tempDir = FileManager.default.temporaryDirectory
        .appending(path: "agentstudio-coordinator-tests-\(UUID().uuidString)")
    let store = WorkspaceStore()
    let viewRegistry = ViewRegistry()
    let runtime = SessionRuntime(store: store)
    let surfaceManager = makeAppTerminalFixtureSurfaceManager()
    let coordinator = WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: viewRegistry,
        runtime: runtime,
        surfaceManager: surfaceManager,
        terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
        terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
        runtimeRegistry: RuntimeRegistry(),
        paneEventBus: paneEventBus,
        windowLifecycleStore: WindowLifecycleAtom(),
        ipcLifecycle: .testUnavailable,
        bridgePaneAttendance: BridgePaneAttendanceAtom()
    )
    return WorkspaceSurfaceCoordinatorViewFactoryHarness(
        store: store,
        viewRegistry: viewRegistry,
        runtime: runtime,
        coordinator: coordinator,
        tempDir: tempDir
    )
}

@MainActor
func makeBridgeReplayEnvelope(paneId: PaneId, sequence: UInt64) -> RuntimeEnvelope {
    makeRuntimeEnvelope(
        source: .pane(paneId),
        paneKind: .diff,
        seq: sequence,
        commandId: nil,
        correlationId: nil,
        timestamp: ContinuousClock().now,
        epoch: 0,
        event: .lifecycle(.surfaceCreated)
    )
}
