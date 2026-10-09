import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge development host bounded shutdown")
struct BridgeDevelopmentProductHostShutdownDeadlineTests {
    @Test("cooperative whole-host cleanup reaches zero before its deadline")
    func cooperativeCleanupCompletes() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-host-cooperative-shutdown"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let clock = TestPushClock()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            retirementClock: clock,
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            ),
            makeReviewProvider: { _, _ in BridgeDevelopmentSharedConstructionReviewProvider() }
        )

        #expect(await host.shutdown() == .completed)
        #expect((await host.shutdownSnapshot()).unfinishedDrainCount == 0)
        #expect((await host.shutdownSnapshot()).cleanupCompleted)
    }

    @Test("whole-host shutdown returns at one deadline and retains unfinished cleanup")
    func uncooperativeComparisonDoesNotBlockPaneDisposal() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-host-bounded-shutdown"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let clock = TestPushClock()
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            retirementClock: clock,
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            ),
            makeReviewProvider: { _, _ in provider }
        )
        _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
        let comparisonGate = BridgeComparisonGate()
        await provider.setComparisonGate(comparisonGate)
        let productAdmission = await host.productAdmission
        await admitDevelopmentReviewComparisonIntent(
            host: host,
            workerDerivationEpoch: 1,
            productAdmission: productAdmission
        )
        await host.applyCommittedReviewComparisonUpdate(
            BridgeProductReviewComparisonUpdateRequest(target: .branch(name: "stack/base")),
            workerDerivationEpoch: 1,
            productAdmission: productAdmission
        )
        await comparisonGate.waitForStartedComparisonCount(1)

        let shutdownTask = Task { await host.shutdown() }
        await clock.waitForPendingSleepCount(atLeast: 1)
        let admissionGate = await host.productAdmissionGate
        #expect(admissionGate.acquire() == nil)
        clock.advance(by: AppPolicies.Bridge.productRetirementQuiescenceDeadline)
        let result = await shutdownTask.value
        guard case .quiescenceDeadlineExceeded(let unfinishedCount) = result else {
            Issue.record("Expected a typed whole-host deadline diagnostic, got \(result)")
            await comparisonGate.releaseAll()
            await host.waitForShutdownCleanup()
            return
        }
        #expect(unfinishedCount > 0)
        #expect((await host.shutdownSnapshot()).unfinishedDrainCount > 0)

        await comparisonGate.releaseAll()
        await host.waitForShutdownCleanup()
        #expect((await host.shutdownSnapshot()).cleanupCompleted)
    }
}
