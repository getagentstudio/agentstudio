import Foundation
import Testing

@testable import AgentStudioInfrastructure

extension AgentStudioOTLPBridgeTraceProjectionTests {
    @Test
    func bridgeProjectionPreservesSafeProductStreamWebKitFeasibilityFacts() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductStreamWebKitFeasibilityStartupDiagnostics.swift:155: stream proof emits counts/verdicts, never body or capability text.
        let projection = OTLPProjectionAssertions.project(
            makeProductStreamWebKitFeasibilityProjectionCanaryRecord()
        )

        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.carrier.succeeded"
            ] == .bool(true))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.authentication_before_body.succeeded"
            ] == .bool(true))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.total_body_read.count"
            ] == .int(11))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.frame_receipt.count"
            ] == .int(4))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.abort_causal_cancellation.succeeded"
            ] == .bool(true))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.valid_stream_ended"
            ] == .bool(true))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.worker_observed_exact_frames"
            ] == .bool(true))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.active_producer_task.count"
            ] == .int(0))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.post_terminal_frame.count"
            ] == .int(0))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.failure.reason"
            ] == .string("none"))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.raw_capability"
            ] != nil)
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.product_stream_webkit.raw_body"
            ] != nil)
    }
}

private func makeProductStreamWebKitFeasibilityProjectionCanaryRecord() -> AgentStudioTraceRecord {
    // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductStreamWebKitFeasibilityStartupDiagnostics.swift:155: stream proof emits counts/verdicts, never body or capability text.
    AgentStudioTraceRecord(
        timeUnixNano: 133,
        severityText: .info,
        body: "app.startup_diagnostic_action.completed",
        traceID: nil,
        spanID: nil,
        parentSpanID: nil,
        resource: [
            "service.name": "AgentStudio"
        ],
        scope: .init(name: "agentstudio.app.startup", version: "0.1.0"),
        attributes: [
            "agentstudio.startup_diagnostic.action": .string(
                "bridge-product-stream-webkit-feasibility"),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.carrier.succeeded":
                .bool(true),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.authentication_before_body.succeeded":
                .bool(true),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.total_body_read.count": .int(11),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.frame_receipt.count": .int(4),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.abort_causal_cancellation.succeeded":
                .bool(true),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.valid_stream_ended":
                .bool(true),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.worker_observed_exact_frames":
                .bool(true),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.active_producer_task.count":
                .int(0),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.post_terminal_frame.count":
                .int(0),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.failure.reason":
                .string("none"),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.raw_capability":
                .string("private-capability"),
            "agentstudio.startup_diagnostic.bridge.product_stream_webkit.raw_body":
                .string("private-body"),
        ]
    )
}
