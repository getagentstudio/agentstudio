import Testing

@testable import AgentStudioArchitectureLintCore

@Suite("Silent test return rule")
struct TestSilentReturnRuleTests {
    @Test("bare returns in test guards are diagnosed across guard forms")
    func detectsBareReturnsAcrossGuardForms() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTests/SilentReturnExamples.swift",
            source: """
                import Testing

                struct Examples {
                    @Test func boolWait() async {
                        guard await waitForEvent() else { return }
                    }

                    @Test func caseMatch() {
                        guard case .ready = state else { return }
                    }

                    @Test func optionalBinding() {
                        guard let value else { return }
                        consume(value)
                    }

                    @Test func closureWait() {
                        let check = {
                            guard condition else { return }
                            consume()
                        }
                        check()
                    }

                    private func helper() {
                        guard condition else { return }
                    }
                }
                """
        )

        let diagnostics = TestSilentReturnRule().validate(context: context)

        #expect(diagnostics.map(\.line) == [5, 9, 13, 19])
        #expect(diagnostics.allSatisfy { $0.ruleID == "agentstudio_no_silent_test_return" })
        #expect(diagnostics.allSatisfy { $0.severity == .error })
    }

    @Test("explicit failure paths and nested helpers are allowed")
    func allowsFailurePathsAndNestedScopes() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTests/SilentReturnExamples.swift",
            source: """
                import Testing

                struct Examples {
                    @Test func recordsIssue() {
                        guard condition else {
                            Issue.record("setup failed")
                            return
                        }
                    }

                    @Test func recordsExpectation() {
                        guard condition else {
                            #expect(false, "setup failed")
                            return
                        }
                    }

                    @Test func throwsFailure() throws {
                        guard condition else {
                            throw TestError.failed
                        }
                    }

                    @Test func closesWithFatalError() {
                        guard condition else { fatalError("setup failed") }
                    }

                    private func helperClosureReturnDoesNotExitTest() {
                        let check = {
                            guard condition else { return }
                            consume()
                        }
                        check()
                    }
                }
                """
        )

        #expect(TestSilentReturnRule().validate(context: context).isEmpty)
    }

    @Test("production sources and the shared harness are ignored")
    func ignoresProductionAndHarnessSources() {
        let production = LintTestSupport.repositoryContext(
            path: "Sources/AgentStudio/Core/Production.swift",
            source: """
                func work() {
                    guard condition else { return }
                }
                """
        )
        let harness = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTestHarness/HeldStep.swift",
            source: """
                func work() {
                    guard condition else { return }
                }
                """
        )

        #expect(TestSilentReturnRule().validate(context: production).isEmpty)
        #expect(TestSilentReturnRule().validate(context: harness).isEmpty)
    }
}

private enum TestError: Error {
    case failed
}
