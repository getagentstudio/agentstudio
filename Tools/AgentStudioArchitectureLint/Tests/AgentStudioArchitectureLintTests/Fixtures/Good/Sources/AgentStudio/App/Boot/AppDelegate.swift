final class AppDelegate {
    private lazy var startupCommandDispatcher = AppCommandDispatcher(dependencies: dependencies)
    let startupRuntimeRegistry = RuntimeRegistry()
    private lazy var startupTerminalLookup: SurfaceManager = .init(
        appCommandDispatcher: startupCommandDispatcher,
        engineAccess: { .unavailable }
    )
    private lazy var startupNativeEngine: Ghostty.App = .init(callbackHandling: startupCallbackHandling)
    private lazy var startupCallbackHandling: Ghostty.ActionRouter = .init(host: routingHost)

    init() {
        let callbackHandling = Ghostty.ActionRouter(host: fakeHost)
    }
}
