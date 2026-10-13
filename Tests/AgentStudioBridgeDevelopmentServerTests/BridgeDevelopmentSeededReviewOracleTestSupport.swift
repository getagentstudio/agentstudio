import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

struct SeededReviewPublicationFixture: Sendable {
    let baseline: BridgeReviewCommittedPublication
    let deletion: BridgeReviewCommittedPublication

    func publication(
        _ original: BridgeReviewCommittedPublication, correlation: String
    ) -> BridgeReviewCommittedPublication {
        BridgeReviewCommittedPublication(
            publicationId: UUIDv7.generate(), package: original.package, delta: original.delta,
            contentHandles: original.contentHandles,
            comparisonPresentationRevision: original.comparisonPresentationRevision,
            reviewComparison: original.reviewComparison, operationCorrelationID: correlation,
            classifiedRefreshImpact: original.classifiedRefreshImpact
        )
    }
}

enum SeededReviewOracleScenario: Sendable {
    case earlierReservation
    case predecessorTerminal
}

/// Controls only the oracle's input history. The publications originate at the
/// real host callback; copied identities model distinct operations independently.
func exerciseSeededReviewOracleScenario(_ scenario: SeededReviewOracleScenario) async throws {
    let fixture = try await captureControllableReviewPublications()
    let earlierPublication = fixture.publication(fixture.baseline, correlation: "earlier-review")
    let unrelatedDeletion = fixture.publication(fixture.deletion, correlation: "unrelated-review")
    let expectedPublication = fixture.publication(fixture.deletion, correlation: "deletion-review")
    let recorder = SeededReviewLifecycleRecorder()
    let successorAnnouncement = HeldStep<Void>("deletion successor reservation announcement")
    if case .earlierReservation = scenario {
        await recorder.record(seededReviewLifecycle(correlation: "earlier-review", stage: .refreshReserved))
        await recorder.record(seededReviewLifecycle(correlation: "unrelated-review", stage: .refreshReserved))
    }
    let opening = recorder.openDeletionObservation()
    let producer = Task {
        switch scenario {
        case .earlierReservation:
            recorder.recordCommit(earlierPublication)
            recorder.recordCommit(unrelatedDeletion)
        case .predecessorTerminal:
            await recorder.record(seededReviewLifecycle(correlation: "predecessor-review", stage: .refreshReserved))
            await recorder.record(
                seededReviewLifecycle(
                    correlation: "predecessor-review", stage: .refreshOperationTerminal, result: .stale
                ))
        }
        try await successorAnnouncement.arrive(())
        await recorder.record(seededReviewLifecycle(correlation: "deletion-review", stage: .refreshReserved))
        recorder.recordCommit(expectedPublication)
    }
    let consumer = Task { try await recorder.requireCommittedDeletion(path: "tracked.txt", after: opening) }
    do {
        _ = try await successorAnnouncement.firstArrival()
        successorAnnouncement.release()
        let observedPublication = try await consumer.value
        try await producer.value
        #expect(observedPublication == expectedPublication)
        #expect(observedPublication.operationCorrelationID == "deletion-review")
        print(
            "TQ56 oracle observed correlation=\(observedPublication.operationCorrelationID ?? "none") scenario=\(scenario)"
        )
        try await recorder.finish()
    } catch {
        successorAnnouncement.release()
        producer.cancel()
        consumer.cancel()
        _ = await producer.result
        _ = await consumer.result
        try await recorder.finish()
        throw error
    }
}

func seededReviewLifecycle(
    correlation: String,
    stage: BridgeOperationLifecycleTraceEvent.Stage,
    result: BridgeOperationLifecycleTraceEvent.Result = .success
) -> BridgeOperationLifecycleTraceEvent {
    BridgeOperationLifecycleTraceEvent(
        operationCorrelationID: correlation, result: result, stage: stage, stageAttempt: 0, surface: .review
    )
}
