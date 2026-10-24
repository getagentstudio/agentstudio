import Foundation
import Testing

@testable import AgentStudioInfrastructure

extension AgentStudioOTLPBridgeTraceProjectionTests {
    @Test
    func bridgeProjectionPreservesSafeReviewTreeClickProbeDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/BridgeReviewStartupDiagnosticRenderProof.swift:669: tree-click proof emits diagnostics, never agent message text.
        let projection = OTLPProjectionAssertions.project(
            makeReviewTreeClickProbeProjectionCanaryRecord()
        )

        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.dispatch_result"
            ] == .string("completed"))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.rendered_row_count_at_find"
            ] == .int(7))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.rendered_row_count_at_dispatch"
            ] == .int(8))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.rendered_row_count_delta_before_dispatch"
            ] == .int(1))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_poll.count"
            ] == .int(2))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_poll.last_index"
            ] == .int(1))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.polls_to_selection_match"
            ] == .int(42))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.click_to_selection_ms"
            ] == .int(2100))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_connected_at_dispatch"
            ] == .bool(true))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_same_id_at_dispatch"
            ] == .bool(true))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.second_click_attempted"
            ] == .bool(false))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_poll_trace"
            ] != nil)
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_id_at_find"
            ] != nil)
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_path_at_find"
            ] != nil)
    }
}

private func makeReviewTreeClickProbeProjectionCanaryRecord() -> AgentStudioTraceRecord {
    // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/BridgeReviewStartupDiagnosticRenderProof.swift:669: tree-click proof emits diagnostics, never agent message text.
    AgentStudioTraceRecord(
        timeUnixNano: 132,
        severityText: .info,
        body: "app.startup_diagnostic_action.blocked",
        traceID: nil,
        spanID: nil,
        parentSpanID: nil,
        resource: [
            "service.name": "AgentStudio"
        ],
        scope: .init(name: "agentstudio.app.startup", version: "0.1.0"),
        attributes: [
            "agentstudio.startup_diagnostic.action": .string("bridge-review-observability-smoke"),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.dispatch_result": .string(
                "completed"),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.rendered_row_count_at_dispatch": .int(8),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.rendered_row_count_at_find": .int(7),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.rendered_row_count_delta_before_dispatch":
                .int(1),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.second_click_attempted": .bool(false),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_poll.count": .int(2),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_poll.last_index": .int(1),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.polls_to_selection_match": .int(42),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.click_to_selection_ms": .int(2100),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_poll_trace": .string(
                "0:private-initial-item|1:private-target-item"),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_connected_at_dispatch":
                .bool(true),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_id_at_dispatch": .string(
                "private-target-row"),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_id_at_find": .string(
                "private-target-row"),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_path_at_find": .string(
                "Sources/App/Private.swift"),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.target_row_same_id_at_dispatch": .bool(true),
            "agentstudio.startup_diagnostic.render_proof.succeeded": .bool(false),
        ]
    )
}
