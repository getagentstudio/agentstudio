import Testing

@testable import AgentStudioArchitectureLintCore

@Suite("Composition-root construction boundary")
struct CompositionRootConstructionRuleTests {
    private static let ruleID = "agentstudio_composition_root_construction"

    @Test("startup constructors and private lazy construction are admitted")
    func permitsStartupHomes() {
        #expect(
            lint("let engine = Ghostty.App(callbackHandling: handler)", path: "Sources/AgentStudio/main.swift").isEmpty)
        #expect(
            lint(
                """
                final class AppDelegate {
                    let startupRuntimeRegistry = RuntimeRegistry()
                    private lazy var startupNativeEngine: Ghostty.App = .init(callbackHandling: handler)
                    private lazy var startupCallbackHandling: Ghostty.ActionRouter = .init(host: host)
                    init() { let handler = Ghostty.ActionRouter(host: host) }
                }
                """, path: "Sources/AgentStudio/App/Boot/AppDelegate.swift"
            ).isEmpty)
    }

    @Test("Terminal constructors may construct private native children")
    func permitsTerminalPrivateChildren() {
        #expect(
            lint(
                """
                extension Ghostty {
                    final class App {
                        init() { let handle = AppHandle(runtimeConfig: config, callbackContext: context) }
                    }
                }
                """, path: "Sources/AgentStudio/Features/Terminal/Ghostty/Ghostty.swift"
            ).isEmpty)
    }

    @Test("fake-facing test handling and local dispatcher registry lookup fixtures are admitted")
    func permitsOwnedTestFixtures() {
        #expect(
            lint(
                """
                func makeFixture() {
                    let dispatcher = AppCommandDispatcher(dependencies: dependencies)
                    let registry = RuntimeRegistry()
                    let lookup = SurfaceManager(appCommandDispatcher: dispatcher, engineAccess: { .unavailable })
                    let handling = Ghostty.ActionRouter(host: fakeHost)
                }
                """, path: "Tests/AgentStudioTests/Fixture.swift"
            ).isEmpty)
    }

    @Test(
        "native identity construction outside startup is rejected",
        arguments: [
            "func make() { let engine = Ghostty.App(callbackHandling: handler) }",
            "func make() { let engine = AgentStudioTerminal.Ghostty.App.init(callbackHandling: handler) }",
            "func make() { let engine: Ghostty.App = .init(callbackHandling: handler) }",
            "func make() -> Ghostty.App { return .init(callbackHandling: handler) }",
            "extension Ghostty.App { static func make() -> Self { Self(callbackHandling: handler) } }",
            "extension Ghostty.App { static func make() -> Self { Self.init(callbackHandling: handler) } }",
            "func make() { let handling = Ghostty.ActionRouter(host: host) }",
            "extension Ghostty { static func make() { let engine = App(callbackHandling: handler) } }",
            "extension Ghostty.App { static func make() -> Self { .init(callbackHandling: handler) } }",
            "typealias NativeEngine = Ghostty.App\nfunc make() { let engine = NativeEngine(callbackHandling: handler) }",
            "func make() { let factory = Ghostty.App.init }",
            "func make() { delegate.initializeNativeEngineForBoot() }",
        ])
    func rejectsOutsideConstruction(source: String) {
        expectError(lint(source))
    }

    @Test(
        "other selected identities retain construction restrictions through lexical context",
        arguments: [
            "extension Ghostty { static func make() { let handler = ActionRouter(host: host) } }",
            "extension Ghostty.ActionRouter { static func make() -> Self { Self(host: host) } }",
            "extension AppCommandDispatcher { static func make() -> Self { Self(dependencies: dependencies) } }",
            "extension RuntimeRegistry { static func make() -> Self { .init() } }",
            "extension SurfaceManager { static func make() -> Self { Self.init(dependencies: dependencies) } }",
            "extension Ghostty { typealias EscapedHandling = ActionRouter }",
            "func make() { let engine = Ghostty /* namespace */ . App(callbackHandling: handler) }",
        ])
    func rejectsContextualSelectedConstruction(source: String) {
        expectError(lint(source))
    }

    @Test(
        "typed implicit constructor defaults are not fixture-owned construction",
        arguments: [
            "func fixture(handler: Ghostty.ActionRouter = .init(host: host)) {}",
            "func fixture(dispatcher: AppCommandDispatcher = .init(dependencies: dependencies)) {}",
            "func fixture(registry: RuntimeRegistry = .init()) {}",
        ])
    func rejectsImplicitFixtureDefaults(source: String) {
        expectError(lint(source, path: "Tests/AgentStudioTests/Fixture.swift"))
    }

    @Test("a nested unrelated Self remains unrelated to the enclosing native engine")
    func permitsUnrelatedNestedSelf() {
        #expect(
            lint(
                """
                extension Ghostty.App {
                    struct FrameMetadata {
                        static func make() -> Self { Self() }
                    }
                }
                """
            ).isEmpty)
    }

    @Test("reading an already selected identity through a method is not construction")
    func permitsSelectedIdentityMethodReads() {
        #expect(
            lint(
                """
                func readRegistry() -> RuntimeRegistry { root.registryForCurrentContext() }
                func readDispatcher() -> AppCommandDispatcher { root.commandDispatcherForBoot() }
                """
            ).isEmpty)
    }

    @Test(
        "real engine and raw native creation are rejected in test fixtures",
        arguments: [
            "func fixture() { let engine = Ghostty.App(callbackHandling: handler) }",
            "func fixture() { let handle = Ghostty.AppHandle(runtimeConfig: config, callbackContext: context) }",
            "func fixture() { let app = ghostty_app_new(&config, nil) }",
            "func fixture() { delegate.initializeNativeEngineForBoot() }",
        ])
    func rejectsRealEngineFixtures(source: String) {
        expectError(lint(source, path: "Tests/AgentStudioTests/Fixture.swift"))
    }

    @Test(
        "a startup filename does not admit later methods or unrelated types",
        arguments: [
            "final class AppDelegate { func reset() { let engine = Ghostty.App(callbackHandling: handler) } }",
            "final class OtherOwner { init() { let engine = Ghostty.App(callbackHandling: handler) } }",
            "final class OtherOwner { final class AppDelegate { init() { let engine = Ghostty.App(callbackHandling: handler) } } }",
            "final class OtherOwner { final class AppDelegate { private lazy var startupNativeEngine = Ghostty.App(callbackHandling: handler) } }",
            "let engine = Ghostty.App(callbackHandling: handler)",
        ])
    func rejectsBroadFileExemption(source: String) {
        expectError(lint(source, path: "Sources/AgentStudio/App/Boot/AppDelegate.swift"))
    }

    @Test(
        "AppDelegate startup identity properties retain the private-lazy or immutable shape",
        arguments: [
            "final class AppDelegate { lazy var startupNativeEngine: Ghostty.App = .init(callbackHandling: handler) }",
            "final class AppDelegate { private var startupNativeEngine: Ghostty.App = .init(callbackHandling: handler) }",
            "final class AppDelegate { private let startupNativeEngine: Ghostty.App = .init(callbackHandling: handler) }",
            "final class AppDelegate { var startupRuntimeRegistry = RuntimeRegistry() }",
            "final class AppDelegate { private static let startupRuntimeRegistry = RuntimeRegistry() }",
        ])
    func rejectsMutableOrUnscopedStartupProperties(source: String) {
        expectError(lint(source, path: "Sources/AgentStudio/App/Boot/AppDelegate.swift"))
    }

    @Test(
        "selected objects cannot become ambient defaults",
        arguments: [
            "let handler = Ghostty.ActionRouter(host: fakeHost)",
            "enum Fixture { static let dispatcher = AppCommandDispatcher(dependencies: dependencies) }",
            "func consumer(dispatcher: AppCommandDispatcher = .shared) {}",
            "func consumer(registry: RuntimeRegistry = RuntimeRegistry.shared) {}",
            "func consumer(engine: Ghostty.App = Ghostty.App(callbackHandling: handler)) {}",
        ])
    func rejectsAmbientDefaults(source: String) {
        expectError(lint(source, path: "Tests/AgentStudioTests/Fixture.swift"))
    }

    @Test(
        "startup identities cannot be reset",
        arguments: [
            "startupCommandDispatcher", "startupTerminalLookup", "startupNativeEngine",
            "startupCallbackHandling", "startupRuntimeRegistry",
        ])
    func rejectsIdentityReset(property: String) {
        expectError(
            lint(
                "extension AppDelegate { func reset() { self.\(property) = replacement } }",
                path: "Sources/AgentStudio/App/Boot/AppDelegate+Later.swift"))
    }

    @Test("identity reads and unrelated constructors remain valid")
    func permitsReadsAndUnrelatedTypes() {
        #expect(
            lint(
                """
                func inspect() {
                    let same = root.startupNativeEngine === other.startupNativeEngine
                    let value = root.startupRuntimeRegistry
                    let model = Other.App()
                    let handle = Other.AppHandle()
                    let display = "Ghostty.App(callbackHandling: handler)"
                }
                """
            ).isEmpty)
    }

    @Test("the construction boundary is registered as an error")
    func registersBoundary() {
        #expect(ArchitectureRuleRegistry.rules.contains { $0.id == Self.ruleID && $0.severity == .error })
    }

    private func expectError(_ diagnostics: [ArchitectureDiagnostic]) {
        #expect(!diagnostics.isEmpty)
        #expect(diagnostics.allSatisfy { $0.ruleID == Self.ruleID && $0.severity == .error })
    }

    private func lint(_ source: String, path: String = "Sources/AgentStudio/App/Windows/OtherOwner.swift")
        -> [ArchitectureDiagnostic]
    {
        let context = LintTestSupport.repositoryContext(path: path, source: source)
        return ArchitectureRuleRegistry.rules.filter { $0.id == Self.ruleID }.flatMap { $0.validate(context: context) }
    }
}
