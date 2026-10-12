import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore

func makeTestPaneRuntimeEventBus() -> EventBus<RuntimeEnvelope> {
    EventBus(
        replayConfiguration: .init(
            capacityPerSource: 256,
            sourceKey: { envelope in
                envelope.source.description
            }
        )
    )
}

@MainActor
func makeTestWorkspaceSurfaceCoordinator(
    store: WorkspaceStore,
    viewRegistry: ViewRegistry,
    runtime: SessionRuntime,
    surfaceManager: WorkspaceSurfaceManaging,
    runtimeRegistry: RuntimeRegistry,
    paneEventBus: EventBus<RuntimeEnvelope> = makeTestPaneRuntimeEventBus(),
    windowLifecycleStore: WindowLifecycleAtom = WindowLifecycleAtom(),
    bridgePaneAttendance: BridgePaneAttendanceAtom = BridgePaneAttendanceAtom()
) -> WorkspaceSurfaceCoordinator {
    WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: viewRegistry,
        runtime: runtime,
        surfaceManager: surfaceManager,
        terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
        terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
        runtimeRegistry: runtimeRegistry,
        paneEventBus: paneEventBus,
        windowLifecycleStore: windowLifecycleStore,
        ipcLifecycle: .testUnavailable,
        bridgePaneAttendance: bridgePaneAttendance
    )
}

@MainActor
func eventually(
    _ description: String,
    timeout: Duration = .seconds(5),
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if condition() {
            return
        }
        await Task.yield()
    }
    #expect(condition(), "\(description) timed out")
}

@MainActor
final class ExactEventAcknowledgement<Event: Sendable> {
    private var recordedEvents: [Event] = []
    private var waiters:
        [(
            predicate: (Event) -> Bool,
            continuation: CheckedContinuation<Event, Never>
        )] = []

    func record(_ event: Event) {
        guard let waiterIndex = waiters.firstIndex(where: { $0.predicate(event) }) else {
            recordedEvents.append(event)
            return
        }

        let waiter = waiters.remove(at: waiterIndex)
        waiter.continuation.resume(returning: event)
    }

    func wait(where predicate: @escaping (Event) -> Bool) async -> Event {
        if let eventIndex = recordedEvents.firstIndex(where: predicate) {
            return recordedEvents.remove(at: eventIndex)
        }

        return await withCheckedContinuation { continuation in
            waiters.append((predicate, continuation))
        }
    }
}
