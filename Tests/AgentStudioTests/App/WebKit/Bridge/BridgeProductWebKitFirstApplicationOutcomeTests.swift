import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioInfrastructure

@Suite("WebKit first Review application outcome")
struct BridgeProductWebKitFirstApplicationOutcomeTests {
    @Test(arguments: [
        "metadata_producer_failed", "metadata_producer_cancelled", "review_metadata_publication_failed",
        "review_refresh_candidate_failed", "review_refresh_candidate_superseded",
        "review_refresh_cleanup_terminal", "review_refresh_install_terminal",
    ])
    func existingTelemetryEndsFirstReceiptWait(phase: String) async throws {
        let recorder = BridgeProductWebKitFirstApplicationRecorder()
        let trace = BridgeProductWebKitCarrierTraceRecorder(firstApplication: recorder)
        let sample = sample(phase: phase, protocolName: "review")
        await trace.record(sample: sample, receivedAtUnixNano: 0)
        #expect(try await recorder.wait() == .ended(phase: phase, reason: "fixture_failure"))
    }

    @Test
    func unrelatedFileFailureDoesNotEndReviewWait() async throws {
        let recorder = BridgeProductWebKitFirstApplicationRecorder()
        recorder.observe(sample(phase: "metadata_producer_failed", protocolName: "worktree-file"))
        let receipt = BridgeProductWebKitCarrierApplicationReceipt(
            applicationResult: .advanced, publicationId: UUIDv7.generate())
        recorder.record(.receipt(receipt))
        #expect(try await recorder.wait() == .receipt(receipt))
    }

    @Test
    func firstReceiptWinsOverLaterRecoveryFailuresAndReceipts() async throws {
        let recorder = BridgeProductWebKitFirstApplicationRecorder()
        let receipt = BridgeProductWebKitCarrierApplicationReceipt(
            applicationResult: .advanced, publicationId: UUIDv7.generate())
        recorder.record(.receipt(receipt))
        recorder.observe(sample(phase: "review_refresh_candidate_superseded", protocolName: "review"))
        recorder.record(.receipt(receipt))
        #expect(try await recorder.wait() == .receipt(receipt))
    }

    private func sample(phase: String, protocolName: String) -> BridgeTelemetrySample {
        BridgeTelemetrySample(
            scope: .web,
            name: phase.hasPrefix("review_refresh")
                ? "performance.bridge.web.review_refresh_lifecycle"
                : "performance.bridge.swift.metadata_bootstrap_lifecycle",
            durationMilliseconds: nil,
            traceContext: nil,
            stringAttributes: [
                "agentstudio.bridge.phase": phase,
                "agentstudio.bridge.protocol": protocolName,
                "agentstudio.bridge.result": "failure",
                "agentstudio.bridge.result_reason": "fixture_failure",
            ],
            numericAttributes: [:],
            booleanAttributes: [:]
        )
    }
}
