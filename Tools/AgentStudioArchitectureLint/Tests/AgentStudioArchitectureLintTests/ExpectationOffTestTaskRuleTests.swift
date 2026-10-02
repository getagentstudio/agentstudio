import Testing

@testable import AgentStudioArchitectureLintCore

@Suite("Expectations off the test task rule")
struct ExpectationOffTestTaskRuleTests {
    private static let ruleID = "agentstudio_no_expectation_off_test_task"

    @Test(
        "all expectation forms are rejected in either helper's closure arguments",
        arguments: [
            "valueFromDedicatedThread", "withoutBlockingCooperativePool",
        ])
    func rejectsClosureArguments(helper: String) {
        let body = """
            #expect(observed)
            _ = try #require(optional)
            Issue.record("off-task failure")
            """
        for call in [
            "\(helper) {\n\(body)\n}",
            "\(helper)({\n\(body)\n})",
            "\(helper)(blockingWork: {\n\(body)\n})",
            "\(helper)(blockingWork: ({\n\(body)\n}))",
            "\(helper)({\n\(body)\n} as @Sendable () throws -> Void)",
        ] {
            let diagnostics = lint("func test() async throws {\n_ = try await \(call)\n}")
            #expect(diagnostics.map(\.line) == [3, 4, 5])
            #expect(diagnostics.allSatisfy { $0.ruleID == Self.ruleID && $0.severity == .error })
            #expect(
                diagnostics.allSatisfy {
                    $0.message == "return observations from the closure; assert in the test task"
                })
        }
    }

    @Test("nested closures stay inside the lexical off-task boundary without duplicate issues")
    func rejectsNestedClosuresOnce() {
        let diagnostics = lint(
            """
            func test() async {
                await valueFromDedicatedThread {
                    withoutBlockingCooperativePool {
                        nested { #expect(false) }
                    }
                }
            }
            """)
        #expect(diagnostics.map(\.line) == [4])
    }

    @Test("module-qualified helpers and Issue.record are recognized")
    func rejectsQualifiedForms() {
        let diagnostics = lint(
            """
            func test() async {
                await AgentStudioTestHarness.valueFromDedicatedThread {
                    Testing.Issue.record("failure")
                }
            }
            """)
        #expect(diagnostics.map(\.line) == [3])
    }

    @Test("additional labeled trailing closures are arguments of the helper")
    func rejectsAdditionalTrailingClosures() {
        let diagnostics = lint(
            """
            func test() async {
                await withoutBlockingCooperativePool { true } completion: {
                    #expect(false)
                }
            }
            """)
        #expect(diagnostics.map(\.line) == [3])
    }

    @Test("assertions after the hop and eagerly evaluated arguments stay on the test task")
    func permitsTestTaskAssertions() {
        #expect(
            lint(
                """
                func test() async throws {
                    let observed = await valueFromDedicatedThread { true }
                    #expect(observed)
                    let optional = await withoutBlockingCooperativePool { Optional(true) }
                    _ = try #require(optional)
                    Issue.record("test-task failure")
                    await withoutBlockingCooperativePool(#expect(observed)) { true }
                await withoutBlockingCooperativePool(makeClosure { #expect(observed) })
                }
                """
            ).isEmpty)
    }

    @Test("comments strings other macros and unrelated methods are not expectations in the hop")
    func permitsUnrelatedSyntax() {
        #expect(
            lint(
                """
                func test() async {
                    await valueFromDedicatedThread {
                        // #expect(false); Issue.record("comment")
                        let text = "#require(value) Issue.record()"
                        #unrelatedMacro(text)
                        OtherIssue.record(text)
                    }
                    someOtherHelper { #expect(true) }
                }
                """
            ).isEmpty)
    }

    @Test("the rule is confined to the repository Tests tree")
    func scopesToTests() {
        let source = "await valueFromDedicatedThread { #expect(false) }"
        #expect(lint(source, path: "Sources/Example.swift").isEmpty)
        #expect(lint(source, path: "Tests/Support.swift").count == 1)
    }

    @Test("the expectation guardrail is registered as an error")
    func registersGuardrail() {
        #expect(ArchitectureRuleRegistry.rules.contains { $0.id == Self.ruleID && $0.severity == .error })
    }

    private func lint(_ source: String, path: String = "Tests/AgentStudioTests/Example.swift")
        -> [ArchitectureDiagnostic]
    {
        let context = LintTestSupport.repositoryContext(path: path, source: source)
        return ArchitectureRuleRegistry.rules.filter { $0.id == Self.ruleID }.flatMap { $0.validate(context: context) }
    }
}
