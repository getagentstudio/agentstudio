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

                    @Test func nestedFunctionIsIgnored() {
                        func helper() {
                            guard condition else { return }
                        }
                        helper()
                    }

                    private func helper() {
                        guard condition else { return }
                    }
                }
                """
        )

        let diagnostics = TestSilentReturnRule().validate(context: context)

        #expect(diagnostics.map(\.line) == [5, 9, 13])
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

                    @Test func closureReturnDoesNotExitTest() {
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

    @Test("paired expectations exempt only exact matching guard expressions")
    func pairedExpectationExemptionRequiresExactMatch() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTests/PairedExpectationExamples.swift",
            source: """
                import Testing

                struct Examples {
                    @Test func exactMatch() {
                        #expect(condition)
                        guard condition else { return }
                        #expect(otherCondition, "the message form also matches")
                        guard otherCondition else { return }
                    }

                    @Test func driftedMatch() {
                        #expect(condition)
                        guard otherCondition else { return }
                    }
                }
                """
        )

        #expect(TestSilentReturnRule().validate(context: context).map(\.line) == [13])
    }

    @Test("nested control-flow returns require a signal on their own path")
    func nestedControlFlowRequiresPathSignal() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTests/NestedReturnExamples.swift",
            source: """
                import Testing

                struct Examples {
                    @Test func nestedIfReturn() {
                        guard condition else {
                            if shouldReturn { return }
                        }
                    }

                    @Test func nestedSwitchReturn() {
                        guard condition else {
                            switch state {
                            case .bad: return
                            default: break
                            }
                        }
                    }

                    @Test func nestedSignalsDominateReturns() {
                        guard condition else {
                            if shouldReturn {
                                Issue.record("setup failed")
                                return
                            }
                        }
                    }
                }
                """
        )

        #expect(TestSilentReturnRule().validate(context: context).map(\.line) == [5, 11])
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
