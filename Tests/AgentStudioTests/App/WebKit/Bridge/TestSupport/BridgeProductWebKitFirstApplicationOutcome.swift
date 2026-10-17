import AgentStudioTestHarness
import Synchronization

@testable import AgentStudioBridge

enum BridgeProductWebKitFirstApplicationOutcome: Equatable, Sendable {
    case receipt(BridgeProductWebKitCarrierApplicationReceipt)
    case ended(phase: String, reason: String)
}

/// Joins the existing receipt and telemetry seams without leaving a success-only waiter.
final class BridgeProductWebKitFirstApplicationRecorder: Sendable {
    private let hasOutcome = Mutex(false)
    private let outcomes = FactRecorder<String, BridgeProductWebKitFirstApplicationOutcome>(
        vocabulary: .init(
            describeScope: { $0 }, describeFact: { String(describing: $0) }, isClosing: { _, _ in true }
        )
    )

    func record(_ outcome: BridgeProductWebKitFirstApplicationOutcome) {
        let isFirst = hasOutcome.withLock { recorded in
            guard !recorded else { return false }
            recorded = true
            return true
        }
        if isFirst { outcomes.append(scope: "first Review application", fact: outcome) }
    }

    func observe(_ sample: BridgeTelemetrySample) {
        let attributes = sample.stringAttributes
        guard let phase = attributes["agentstudio.bridge.phase"] else { return }
        let reason = attributes["agentstudio.bridge.result_reason"] ?? "none"
        let isNativeReviewEnd =
            attributes["agentstudio.bridge.protocol"] == "review"
            && ["metadata_producer_failed", "metadata_producer_cancelled", "review_metadata_publication_failed"]
                .contains(phase)
        let isPageReviewEnd =
            sample.name == "performance.bridge.web.review_refresh_lifecycle"
            && (phase == "review_refresh_candidate_failed"
                || phase == "review_refresh_candidate_superseded"
                || phase == "review_refresh_cleanup_terminal"
                || (phase == "review_refresh_install_terminal" && attributes["agentstudio.bridge.result"] != "success"))
        if isNativeReviewEnd || isPageReviewEnd { record(.ended(phase: phase, reason: reason)) }
    }

    func wait() async throws -> BridgeProductWebKitFirstApplicationOutcome {
        try await outcomes.expectNext(
            in: "first Review application", where: { _ in true }, "receipt or named failure/retirement")
    }
}
