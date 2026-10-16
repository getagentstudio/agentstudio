// This suite lives in its own file, not alongside `RepoExplorerNativeTablePilotTests`: `swift
// test --filter`/`--skip` also match a test's declaring file's basename, so a suite sharing
// `RepoExplorerNativeTablePilotTests.swift` would be swept back into the PR-gated fast lane.
import Dispatch
import Foundation
import Testing

@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite("Repo Explorer native table pilot benchmark", .serialized)
struct RepoExplorerNativeTablePilotBenchmarkTests {
    // Growth is a ratio of the same machine's two runs, so it holds on any hardware,
    // including the shared 3-core CI runner.
    @Test("pilot completes and doubling stays within the growth policy")
    func pilotCompletesWithinGrowthPolicy() async {
        let result = await runPilotAndReport()
        #expect(result.failureReason == nil || result.failureReason == .membershipP95Exceeded)
        #expect(result.doubledOffscreenGrowthPercent <= 20)
    }

    // An absolute millisecond budget is a property of the hardware, so it is enforced on
    // developer machines only. GitHub Actions sets CI=true.
    @Test(
        "pilot meets the absolute 4 ms membership p95 budget on developer hardware",
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] == "true",
            "absolute millisecond budgets are enforced on developer hardware, not shared CI runners"
        )
    )
    func pilotMeetsAbsoluteMembershipBudget() async {
        let result = await runPilotAndReport()
        #expect(result.passed)
        #expect(result.failureReason == nil)
        #expect(result.baselineMembershipP95Milliseconds <= 4)
        #expect(result.doubledMembershipP95Milliseconds <= 4)
    }

    private func runPilotAndReport() async -> RepoExplorerNativeTablePilotResult {
        let result = await RepoExplorerNativeTablePilot.run(performanceTraceRecorder: nil)
        print(
            "REPO_EXPLORER_NATIVE_TABLE_PILOT_RESULT "
                + "baseline_p95_ms=\(result.baselineMembershipP95Milliseconds) "
                + "doubled_p95_ms=\(result.doubledMembershipP95Milliseconds) "
                + "growth_percent=\(result.doubledOffscreenGrowthPercent)"
        )
        return result
    }
}
