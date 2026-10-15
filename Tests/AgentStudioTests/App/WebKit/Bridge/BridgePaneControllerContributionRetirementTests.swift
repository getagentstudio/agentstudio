import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgePaneControllerTests {
    @Test("superseded contribution refresh retains lineage until its successor settles")
    func supersededContributionRefreshRetainsLineageUntilSuccessorSettles() async throws {
        // Arrange
        let fixture = try await makeContributionRefreshFixture(
            reviewConstructionProgress: .init(clock: TestPushClock())
        )
        let controller = fixture.controller
        defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        guard
            case .success = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: fixture.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: UUIDv7.generate(),
                correlationId: nil
            )
        else {
            Issue.record("Expected the initial contribution load to succeed")
            return
        }
        let pendingGeneration = controller.nextReviewGeneration
        controller.refreshAdmissionCoordinator.beginReviewComparisonAttempt(
            activeTarget: .ref(name: "target"),
            reviewGeneration: pendingGeneration.rawValue
        )
        try #require(
            controller.pendingComparisonReviewGeneration == nil,
            "Same-lineage refresh must not be blocked by a fabricated comparison replacement"
        )
        let captureGate = BridgeContributionCaptureGate()
        await fixture.provider.setContributionCaptureGate(captureGate)

        do {
            // Act — the predecessor attempt remains blocked while its successor
            // becomes current under the same public Review generation.
            await controller.handlePaneFilesystemContextEvent(
                .cwdSubtreeChanged(
                    context: PaneFilesystemContext(
                        paneId: PaneId(existingUUID: fixture.paneId),
                        repoId: fixture.repoId,
                        cwd: URL(fileURLWithPath: "/tmp/contribution-refresh"),
                        worktreeId: fixture.worktreeId
                    ),
                    paths: ["Sources/App/Generation2.swift"],
                    batchSeq: 1
                )
            )
            await captureGate.waitForStartedCaptureCount(1)
            let predecessorTask = try #require(controller.activeReviewRefreshTask)
            #expect(!predecessorTask.isCancelled)
            await controller.handlePaneFilesystemContextEvent(
                .cwdSubtreeChanged(
                    context: PaneFilesystemContext(
                        paneId: PaneId(existingUUID: fixture.paneId),
                        repoId: fixture.repoId,
                        cwd: URL(fileURLWithPath: "/tmp/contribution-refresh"),
                        worktreeId: fixture.worktreeId
                    ),
                    paths: ["Sources/App/Generation3.swift"],
                    batchSeq: 2
                )
            )
            try #require(predecessorTask.isCancelled, "Invalidation must cancel the held predecessor directly")
            await captureGate.waitForStartedCaptureCount(2)
            let refreshRequests = await fixture.provider.recordedContributionRequests()
            try #require(refreshRequests.count == 3)
            #expect(refreshRequests.map { $0.reviewGenerationValue } == [1, 1, 1])
            #expect(
                refreshRequests[2].reviewAttemptAuthorityGeneration
                    > refreshRequests[1].reviewAttemptAuthorityGeneration
            )
            await captureGate.releaseFirst()
            #expect(await waitForRetiringReviewRefreshTasksToDrain(controller))

            // Assert — stale cleanup cannot manufacture a failure for the live successor.
            #expect(
                controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                    .attempt == .pending(reviewGeneration: pendingGeneration.rawValue)
            )

            await captureGate.releaseAll()
            await waitForActiveReviewRefreshTaskToFinish(controller)
            #expect(
                controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                    .attempt == .settled(reviewGeneration: controller.nextReviewGeneration.rawValue)
            )
        } catch {
            await captureGate.releaseAll()
            for task in controller.reviewConstructionProgress.physicalTaskHandles() { await task.value }
            _ = await controller.beginTeardown().value
            throw error
        }
    }
}
