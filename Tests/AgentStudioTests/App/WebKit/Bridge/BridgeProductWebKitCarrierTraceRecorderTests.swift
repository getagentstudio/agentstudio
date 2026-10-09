import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("WebKit carrier publication trace facts")
struct BridgeProductWebKitCarrierTraceRecorderTests {
    @Test("publication sample waits for its recorder write", arguments: [0, 1])
    func completedPublicationWaitsForRecorderWrite(priorCount: Int) async throws {
        // Arrange: exercise the production lifecycle-to-telemetry adapter and the
        // same test recorder used by the hosted corruption/replay journey.
        let recorder = BridgeProductWebKitCarrierTraceRecorder()
        let lifecycle = BridgeProductMetadataLifecycleTraceRecorder(recorder: recorder)
        let receipt = BridgeReviewMetadataPublicationReceipt(
            retained: 1, publishedSubscriptions: 1, emittedEvents: 1, superseded: 0, finalFrames: []
        )
        if priorCount == 1 { await lifecycle.record(.completed(receipt: receipt, traceContext: nil)) }
        let heldWrite = HeldStep<Void>("completed publication recorder append", cancellation: .holdThroughCancellation)
        await recorder.holdNextCompletedPublicationWrite(at: heldWrite)
        let producer = Task { await lifecycle.record(.completed(receipt: receipt, traceContext: nil)) }
        _ = try await heldWrite.firstArrival()

        // Act: another owner can finish while this telemetry append is suspended.
        let beforeWrite = await recorder.scrubbedTrace()
        #expect(beforeWrite.completedReviewPublicationCount == priorCount)
        heldWrite.release()
        let completedTrace = try await recorder.waitForCompletedReviewPublicationCount(priorCount + 1)
        await producer.value

        // Assert: a sampled prefix is not proof that the expected write happened.
        #expect(completedTrace.completedReviewPublicationCount == priorCount + 1)
        // A caller arriving after the write reads the same already-satisfied fact.
        let retainedTrace = try await recorder.waitForCompletedReviewPublicationCount(priorCount + 1)
        #expect(retainedTrace.completedReviewPublicationCount == priorCount + 1)
    }
}
