typealias NativeEngineAlias = Ghostty.App

func constructOutsideStartup() {
    let engine = Ghostty.App(callbackHandling: handler)
    let callbackFactory = Ghostty.ActionRouter.init(host: host)
}

enum AmbientRegistry {
    static let registry = RuntimeRegistry()
}

func consume(dispatcher: AppCommandDispatcher = .shared) {}

extension AppDelegate {
    func reset() {
        self.startupNativeEngine = replacement
    }
}
