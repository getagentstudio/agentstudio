import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

@MainActor
struct GhosttyActionRouterTestFixtureConfiguration {
    var paneUUID = UUIDv7.generate()
    var surfaceID = UUIDv7.generate()
    var runtimeTitle = "Runtime"
    var registerRuntime = true
    var resolveMountedHost = true
    var nativeViewSurfaceID: UUID?
    var resolveMountedPane = true
    var mountedPaneUUID: UUID?
    var traceRuntime: AgentStudioTraceRuntime?
    var startupTraceRecorder: AgentStudioStartupTraceRecorder?
    var performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    var activityProjectionContext: TerminalActivityProjectionContext?
    var activityContextRead: @MainActor (UUID) -> Void = { _ in }
    var activityInputObserved: @MainActor (TerminalActivitySourceInput) async -> Void = { _ in }
}

@MainActor
final class GhosttyActionRouterTestFixture {
    let paneUUID: UUID
    let surfaceID: UUID
    let surfaceViewObjectID: ObjectIdentifier
    let runtime: TerminalRuntime
    let runtimeRegistry: RuntimeRegistry
    let routingLookup: GhosttyActionRouterTestRoutingLookup
    let nativeView: GhosttyActionRouterTestNativeView
    let activityInputRecorder: GhosttyActionRouterTestActivityInputRecorder
    let handler: Ghostty.ActionRouter

    private let performanceReporter: RuntimeDeliveryPerformanceReporter

    init(configuration: GhosttyActionRouterTestFixtureConfiguration = .init()) {
        let paneUUID = configuration.paneUUID
        let surfaceID = configuration.surfaceID
        self.paneUUID = paneUUID
        self.surfaceID = surfaceID

        let paneID = PaneId(existingUUID: paneUUID)
        let runtimeRegistry = RuntimeRegistry()
        let performanceReporter = RuntimeDeliveryPerformanceReporter()
        performanceReporter.enable()
        let eventBus = EventBus<RuntimeEnvelope>(performanceReporter: performanceReporter)
        let runtime = TerminalRuntime(
            paneId: paneID,
            metadata: PaneMetadata(paneId: paneID, contentType: .terminal, title: configuration.runtimeTitle),
            paneEventBus: eventBus,
            performanceReporter: performanceReporter,
            surfaceCommandDispatcher: GhosttyActionRouterTestSurfaceCommands(),
            openExternalURL: { _ in }
        )
        runtime.transitionToReady()
        if configuration.registerRuntime {
            _ = runtimeRegistry.register(runtime)
        }

        let nativeView = GhosttyActionRouterTestNativeView(
            managedSurfaceID: configuration.nativeViewSurfaceID ?? surfaceID,
            performanceTraceRecorder: configuration.performanceTraceRecorder
        )
        let surfaceViewObjectID = ObjectIdentifier(nativeView)
        let routingLookup = GhosttyActionRouterTestRoutingLookup(
            surfaceIDsByViewObjectID: [surfaceViewObjectID: surfaceID],
            paneIDsBySurfaceID: [surfaceID: paneUUID]
        )
        let activityInputRecorder = GhosttyActionRouterTestActivityInputRecorder()
        let host = GhosttyActionRoutingHost(
            dependencies: .init(
                runtimeRegistry: runtimeRegistry,
                routingLookup: routingLookup,
                mountedHostResolver: TerminalLocalActionMountedHostResolver(
                    surfaceForID: { requestedSurfaceID in
                        guard configuration.resolveMountedHost else { return nil }
                        return requestedSurfaceID == surfaceID ? nativeView : nil
                    },
                    paneIDForSurfaceID: { requestedSurfaceID in
                        guard configuration.resolveMountedPane, requestedSurfaceID == surfaceID else { return nil }
                        return configuration.mountedPaneUUID ?? paneUUID
                    }
                ),
                applyNativeView: { requestedSurfaceID, viewObjectID, update in
                    nativeView.apply(
                        surfaceID: requestedSurfaceID,
                        viewObjectID: viewObjectID,
                        update: update
                    )
                },
                activityContext: { requestedPaneUUID in
                    configuration.activityContextRead(requestedPaneUUID)
                    return requestedPaneUUID == paneUUID ? configuration.activityProjectionContext : nil
                },
                submitActivityInput: { input in
                    let runtimeWasEmpty = (await runtime.eventsSince(seq: 0)).events.isEmpty
                    activityInputRecorder.record(input, runtimeWasEmptyAtInput: runtimeWasEmpty)
                    await configuration.activityInputObserved(input)
                },
                startupTraceRecorder: configuration.startupTraceRecorder,
                traceRuntime: configuration.traceRuntime
            )
        )

        self.runtime = runtime
        self.runtimeRegistry = runtimeRegistry
        self.routingLookup = routingLookup
        self.nativeView = nativeView
        self.surfaceViewObjectID = surfaceViewObjectID
        self.activityInputRecorder = activityInputRecorder
        self.performanceReporter = performanceReporter
        self.handler = Ghostty.ActionRouter(host: host)
    }

