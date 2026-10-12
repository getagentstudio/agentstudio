func makeFakeOwners() {
    let dispatcher = AppCommandDispatcher(dependencies: fakeDependencies)
    let registry = RuntimeRegistry()
    let lookup = SurfaceManager(appCommandDispatcher: dispatcher, engineAccess: { .unavailable })
    let handling = Ghostty.ActionRouter(host: fakeHost)
}
