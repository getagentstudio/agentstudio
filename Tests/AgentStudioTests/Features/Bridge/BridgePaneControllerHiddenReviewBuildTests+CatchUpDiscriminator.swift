import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneControllerHiddenReviewBuildTests {
    @Test("foreground Review catch-up successor settles after its predecessor is superseded")
    func foregroundReviewCatchUpSuccessorSettlesAfterSupersession() async throws {
        // Arrange: settle the initial package so only filesystem Review catch-up is under test.
        let lifecycle = BridgePaneCatchUpLifecycleRecorder()
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            lifecycleTraceRecorder: lifecycle
        )
        await fixture.controller.applyBridgePaneActivity(.foreground)?.value
        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        let initialReviewTask = try #require(fixture.controller.activeReviewRefreshTask)
        await initialReviewTask.value
        #expect(fixture.controller.paneState.diff.packageMetadata != nil)
        #expect(fixture.controller.activeViewerModeSignalState.acceptedMode == .review)
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)

        let predecessorComparison = HeldStep<Void>(
            "superseded Review catch-up comparison",
            cancellation: .holdThroughCancellation
        )
        let successorComparison = HeldStep<Void>("current Review catch-up comparison")
        defer {
            predecessorComparison.release()
            successorComparison.release()
        }
        await fixture.reviewProvider.setComparisonStep(predecessorComparison)

        // Act: reserve and hold the current catch-up at its named preparation step.
        fixture.controller.refreshAdmissionCoordinator.recordInvalidation(
            fileChangeset: nil,
            requiresReviewRefresh: true
        )
        fixture.controller.scheduleWorktreeProductCatchUpIfPossible()
        let predecessorStart = try await lifecycle.nextReviewPreparation()
        let predecessorTask = try #require(fixture.controller.activeReviewRefreshTask)
        _ = try await predecessorComparison.firstArrival()
        let predecessorReservation = try #require(
            fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activeRefreshPass
        )

        // Act: a newer Review invalidation retires the predecessor and admits a successor.
        await fixture.reviewProvider.setComparisonStep(successorComparison)
        fixture.controller.refreshAdmissionCoordinator.recordInvalidation(
            fileChangeset: nil,
            requiresReviewRefresh: true
        )
        fixture.controller.retireActiveReviewRefreshTask()
        fixture.controller.scheduleWorktreeProductCatchUpIfPossible()

        let successorStart = try await lifecycle.nextReviewPreparation()
        let successorTask = try #require(fixture.controller.activeReviewRefreshTask)
        _ = try await successorComparison.firstArrival()
        let currentReservation = try #require(
            fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activeRefreshPass
        )
        #expect(successorStart.operationCorrelationID != predecessorStart.operationCorrelationID)
        #expect(currentReservation.id != predecessorReservation.id)
        #expect(fixture.controller.activeViewerModeSignalState.acceptedMode == .review)
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity == .foreground)

        // Act: let both physical tasks close, then observe the exact successor terminal.
        predecessorComparison.release()
        await predecessorTask.value
        successorComparison.release()
        await successorTask.value

        // Assert: the superseded attempt may end stale/cancelled; the current operation succeeds.
        let predecessorTerminal = try #require(
            await lifecycle.terminal(for: predecessorStart.operationCorrelationID)
        )
        let successorTerminal = try #require(
            await lifecycle.terminal(for: successorStart.operationCorrelationID)
        )
        #expect(predecessorTerminal.result == .stale || predecessorTerminal.result == .cancelled)
        #expect(successorTerminal.result == .success)
        #expect(fixture.controller.activeReviewRefreshTask == nil)
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activeRefreshPass == nil)
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact == nil)
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        await fixture.finish()
        try await lifecycle.finish()
    }
}

private actor BridgePaneCatchUpLifecycleRecorder:
    BridgeProductMetadataLifecycleTraceRecording
{
    private let reviewEvents = FactRecorder<String, BridgeOperationLifecycleTraceEvent>(
        vocabulary: .init(
            describeScope: { $0 },
            describeFact: { "\($0.stage.rawValue):\($0.result.rawValue):\($0.operationCorrelationID)" },
            isClosing: { _, _ in false }
        )
    )
    private var reviewTerminals: [BridgeOperationLifecycleTraceEvent] = []

    func record(_ event: BridgeOperationLifecycleTraceEvent) async {
        guard event.surface == .review else { return }
        if event.stage == .reviewPrepareStarted {
            reviewEvents.append(scope: "review", fact: event)
        } else if event.stage == .refreshOperationTerminal {
            reviewTerminals.append(event)
        }
    }

    func nextReviewPreparation() async throws -> BridgeOperationLifecycleTraceEvent {
        try await reviewEvents.expectNext(
            in: "review",
            where: { $0.stage == .reviewPrepareStarted },
            "next correlated Review catch-up preparation"
        )
    }

    func terminal(for operationCorrelationID: String) -> BridgeOperationLifecycleTraceEvent? {
        reviewTerminals.first { $0.operationCorrelationID == operationCorrelationID }
    }

    func finish() async throws {
        reviewEvents.receive(.ended)
        try await reviewEvents.finish()
    }
}