    func route(
        _ actionTag: GhosttyActionTag,
        _ payload: GhosttyActionPayload,
        surfaceViewObjectID: ObjectIdentifier? = nil
    ) -> Bool {
        handler.routeActionToTerminalRuntimeOnMainActor(
            actionTag: actionTag.rawValue,
            payload: payload,
            surfaceViewObjectId: surfaceViewObjectID ?? self.surfaceViewObjectID
        )
    }

    func closeAndJoin() async {
        await handler.retire()
        _ = await runtime.shutdown(timeout: .seconds(1))
        await runtime.finishAndJoinOutboundDelivery()
        #expect(performanceReporter.snapshot().runtimeChannelOutboundPendingCount == 0)
    }
}

@MainActor
func withGhosttyActionRouterTestFixture<Output>(
    configuration: GhosttyActionRouterTestFixtureConfiguration = .init(),
    operation: (GhosttyActionRouterTestFixture) async throws -> Output
) async throws -> Output {
    let fixture = GhosttyActionRouterTestFixture(configuration: configuration)
    do {
        let output = try await operation(fixture)
        await fixture.closeAndJoin()
        return output
    } catch {
        await fixture.closeAndJoin()
        throw error
    }
}

@MainActor
final class GhosttyActionRouterTestRoutingLookup: GhosttyActionRoutingLookup {
    private var surfaceIDsByViewObjectID: [ObjectIdentifier: UUID]
    private var paneIDsBySurfaceID: [UUID: UUID]
    var onSurfaceLookup: (@MainActor (ObjectIdentifier) -> Void)?

    init(
        surfaceIDsByViewObjectID: [ObjectIdentifier: UUID] = [:],
        paneIDsBySurfaceID: [UUID: UUID] = [:]
    ) {
        self.surfaceIDsByViewObjectID = surfaceIDsByViewObjectID
        self.paneIDsBySurfaceID = paneIDsBySurfaceID
    }

    func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID? {
        onSurfaceLookup?(viewObjectId)
        return surfaceIDsByViewObjectID[viewObjectId]
    }

    func paneId(for surfaceId: UUID) -> UUID? {
        paneIDsBySurfaceID[surfaceId]
    }

    func mapSurface(_ surfaceID: UUID?, for viewObjectID: ObjectIdentifier) {
        surfaceIDsByViewObjectID[viewObjectID] = surfaceID
    }

    func mapPane(_ paneID: UUID?, for surfaceID: UUID) {
        paneIDsBySurfaceID[surfaceID] = paneID
    }
}

@MainActor
final class GhosttyActionRouterTestNativeView: TerminalLocalActionDrainHost {
    let managedSurfaceID: UUID
    var hostScrollbarState: ScrollbarState?
    private(set) var title: String
    private(set) var workingDirectory: String?
    private(set) var reportedInitialSize: (UInt32, UInt32)?
    private(set) var reportedCellSize: (UInt32, UInt32)?
    private(set) var nativeUpdates: [GhosttyDirectHostUpdate] = []
    var onScrollbarStateChanged: (@MainActor (ScrollbarState) -> Void)?
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    init(
        managedSurfaceID: UUID,
        title: String = "",
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    ) {
        self.managedSurfaceID = managedSurfaceID
        self.title = title
        self.performanceTraceRecorder = performanceTraceRecorder
    }

    func updateHostScrollbarState(_ state: ScrollbarState) {
        hostScrollbarState = state
        onScrollbarStateChanged?(state)
    }

    func titleDidChange(_ title: String) {
        self.title = title
    }

    func apply(
        surfaceID: UUID,
        viewObjectID: ObjectIdentifier,
        update: GhosttyDirectHostUpdate
    ) -> GhosttyDeferredApplyResult {
        guard surfaceID == managedSurfaceID, viewObjectID == ObjectIdentifier(self) else {
            return .dropped(.staleSurface)
        }
        nativeUpdates.append(update)
        switch update {
        case .closeRequested:
            break
        case .workingDirectory(let path):
            workingDirectory = path
        case .reportedInitialSize(let width, let height):
            reportedInitialSize = (width, height)
        case .reportedCellSize(let width, let height):
            reportedCellSize = (width, height)
        case .cache(let tag, let payload):
            guard GhosttyActionTag(rawValue: tag) == .scrollbar,
                case .scrollbar(let total, let offset, let length) = payload
            else { return .applied }
            updateHostScrollbarState(
                ScrollbarState(top: Int(offset), bottom: Int(offset + length), total: Int(total))
            )
        }
        return .applied
    }
}

@MainActor
final class GhosttyActionRouterTestActivityInputRecorder {
    private(set) var inputs: [TerminalActivitySourceInput] = []
    private(set) var runtimeWasEmptyAtInput: [Bool] = []

    func record(_ input: TerminalActivitySourceInput, runtimeWasEmptyAtInput: Bool) {
        inputs.append(input)
        self.runtimeWasEmptyAtInput.append(runtimeWasEmptyAtInput)
    }
}

@MainActor
private final class GhosttyActionRouterTestSurfaceCommands: TerminalSurfaceCommandDispatching {
    func sendInput(_: String, toPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
    func clearScrollback(forPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
    func scrollToBottom(forPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
    func scrollPageFractional(fraction _: Double, forPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
    func jumpToPrompt(delta _: Int, forPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
}
