import Testing

@testable import AgentStudioArchitectureLintCore

@Suite("Process-wide singleton rule")
struct ProcessSingletonRuleTests {
    private static let ruleID = "agentstudio_no_new_process_singletons"
    private static let message =
        "process-wide state: construct it in the app composition and inject it (see the composition-root DI problem statement); existing instances are ledgered"

    @Test(
        "shared declarations are rejected at every access level",
        arguments: ["", "private ", "fileprivate ", "internal ", "package ", "public "])
    func rejectsSharedDeclarations(access: String) {
        let source = """
            struct Service {
                \(access)static let shared = Service()
                \(access)static var shared: Service { Service() }
            }
            """
        let diagnostics = lint(source)
        #expect(diagnostics.map(\.line) == [2, 3])
        #expect(
            diagnostics.allSatisfy { $0.ruleID == Self.ruleID && $0.severity == .error && $0.message == Self.message })
    }

    @Test("mutable stored statics include inferred typed unsafe and observed storage")
    func rejectsMutableStorage() {
        let diagnostics = lint(
            """
            enum RuntimeState {
                static var inferred = false
                private static var optional: Int?
                nonisolated(unsafe) static var unsafeState = 0
                static var observed = 0 { didSet {} }
                static var shared = RuntimeState()
            }
            """)
        #expect(diagnostics.map(\.line) == [2, 3, 4, 5, 6])
    }

    @Test("task-local injection is allowed without exempting shared or other property wrappers")
    func permitsTaskLocalBindingsOnly() {
        let diagnostics = lint(
            """
            enum Context {
                @TaskLocal static var request: String?
                @_Concurrency.TaskLocal static var qualifiedRequest: String?
                @TaskLocal static var shared: String?
                @OtherWrapper static var processState: String?
            }
            """)
        #expect(diagnostics.map(\.line) == [4, 5])
    }

    @Test("every stored binding in one declaration is checked once")
    func rejectsMultipleBindings() {
        let diagnostics = lint("enum State { static var first = 0, shared = 1, third: Int? }")
        #expect(diagnostics.count == 3)
        #expect(Set(diagnostics.map(\.column)).count == 3)
    }

    @Test("escaped shared identifiers and extension members are checked")
    func rejectsEscapedSharedAndExtensions() {
        let diagnostics = lint(
            """
            extension Service {
                static let `shared` = Service()
            }
            """)
        #expect(diagnostics.map(\.line) == [2])
    }

    @Test("file-scope mutable variables include conditional compilation and tuple bindings")
    func rejectsFileScopeVariables() {
        let diagnostics = lint(
            """
            private var globalState = 0
            #if DEBUG
            nonisolated(unsafe) var unsafeGlobal: Int?
            #endif
            var (first, second) = (1, 2)
            """)
        #expect(diagnostics.map(\.line) == [1, 3, 5])
    }

    @Test("value constants computed statics and instance or local state remain valid")
    func permitsNonProcessStorage() {
        #expect(
            lint(
                """
                let globalConstant = "constant"
                struct Values {
                    static let tags: Set<String> = ["tag"]
                    static let count = 3
                    static let title = "title"
                    static let sharedTitle = "title"
                    static var computed: Int { 1 }
                    static var explicitGetter: Int { get { 1 } }
                    static var computedSetter: Int { get { 1 } set {} }
                    static var borrowed: Int { _read { yield 1 } }
                    var instanceState = 0
                    let shared = "instance"
                    func work() { var localState = 0 }
                }
                func work() { var localState = 0 }
                let makeState = { var closureState = 0 }
                if true { var blockState = 0 }
                switch 1 { case 1: var caseState = 0; default: break }
                """
            ).isEmpty)
    }

    @Test(
        "the rule scans only repository-root Sources and ignores Tests and Tools",
        arguments: [
            "Tests/AgentStudioTests/Example.swift",
            "Tests/Fixtures/Sources/Example.swift",
            "Tools/AgentStudioArchitectureLint/Sources/Example.swift",
            "Package.swift",
        ])
    func ignoresNonProductionPaths(path: String) {
        #expect(lint("enum State { static let shared = State() }", path: path).isEmpty)
    }

    @Test("a production path reports its singleton")
    func scopesToProductionSources() {
        #expect(lint("enum State { static let shared = State() }").count == 1)
    }

    @Test("the rule is registered as an error")
    func registersGuardrail() {
        #expect(ArchitectureRuleRegistry.rules.contains { $0.id == Self.ruleID && $0.severity == .error })
    }

    @Test("ledger permits only the exact observed count and rejects increases or stale counts")
    func reconcilesSingletonDebt() throws {
        let path = "Sources/AgentStudio/Example.swift"
        let ledger = try ArchitectureDebtLedger.parse(
            contents: "rule_id\tpath\tcount\n\(Self.ruleID)\t\(path)\t1\n",
            sourcePath: "ledger.tsv")
        let reconciliation = DebtLedgerReconciliation(
            ledger: ledger, validatedPaths: [path: "/repo/\(path)"], isFullRun: true)
        func reconcile(_ source: String) -> [ArchitectureDiagnostic] {
            reconciliation.reconcile(diagnostics: lint(source, path: path)) { _ in path }.diagnostics
        }
        #expect(reconcile("enum State { static let shared = State() }").isEmpty)
        #expect(reconcile("enum State { static let shared = State(); static var counter = 0 }").count == 2)
        #expect(reconcile("enum State { static let value = 0 }").count == 1)
    }

    private func lint(_ source: String, path: String = "Sources/AgentStudio/Example.swift") -> [ArchitectureDiagnostic]
    {
        let context = LintTestSupport.repositoryContext(path: path, source: source)
        return ArchitectureRuleRegistry.rules.filter { $0.id == Self.ruleID }.flatMap { $0.validate(context: context) }
    }
}
