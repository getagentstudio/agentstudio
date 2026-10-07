import Testing

@testable import AgentStudioArchitectureLintCore

@Suite("Performance policy homes")
struct PerformancePolicyHomeRuleTests {
    private static let timeoutSource = """
        enum CLIStorePolicy {
            static let busyTimeout = 0.05
        }
        """

    @Test("the CLI store's designated policy home may own its timeout")
    func acceptsTheCLIStorePolicyHome() {
        let context = LintTestSupport.repositoryContext(
            path: "Sources/AgentStudioCLIStore/CLIStorePolicy.swift",
            source: Self.timeoutSource)

        #expect(PerformanceConstantsInAppPoliciesRule().validate(context: context).isEmpty)
    }

    @Test(
        "the same timeout remains forbidden in every other CLI store file",
        arguments: ["CLIStore.swift", "OtherPolicy.swift", "Nested/CLIStorePolicy.swift"]
    )
    func rejectsTheSameTimeoutOutsideItsPolicyHome(fileName: String) {
        let context = LintTestSupport.repositoryContext(
            path: "Sources/AgentStudioCLIStore/\(fileName)",
            source: Self.timeoutSource)

        let diagnostics = PerformanceConstantsInAppPoliciesRule().validate(context: context)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.ruleID == "agentstudio_performance_constants_in_app_policies")
        #expect(diagnostics.first?.severity == .error)
        #expect(diagnostics.first?.line == 2)
    }
}
