import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore

extension WebKitSerializedTests.BridgePaneControllerTests {
    @Test("invalidation supersedes an initial Review load before any snapshot exists")
    func invalidationSupersedesInitialReviewLoadBeforeAnySnapshotExists() async throws {
        // Arrange
        let comparisonGate = BridgeComparisonGate()
        let fixture = try await makeRefreshAdmissionIntegrationFixture(comparisonGate: comparisonGate)
        await fixture.reviewProvider.throwCancellationWhenComparisonTaskIsCancelled()
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.foreground)
        await comparisonGate.waitForStartedComparisonCount(1)
        let initialReviewTask = try #require(fixture.controller.activeReviewRefreshTask)
        let predecessorPhysicalTasks = fixture.controller.reviewConstructionProgress.physicalTaskHandles()
        #expect(predecessorPhysicalTasks.count == 1)
        #expect(fixture.controller.paneState.diff.status == .loading)
        #expect(fixture.controller.paneState.diff.packageMetadata == nil)

        // Act — the first physical capture ignores cancellation while a fresh
        // repository invalidation must admit its current successor.
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/InitialLoadChanged.swift"],
                    batchSequence: 101
                )
            )
        )
        await comparisonGate.waitForStartedComparisonCount(2)
        // C16 owns physical construction lifetime separately from the controller's
        // logically settled refresh task. Both held captures remain accounted for.
        await initialReviewTask.value
        #expect(fixture.controller.reviewConstructionProgress.physicalTaskHandles().count == 2)
        await comparisonGate.releaseFirst()
        for task in predecessorPhysicalTasks { await task.value }
        let successorPhysicalTasks = fixture.controller.reviewConstructionProgress.physicalTaskHandles()
        #expect(successorPhysicalTasks.count == 1)
        #expect(fixture.controller.retiringReviewRefreshTaskById.isEmpty)
        #expect(fixture.controller.paneState.diff.status == .loading)
        #expect(
            fixture.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                .attempt != .unavailable(failureKind: "loadFailed:package:cancelled", retryable: true)
        )
        await comparisonGate.releaseAll()
        await fixture.controller.activeReviewRefreshTask?.value
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        for task in successorPhysicalTasks { await task.value }

        // Assert
        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == 2)
        #expect(fixture.controller.pendingReviewPackageBuildReasons.isEmpty)
        #expect(fixture.controller.paneState.diff.status == .ready)
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-initial"])
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact == nil)
        #expect(fixture.controller.reviewConstructionProgress.activeWaitCount() == 0)
        #expect(fixture.controller.reviewConstructionProgress.physicalTaskHandles().isEmpty)
        await fixture.finish()
    }
}
