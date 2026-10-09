@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
func makeTestAtomRegistry() -> AtomRegistry {
    AtomRegistry(core: makeInstalledTestCoreAtoms())
}

@MainActor
func makeInstalledTestAtomRegistry() -> AtomRegistry {
    installTestCoreAtomsIfNeeded()
    return makeTestAtomRegistry()
}

@MainActor
func installTestAtomRegistryIfNeeded() {
    installTestCoreAtomsIfNeeded()
}

@MainActor
func withTestAtomRegistry<T>(
    _ body: (AtomRegistry) throws -> T
) rethrows -> T {
    let atomRegistry = makeInstalledTestAtomRegistry()
    return try CoreAtomScope.$override.withValue(atomRegistry.core) {
        try body(atomRegistry)
    }
}

@MainActor
func withAsyncTestAtomRegistry<T>(
    _ body: (AtomRegistry) async throws -> T
) async rethrows -> T {
    let atomRegistry = makeInstalledTestAtomRegistry()
    return try await CoreAtomScope.$override.withValue(atomRegistry.core) {
        try await body(atomRegistry)
    }
}

@MainActor
func makeTestOcticonLoader() -> OcticonLoader {
    OcticonLoader(resourceBundle: Bundle.appResources)
}
