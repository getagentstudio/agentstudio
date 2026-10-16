import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("Sidebar performance proof policy")
struct SidebarPerformanceProofPolicyTests {
    @Test("native table pilot policy is immutable and centrally owned")
    func nativeTablePilotPolicyIsImmutableAndCentrallyOwned() {
        #expect(AppPolicies.SidebarPerformanceProof.repositoryCount == 150)
        #expect(AppPolicies.SidebarPerformanceProof.worktreeCount == 180)
        #expect(AppPolicies.SidebarPerformanceProof.tabCount == 12)
        #expect(AppPolicies.SidebarPerformanceProof.paneCount == 36)
        #expect(AppPolicies.SidebarPerformanceProof.doubledWorktreeCount == 360)
        #expect(AppPolicies.SidebarPerformanceProof.representedRowCount == 24)
        #expect(AppPolicies.SidebarPerformanceProof.warmupTransactionCountPerScale == 20)
        #expect(AppPolicies.SidebarPerformanceProof.measuredTransactionCountPerScale == 200)
        #expect(AppPolicies.SidebarPerformanceProof.maximumMembershipP95Milliseconds == 4.0)
        #expect(AppPolicies.SidebarPerformanceProof.maximumDoubledOffscreenGrowthPercent == 20.0)
        #expect(AppPolicies.SidebarPerformanceProof.nativeTablePilotCompletionTimeout == .seconds(30))
        #expect(
            AppPolicies.SidebarPerformanceProof.scaleWorktreeCounts == [180, 360]
        )
        #expect(AppPolicies.SidebarPerformanceProof.invalidatesWholePopulationOnFailure)
        #expect(AppPolicies.SidebarPerformanceProof.nativeTablePilotPolicyID == "sidebar-native-table-pilot")
        #expect(AppPolicies.SidebarPerformanceProof.nativeTablePilotPolicyVersion == 1)
    }

    @Test("strict sidebar CPU policy is immutable and population specific")
    func strictSidebarCPUPolicyIsImmutableAndPopulationSpecific() throws {
        #expect(AppPolicies.SidebarPerformanceProof.policyID == "strict-sidebar-cpu")
        let policySource = try String(
            contentsOfFile: "Sources/AgentStudio/Infrastructure/AppPolicies.swift",
            encoding: .utf8
        )

        #expect(policySource.contains("package static let policyVersion: Int = 6"))
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        #expect(
            AppPolicies.SidebarPerformanceProof.strictWatchedRootURLs == [
                homeURL.appendingPathComponent("code/opensource", isDirectory: true),
                homeURL.appendingPathComponent("code/projects", isDirectory: true),
            ]
        )
        #expect(policySource.contains("package static let strictTabCount: Int = 5"))
        #expect(policySource.contains("package static let strictPaneModelCount: Int = 20"))
        #expect(policySource.contains("package static let zeroPTYExpectedSessionCount: Int = 0"))
        #expect(!policySource.contains("mountedPTYExpectedSessionCount"))
        #expect(policySource.contains("package static let zmxInventoryInterval: Duration"))
        #expect(policySource.contains("package static let fixturePreparationTimeout: Duration = .seconds(300)"))
        #expect(AppPolicies.SidebarPerformanceProof.fixtureQuery == "worktree")
        #expect(AppPolicies.SidebarPerformanceProof.idleProcessCPUP99MaximumPercent == 10)
        #expect(AppPolicies.SidebarPerformanceProof.actionProcessCPUP95MaximumPercent == 20)
        #expect(AppPolicies.SidebarPerformanceProof.sampleInterval == .seconds(1))
        #expect(AppPolicies.SidebarPerformanceProof.metricsExportInterval == .seconds(60))
        #expect(AppPolicies.SidebarPerformanceProof.requiredIdleUsableSampleCount == 1000)
        #expect(AppPolicies.SidebarPerformanceProof.requiredSuccessfulActionCount == 100)
        #expect(AppPolicies.SidebarPerformanceProof.requiredActionBearingSampleCount == 200)
        #expect(AppPolicies.SidebarPerformanceProof.searchCharacterCount == 8)
        #expect(AppPolicies.SidebarPerformanceProof.searchCharacterInterval == .milliseconds(100))
        #expect(AppPolicies.SidebarPerformanceProof.quiescenceInterval == .seconds(5))
        #expect(AppPolicies.SidebarPerformanceProof.actionReadbackTimeout == .seconds(5))
        #expect(AppPolicies.SidebarPerformanceProof.maximumSamplerGap == .milliseconds(1250))
        #expect(AppPolicies.SidebarPerformanceProof.maximumActionSampleBoundaryOffset == .milliseconds(50))
        #expect(AppPolicies.SidebarPerformanceProof.actionSampleStartOffset == .milliseconds(20))
        #expect(AppPolicies.SidebarPerformanceProof.maximumDiagnosticCPUP95DeltaPercentagePoints == 5)
        #expect(AppPolicies.SidebarPerformanceProof.maximumDiagnosticInteractionP95GrowthPercent == 10)
        #expect(AppPolicies.SidebarPerformanceProof.gitStatusPhysicalLimit == 4)
        #expect(AppPolicies.SidebarPerformanceProof.gitMaximumSettlementInterval == .seconds(960))
        #expect(
            AppPolicies.SidebarPerformanceProof.standardTraceTags
                == ["performance", "app.startup", "terminal.startup"]
        )
        #expect(AppPolicies.SidebarPerformanceProof.idlePopulationNames == ["zero_pty_idle"])
        #expect(AppPolicies.SidebarPerformanceProof.actionPopulationNames.count == 4)
    }
}
