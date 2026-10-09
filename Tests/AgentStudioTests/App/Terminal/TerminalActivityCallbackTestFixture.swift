import Foundation

@testable import AgentStudioCore
@testable import AgentStudioTerminal

/// Reverse activity control uses the same owned handler boundary as startup.
@MainActor
final class TerminalActivityCallbackTestFixture {
    weak var router: TerminalActivityRouter?
    private lazy var host: GhosttyActionRoutingHost = .init(
        dependencies: .init(
            runtimeRegistry: RuntimeRegistry(),
            routingLookup: ActivityCallbackTestLookup(),
            mountedHostResolver: .init(surfaceForID: { _ in nil }, paneIDForSurfaceID: { _ in nil }),
            applyNativeView: { _, _, _ in .dropped(.staleSurface) },
            activityContext: { [weak self] in self?.router?.sourceInputContext(paneID: $0) },
            submitActivityInput: { [weak self] in await self?.router?.consumeSourceInputIfAccepting($0) },
            startupTraceRecorder: nil,
            traceRuntime: nil
        ))
    lazy var handler: Ghostty.ActionRouter = .init(host: host)

    func closeAndJoin() async {
        await handler.retire()
    }
}

@MainActor
private final class ActivityCallbackTestLookup: GhosttyActionRoutingLookup {
    func surfaceId(forViewObjectId _: ObjectIdentifier) -> UUID? { nil }
    func paneId(for surfaceId: UUID) -> UUID? { surfaceId }
}
