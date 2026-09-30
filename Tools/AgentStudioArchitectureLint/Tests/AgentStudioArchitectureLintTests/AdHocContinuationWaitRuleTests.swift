import Testing

@testable import AgentStudioArchitectureLintCore

@Suite("Ad-hoc continuation wait rule")
struct AdHocContinuationWaitRuleTests {
    @Test("continuation calls and stored collection and tuple types are diagnosed")
    func detectsContinuationCallsAndStoredTypes() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTests/ContinuationWaiters.swift",
            source: """
                struct Fixture {
                    var direct: CheckedContinuation<Void, Never>?
                    var array: [UnsafeContinuation<(String, Int), Never>] = []
                    var dictionary: [String: [CheckedContinuation<Int, any Error>]] = [:]
                    var tuple: (String, UnsafeContinuation<Void, Never>)?
                    var computed: CheckedContinuation<Void, Never>? { nil }
                    var observed: CheckedContinuation<Void, Never>? { didSet {} }
                }
                func wait() async {
                    await withCheckedContinuation { _ in }
                    try? await withCheckedThrowingContinuation { _ in }
                    await withUnsafeContinuation { _ in }
                    try? await withUnsafeThrowingContinuation { _ in }
                }
                """
        )

        let diagnostics = AdHocContinuationWaitRule().validate(context: context)

        #expect(diagnostics.count == 9)
        #expect(diagnostics.allSatisfy { $0.ruleID == "agentstudio_no_adhoc_continuation_wait" })
        #expect(diagnostics.map(\.line).sorted() == [2, 3, 4, 5, 7, 10, 11, 12, 13])
        let expectedMessage =
            "Hand-built continuation waiter: a test double that parks a continuation has no failure path "
            + "and hides the missing fact from the hang report. Use HeldStep, FactRecorder expectations, or "
            + "H12 discovery instead — docs/architecture/testing/testing_architecture.md#typed-facts"
        #expect(diagnostics.allSatisfy { $0.message == expectedMessage })
    }

    @Test("the shared harness and files outside the repository Tests tree are exempt")
    func exemptsHarnessAndNonRepositoryTestPaths() {
        let source = """
            struct Fixture {
                var waiter: [CheckedContinuation<Void, Never>] = []
                func wait() async { await withCheckedContinuation { _ in } }
            }
            """
        let harnessContext = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTestHarness/ContinuationWaiter.swift",
            source: source
        )
        let toolTestContext = LintTestSupport.repositoryContext(
            path: "Tools/AgentStudioArchitectureLint/Tests/ContinuationWaiter.swift",
            source: source
        )

        #expect(AdHocContinuationWaitRule().validate(context: harnessContext).isEmpty)
        #expect(AdHocContinuationWaitRule().validate(context: toolTestContext).isEmpty)
    }

    @Test("event-driven facts and ordinary stored values remain clean")
    func ignoresCleanTestFile() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTests/TypedFactWait.swift",
            source: """
                // withUnsafeContinuation { _ in }
                let sourceText = "withCheckedContinuation { _ in }"
                struct Fixture {
                    var eventCount = 0
                    var computed: CheckedContinuation<Void, Never>? { nil }
                    func nextFact() async {
                        let localWaiter: CheckedContinuation<Void, Never>?
                        let functionReference = withCheckedContinuation
                        await recorder.expectNext()
                    }
                }
                """
        )

        #expect(AdHocContinuationWaitRule().validate(context: context).isEmpty)
    }
}
