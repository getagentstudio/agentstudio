import AgentStudioInfrastructure
import Foundation

@testable import AgentStudioCore
@testable import AgentStudioTerminal

/// Owns the same manager -> host -> router injection graph as App boot, with no native engine.
@MainActor
final class RestorePhaseCallbackTestFixture {
    private var registeredSurfaceIDs: [UUID] = []
    let projector: TerminalActivityProjector
    var inputObserved: @MainActor (TerminalActivitySourceInput) -> Void = { _ in }

    // Factories with explicit return types keep this lazy graph out of type inference
    // (each property's initializer captures the others, so inference would be circular).
    lazy var manager: SurfaceManager = makeManager()
    private lazy var host: GhosttyActionRoutingHost = makeHost()
    lazy var handler: Ghostty.ActionRouter = makeHandler()
    lazy var router: TerminalActivityRouter = makeRouter()

    init(projector: TerminalActivityProjector) {
        self.projector = projector
    }

    func register(_ surface: Ghostty.SurfaceView, paneID: UUID) {
        registeredSurfaceIDs.append(surface.managedSurfaceID)
        _ = manager.acceptCreatedSurface(surface, metadata: SurfaceMetadata(paneId: paneID))
        manager.attach(surface.managedSurfaceID, to: paneID)
    }

    func closeAndJoin() async {
        await handler.retire()
        await router.stop()
        for surfaceID in registeredSurfaceIDs { manager.destroy(surfaceID) }
        registeredSurfaceIDs.removeAll()
    }

    private func makeManager() -> SurfaceManager {
        SurfaceManager(
            appCommandDispatcher: AppTerminalFixtureCommandDispatcher(),
            engineAccess: { .unavailable },
            callbackHandlingAccess: { [weak self] in self?.handler }
        )
    }

    private func makeHost() -> GhosttyActionRoutingHost {
        GhosttyActionRoutingHost(
            dependencies: .init(
                runtimeRegistry: RuntimeRegistry(),
                routingLookup: manager,
                mountedHostResolver: .init(
                    surfaceForID: { [weak self] in self?.manager.surface(for: $0) },
                    paneIDForSurfaceID: { [weak self] in self?.manager.paneId(for: $0) }
                ),
                applyNativeView: { _, _, _ in .dropped(.engineUnavailable) },
                activityContext: { [weak self] in self?.router.sourceInputContext(paneID: $0) },
                submitActivityInput: { [weak self] input in
                    guard let self else { return }
                    await router.consumeSourceInputIfAccepting(input)
                    inputObserved(input)
                },
                startupTraceRecorder: nil,
                traceRuntime: nil
            )
        )
    }

    private func makeHandler() -> Ghostty.ActionRouter {
        Ghostty.ActionRouter(host: host)
    }

    private func makeRouter() -> TerminalActivityRouter {
        TerminalActivityRouter(
            bus: EventBus<RuntimeEnvelope>(),
            activityAtom: TerminalActivityAtom(),
            callbackHandlingAccess: { [weak self] in self?.handler },
            projector: projector,
            surfaceIDForPaneID: { [weak self] in self?.manager.surfaceId(forPaneId: $0) },
            lastOutputLineReader: { _ in .surfaceStale }
        )
    }
}
