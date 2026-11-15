import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPBridgeTraceProjectionTests {
    @Test
    func bridgeProjectionPreservesReviewIntakeFrameDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 127,
            severityText: .info,
            body: "performance.bridge.web.intake_frame",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.intake.frame_kind": .string("review.metadataSnapshot"),
                "agentstudio.bridge.intake.generation": .int(1),
                "agentstudio.bridge.intake.sequence": .int(2),
                "agentstudio.bridge.item_id": .string("private-item-id"),
                "agentstudio.bridge.phase": .string("intake"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("cold"),
                "agentstudio.bridge.result": .string("dropped"),
                "agentstudio.bridge.result_reason": .string("sequence_gap"),
                "agentstudio.bridge.slice": .string("review_metadata"),
                "agentstudio.bridge.transport": .string("intake"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.intake.frame_kind"] == .string("review.metadataSnapshot"))
        #expect(projection.attributes["agentstudio.bridge.intake.generation"] == .int(1))
        #expect(projection.attributes["agentstudio.bridge.intake.sequence"] == .int(2))
        #expect(projection.attributes["agentstudio.bridge.result"] == .string("dropped"))
        #expect(projection.attributes["agentstudio.bridge.result_reason"] == .string("sequence_gap"))
        #expect(projection.attributes["agentstudio.bridge.item_id"] != nil)
    }

    @Test
    func bridgeProjectionPreservesViewerTimeToFirstInteractionDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:496: interaction telemetry emits typed kind/duration, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 512,
            severityText: .info,
            body: "performance.bridge.viewer.time_to_first_interaction",
            traceID: "0af7651916cd43dd8448eb211c80319c",
            spanID: "b7ad6b7169203331",
            parentSpanID: "00f067aa0ba902b7",
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("time_to_first_interaction"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.slice": .string("content_fetch"),
                "agentstudio.bridge.transport": .string("content"),
                "agentstudio.bridge.viewer": .string("file"),
                "agentstudio.bridge.viewer.ttfi_variant": .string("cold"),
                "agentstudio.bridge.visible_item.count": .int(12),
                "agentstudio.bridge.item_id": .string("private-item-id"),
                "agentstudio.performance.elapsed_ms": .double(287.5),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.viewer"] == .string("file"))
        #expect(projection.attributes["agentstudio.bridge.viewer.ttfi_variant"] == .string("cold"))
        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(287.5))
        #expect(projection.attributes["agentstudio.bridge.visible_item.count"] == .int(12))
        #expect(projection.attributes["agentstudio.bridge.item_id"] != nil)
    }

    @Test
    func bridgeProjectionPreservesTelemetryDropFirstRejectedEvent() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 513,
            severityText: .info,
            body: "performance.bridge.web.telemetry_drop",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("dropped"),
                "agentstudio.bridge.plane": .string("observability"),
                "agentstudio.bridge.priority": .string("best_effort"),
                "agentstudio.bridge.result": .string("dropped"),
                "agentstudio.bridge.slice": .string("telemetry_drop"),
                "agentstudio.bridge.telemetry.drop_reason": .string("unsafe_attribute"),
                "agentstudio.bridge.telemetry.dropped_count": .int(3),
                "agentstudio.bridge.telemetry.first_rejected_event": .string(
                    "performance.bridge.web.content_fetch"),
                "agentstudio.bridge.transport": .string("rpc"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.bridge.telemetry.first_rejected_event"]
                == .string("performance.bridge.web.content_fetch")
        )
    }

    @Test
    func bridgeProjectionPreservesReviewStartupCountDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let reviewReadyRecord = AgentStudioTraceRecord(
            timeUnixNano: 128,
            severityText: .info,
            body: "performance.bridge.web.review_ready",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.item_id": .string("private-item-id"),
                "agentstudio.bridge.phase": .string("review_ready"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.review.item_count": .int(42),
                "agentstudio.bridge.slice": .string("review_metadata"),
                "agentstudio.bridge.transport": .string("content"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )
        let selectedContentRecord = AgentStudioTraceRecord(
            timeUnixNano: 129,
            severityText: .info,
            body: "performance.bridge.web.selected_content_ready",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.content.resource_count": .int(2),
                "agentstudio.bridge.item_id": .string("private-item-id"),
                "agentstudio.bridge.phase": .string("selected_content_ready"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.slice": .string("content_fetch"),
                "agentstudio.bridge.transport": .string("content"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let reviewReadyProjection = OTLPProjectionAssertions.project(reviewReadyRecord)
        let selectedContentProjection = OTLPProjectionAssertions.project(selectedContentRecord)

        #expect(reviewReadyProjection.attributes["agentstudio.bridge.review.item_count"] == .int(42))
        #expect(selectedContentProjection.attributes["agentstudio.bridge.content.resource_count"] == .int(2))
        #expect(reviewReadyProjection.attributes["agentstudio.bridge.item_id"] != nil)
        #expect(selectedContentProjection.attributes["agentstudio.bridge.item_id"] != nil)
    }

    @Test
    func bridgeProjectionPreservesWorktreeFileDemandTimingDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 130,
            severityText: .info,
            body: "performance.bridge.web.content_fetch",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.content.byte_length": .int(2048),
                "agentstudio.bridge.content.correlation_mode": .string("summary"),
                "agentstudio.bridge.content.estimated_bytes": .int(4096),
                "agentstudio.bridge.content.first_chunk_wait_ms": .double(4.5),
                "agentstudio.bridge.content.response_wait_ms": .double(3.25),
                "agentstudio.bridge.content.role": .string("file"),
                "agentstudio.bridge.content.stream_read_ms": .double(9.75),
                "agentstudio.bridge.demand.lane": .string("foreground"),
                "agentstudio.bridge.file_size_bucket": .string("small"),
                "agentstudio.bridge.generation_relation": .string("current"),
                "agentstudio.bridge.item_id": .string("private-item-id"),
                "agentstudio.bridge.phase": .string("fetch"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.protocol": .string("worktree-file"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.result_reason": .string("none"),
                "agentstudio.bridge.slice": .string("content_fetch"),
                "agentstudio.bridge.transport": .string("content"),
                "agentstudio.bridge.viewer": .string("file"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.content.byte_length"] == .int(2048))
        #expect(projection.attributes["agentstudio.bridge.content.estimated_bytes"] == .int(4096))
        #expect(projection.attributes["agentstudio.bridge.content.first_chunk_wait_ms"] == .double(4.5))
        #expect(projection.attributes["agentstudio.bridge.content.response_wait_ms"] == .double(3.25))
        #expect(projection.attributes["agentstudio.bridge.content.stream_read_ms"] == .double(9.75))
        #expect(projection.attributes["agentstudio.bridge.demand.lane"] == .string("foreground"))
        #expect(projection.attributes["agentstudio.bridge.file_size_bucket"] == .string("small"))
        #expect(projection.attributes["agentstudio.bridge.generation_relation"] == .string("current"))
        #expect(projection.attributes["agentstudio.bridge.protocol"] == .string("worktree-file"))
        #expect(projection.attributes["agentstudio.bridge.viewer"] == .string("file"))
        #expect(projection.attributes["agentstudio.bridge.item_id"] != nil)
    }

    @Test
    func bridgeProjectionPreservesWorktreeFileVisibleDemandSettledDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 130,
            severityText: .info,
            body: "performance.bridge.web.visible_demand_settled",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.content.first_chunk_wait_ms": .double(4.5),
                "agentstudio.bridge.content.response_wait_ms": .double(3.25),
                "agentstudio.bridge.content.role": .string("file"),
                "agentstudio.bridge.content.stream_read_ms": .double(9.75),
                "agentstudio.bridge.demand.enqueue_accepted.count": .int(10),
                "agentstudio.bridge.demand.enqueue_rejected.count": .int(1),
                "agentstudio.bridge.demand.executor_in_flight_ms": .double(12.5),
                "agentstudio.bridge.demand.executor_pending_wait_ms": .double(1.5),
                "agentstudio.bridge.demand.failed.count": .int(1),
                "agentstudio.bridge.demand.intent.count": .int(11),
                "agentstudio.bridge.demand.lane": .string("visible"),
                "agentstudio.bridge.demand.loaded.count": .int(10),
                "agentstudio.bridge.demand.request.sequence": .int(4),
                "agentstudio.bridge.demand.scheduler_queue_wait_ms": .double(0.5),
                "agentstudio.bridge.item_id": .string("private-item-id"),
                "agentstudio.bridge.phase": .string("visible_demand_settled"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("failed"),
                "agentstudio.bridge.result_reason": .string("load_failed"),
                "agentstudio.bridge.slice": .string("content_fetch"),
                "agentstudio.bridge.transport": .string("content"),
                "agentstudio.bridge.viewer": .string("file"),
                "agentstudio.bridge.visible_item.count": .int(11),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.demand.enqueue_accepted.count"] == .int(10))
        #expect(projection.attributes["agentstudio.bridge.demand.enqueue_rejected.count"] == .int(1))
        #expect(projection.attributes["agentstudio.bridge.demand.executor_in_flight_ms"] == .double(12.5))
        #expect(projection.attributes["agentstudio.bridge.demand.executor_pending_wait_ms"] == .double(1.5))
        #expect(projection.attributes["agentstudio.bridge.demand.failed.count"] == .int(1))
        #expect(projection.attributes["agentstudio.bridge.demand.intent.count"] == .int(11))
        #expect(projection.attributes["agentstudio.bridge.demand.loaded.count"] == .int(10))
        #expect(projection.attributes["agentstudio.bridge.demand.request.sequence"] == .int(4))
        #expect(projection.attributes["agentstudio.bridge.demand.scheduler_queue_wait_ms"] == .double(0.5))
        #expect(projection.attributes["agentstudio.bridge.visible_item.count"] == .int(11))
        #expect(projection.attributes["agentstudio.bridge.item_id"] != nil)
    }

    @Test
    func bridgeProjectionPreservesWorktreeFileTreeWindowBatchDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 130,
            severityText: .info,
            body: "performance.bridge.swift.worktree_file_tree_window_batch",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("worktree_file_tree_window_batch"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("cold"),
                "agentstudio.bridge.slice": .string("tree_prepare_input"),
                "agentstudio.bridge.transport": .string("swift"),
                "agentstudio.bridge.worktree_file.pending_frame.count": .double(0),
                "agentstudio.bridge.worktree_file.tree.discovered_row.count": .double(600),
                "agentstudio.bridge.worktree_file.tree.window.dispatch_elapsed_ms": .double(5.25),
                "agentstudio.bridge.worktree_file.tree.window.is_final": .bool(false),
                "agentstudio.bridge.worktree_file.tree.window.prepare_elapsed_ms": .double(2.25),
                "agentstudio.bridge.worktree_file.tree.window.row.count": .double(200),
                "agentstudio.bridge.worktree_file.tree.window.sequence": .double(3),
                "agentstudio.bridge.worktree_file.tree.window.start_index": .double(400),
                "agentstudio.performance.elapsed_ms": .double(7.5),
                "agentstudio.trace.tag": .string("bridge.performance.swift"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.worktree_file.pending_frame.count"] == .double(0))
        #expect(projection.attributes["agentstudio.bridge.worktree_file.tree.discovered_row.count"] == .double(600))
        let dispatchElapsedKey = "agentstudio.bridge.worktree_file.tree.window.dispatch_elapsed_ms"
        #expect(projection.attributes[dispatchElapsedKey] == .double(5.25))
        #expect(projection.attributes["agentstudio.bridge.worktree_file.tree.window.is_final"] == .bool(false))
        let prepareElapsedKey = "agentstudio.bridge.worktree_file.tree.window.prepare_elapsed_ms"
        #expect(projection.attributes[prepareElapsedKey] == .double(2.25))
        #expect(projection.attributes["agentstudio.bridge.worktree_file.tree.window.row.count"] == .double(200))
        #expect(projection.attributes["agentstudio.bridge.worktree_file.tree.window.sequence"] == .double(3))
        #expect(projection.attributes["agentstudio.bridge.worktree_file.tree.window.start_index"] == .double(400))
        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(7.5))
    }

    @Test
    func bridgeProjectionPreservesWorktreeFileBrowserTreeApplyDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 130,
            severityText: .info,
            body: "performance.bridge.trees.prepare_input",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.fixture_class": .string("large"),
                "agentstudio.bridge.phase": .string("worktree_file_frame_apply"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("warm"),
                "agentstudio.bridge.projection.kind": .string("source"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.slice": .string("tree_prepare_input"),
                "agentstudio.bridge.transport": .string("worker"),
                "agentstudio.bridge.tree_path_count_bucket": .string("large"),
                "agentstudio.bridge.worktree_file.tree.current_row.count": .int(2000),
                "agentstudio.bridge.worktree_file.tree.descriptor.count": .int(8),
                "agentstudio.bridge.worktree_file.tree.incoming_frame.count": .int(1),
                "agentstudio.bridge.worktree_file.tree.window.row.count": .int(200),
                "agentstudio.performance.elapsed_ms": .double(42.5),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.phase"] == .string("worktree_file_frame_apply"))
        #expect(projection.attributes["agentstudio.bridge.tree_path_count_bucket"] == .string("large"))
        let currentRowCountKey = "agentstudio.bridge.worktree_file.tree.current_row.count"
        #expect(projection.attributes[currentRowCountKey] == .int(2000))
        #expect(projection.attributes["agentstudio.bridge.worktree_file.tree.descriptor.count"] == .int(8))
        #expect(projection.attributes["agentstudio.bridge.worktree_file.tree.incoming_frame.count"] == .int(1))
        #expect(projection.attributes["agentstudio.bridge.worktree_file.tree.window.row.count"] == .int(200))
        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(42.5))
    }

    @Test
    func bridgeProjectionPreservesNativeManifestTimingPhases() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let phases = [
            "metadata_open_to_first_window",
            "metadata_full_manifest_complete",
        ]

        for phase in phases {
            let record = AgentStudioTraceRecord(
                timeUnixNano: 131,
                severityText: .info,
                body: "performance.bridge.native.\(phase)",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: [
                    "service.name": "AgentStudio"
                ],
                scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
                attributes: [
                    "agentstudio.bridge.phase": .string(phase),
                    "agentstudio.bridge.plane": .string("data"),
                    "agentstudio.bridge.priority": .string("hot"),
                    "agentstudio.bridge.slice": .string("tree_prepare_input"),
                    "agentstudio.bridge.transport": .string("swift"),
                    "agentstudio.bridge.viewer": .string("file"),
                    "agentstudio.performance.elapsed_ms": .double(42.5),
                    "agentstudio.trace.tag": .string("bridge.performance.swift"),
                ]
            )

            let projection = OTLPProjectionAssertions.project(record)

            #expect(projection.attributes["agentstudio.bridge.phase"] == .string(phase))
            #expect(projection.attributes["agentstudio.bridge.plane"] == .string("data"))
            #expect(projection.attributes["agentstudio.bridge.slice"] == .string("tree_prepare_input"))
        }
    }

    @Test
    func bridgeProjectionPreservesReviewStartupMetadataCounts() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 131,
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
                "agentstudio.startup_diagnostic.action": .string("bridge-review-observability-smoke"),
                "agentstudio.startup_diagnostic.bridge.review_expected_item.count": .int(37),
                "agentstudio.startup_diagnostic.bridge.review_metadata_item.count": .int(36),
                "agentstudio.startup_diagnostic.bridge.review_metadata_tree_row.count": .int(80),
                "agentstudio.startup_diagnostic.bridge.review_shell.state": .string("projection_pending"),
                "agentstudio.startup_diagnostic.bridge.painted_probe.schedule_entered.count": .int(2),
                "agentstudio.startup_diagnostic.bridge.painted_probe.last_reason": .string("flush_called"),
                "agentstudio.startup_diagnostic.bridge.painted_probe.last_schedule_early_return.reason": .string(
                    "duplicate_selection_demand"),
                "agentstudio.startup_diagnostic.pane.id": .string("private-pane-id"),
                "agentstudio.startup_diagnostic.render_proof.succeeded": .bool(false),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.startup_diagnostic.bridge.review_expected_item.count"] == .int(37)
        )
        #expect(
            projection.attributes["agentstudio.startup_diagnostic.bridge.review_metadata_item.count"] == .int(36)
        )
        #expect(
            projection.attributes["agentstudio.startup_diagnostic.bridge.review_metadata_tree_row.count"] == .int(80)
        )
        #expect(
            projection.attributes["agentstudio.startup_diagnostic.bridge.review_shell.state"]
                == .string("projection_pending")
        )
        #expect(
            projection.attributes["agentstudio.startup_diagnostic.bridge.painted_probe.schedule_entered.count"]
                == .int(2)
        )
        #expect(
            projection.attributes["agentstudio.startup_diagnostic.bridge.painted_probe.last_reason"]
                == .string("flush_called")
        )
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.painted_probe.last_schedule_early_return.reason"
            ] == .string("duplicate_selection_demand")
        )
        #expect(projection.attributes["agentstudio.startup_diagnostic.pane.id"] != nil)
    }

    @Test
    func bridgeProjectionPreservesReviewTreeClickProbeHandlerDiagnostics() {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeReviewStartupDiagnosticRenderProof.swift:669; production tree-click proof records selection diagnostics, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 132,
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
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.handler_invoked_delta": .int(1),
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_command_issued_delta":
                    .int(1),
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_command_accepted.count":
                    .int(1),
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_command.last_result":
                    .string("accepted"),
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.late_selected_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.capture_handler_row_item_id":
                    .string("private-item-id"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.handler_invoked_delta"
            ] == .int(1))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_command_issued_delta"
            ] == .int(1))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_command_accepted.count"
            ] == .int(1))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.selection_command.last_result"
            ] == .string("accepted"))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.late_selected_matches"
            ] == .bool(true))
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.bridge.review_tree_click.probe.capture_handler_row_item_id"
            ] != nil)
    }

    @Test
    func bridgeProjectionPreservesFileViewStartupDiagnosticProofWithRecordedPaths() {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeFileViewStartupDiagnosticRenderProof.swift:355; production file-view proof records preview length, never preview text.
        let projection = OTLPProjectionAssertions.project(
            makeFileViewStartupDiagnosticProjectionCanaryRecord()
        )

        assertFileViewStartupVisibilityAndBootstrapAttributes(projection.attributes)
        assertFileViewStartupTreeExtentAttributes(projection.attributes)
        assertFileViewStartupCommandCountAttributes(projection.attributes)
        assertFileViewStartupNativeProbeAttributes(projection.attributes)
        assertFileViewStartupClickAttributes(projection.attributes)
        assertFileViewStartupRawPathAttributesAreRetained(
            attributes: projection.attributes
        )
    }

    private func assertFileViewStartupVisibilityAndBootstrapAttributes(
        _ attributes: [String: AgentStudioTraceValue]
    ) {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeFileViewStartupDiagnosticRenderProof.swift:355; production file-view proof records preview length, never preview text.
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.shell.visible"] == .bool(true))
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.tree.visible"] == .bool(true))
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.code_view.visible"] == .bool(true))
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.source.state"] == .string("live"))
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.bootstrap.protocol"]
                == .string("worktree-file")
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.expected_bootstrap.protocol"]
                == .string("worktree-file")
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.open_file.state"] == .string("ready"))
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.descriptor.count"] == .int(4))
    }

    private func assertFileViewStartupTreeExtentAttributes(_ attributes: [String: AgentStudioTraceValue]) {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeFileViewStartupDiagnosticRenderProof.swift:355; production file-view proof records preview length, never preview text.
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.metadata_tree_row.count"] == .int(200)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.tree_extent.kind"]
                == .string("exactPathCount")
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.tree_path.count"] == .int(260))
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.metadata_file_row.count"] == .int(164))
    }

    private func assertFileViewStartupCommandCountAttributes(_ attributes: [String: AgentStudioTraceValue]) {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeFileViewStartupDiagnosticRenderProof.swift:355; production file-view proof records preview length, never preview text.
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.open_source_command.count"] == .int(1)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.intake_ready_command.count"] == .int(1)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.descriptor_request_command.count"] == .int(1)
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.bridge_response.count"] == .int(1))
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.intake_frame.count"] == .int(2))
    }

    private func assertFileViewStartupNativeProbeAttributes(_ attributes: [String: AgentStudioTraceValue]) {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeFileViewStartupDiagnosticRenderProof.swift:355; production file-view proof records preview length, never preview text.
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.count"] == .int(4))
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_reason"]
                == .string("snapshot_resolved")
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_receiver_reason"]
                == .string("none")
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_frame_kind"]
                == .string("worktree.snapshot")
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_generation"] == .int(1))
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_receiver_generation"]
                == .int(1)
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_sequence"] == .int(7))
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_stream_id_matches"]
                == .bool(true)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.frame_evidence.count"]
                == .int(5)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.final_generation"]
                == .int(1)
        )
        #expect(
            attributes[
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.final_generation_frame_evidence.count"
            ] == .int(5)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.native_probe.failure_drop.count"]
                == .int(0)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.tree_full_stream.satisfied"] == .bool(true)
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.page_issue.last_class"] == .string("none"))
    }

    private func assertFileViewStartupClickAttributes(_ attributes: [String: AgentStudioTraceValue]) {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeFileViewStartupDiagnosticRenderProof.swift:355; production file-view proof records preview length, never preview text.
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.click.target_found"] == .bool(true))
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.click.selected_matches"] == .bool(true))
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.click.open_file_matches"] == .bool(true))
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.click.rendered_file_matches"] == .bool(true)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.click.body_preview.length"] == .int(96)
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.second_click.target_found"] == .bool(true))
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.second_click.selected_matches"] == .bool(true)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.second_click.open_file_matches"] == .bool(true)
        )
        let secondClickRenderedMatchesKey =
            "agentstudio.startup_diagnostic.bridge.file_view.second_click.rendered_file_matches"
        #expect(
            attributes[secondClickRenderedMatchesKey] == .bool(true)
        )
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.second_click.body_preview.length"] == .int(128)
        )
        let offscreenTargetFoundKey = "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.target_found"
        #expect(attributes[offscreenTargetFoundKey] == .bool(true))
        let offscreenSelectedMatchesKey =
            "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.selected_matches"
        #expect(
            attributes[offscreenSelectedMatchesKey] == .bool(true)
        )
        let offscreenOpenFileMatchesKey =
            "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.open_file_matches"
        #expect(
            attributes[offscreenOpenFileMatchesKey] == .bool(true)
        )
        let offscreenRenderedMatchesKey =
            "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.rendered_file_matches"
        #expect(
            attributes[offscreenRenderedMatchesKey] == .bool(true)
        )
        let offscreenBodyPreviewLengthKey =
            "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.body_preview.length"
        #expect(
            attributes[offscreenBodyPreviewLengthKey] == .int(144)
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.mode_switch.count"] == .int(5))
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.mode_switch.final_file_selected"]
                == .bool(true)
        )
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.tree_scroll_stress.count"] == .int(4))
        #expect(
            attributes["agentstudio.startup_diagnostic.bridge.file_view.tree_scroll_stress.reached_bottom"]
                == .bool(true)
        )
    }

    private func assertFileViewStartupRawPathAttributesAreRetained(
        attributes: [String: AgentStudioTraceValue]
    ) {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeFileViewStartupDiagnosticRenderProof.swift:355; production file-view proof records preview length, never preview text.
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.open_file.path"] != nil)
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.rendered_file.path"] != nil)
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.selected_path"] != nil)
        #expect(attributes["agentstudio.startup_diagnostic.bridge.file_view.click.target_path"] != nil)
    }

    private func makeFileViewStartupDiagnosticProjectionCanaryRecord() -> AgentStudioTraceRecord {
        // R10: synthetic text bypasses Sources/AgentStudio/App/Boot/BridgeFileViewStartupDiagnosticRenderProof.swift:355; production file-view proof records preview length, never preview text.
        AgentStudioTraceRecord(
            timeUnixNano: 131,
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
                "agentstudio.startup_diagnostic.action": .string("bridge-file-view-observability-smoke"),
                "agentstudio.startup_diagnostic.bridge.file_view.expected_bootstrap.protocol": .string(
                    "worktree-file"),
                "agentstudio.startup_diagnostic.bridge.file_view.bootstrap.protocol": .string("worktree-file"),
                "agentstudio.startup_diagnostic.bridge.file_view.body_preview.length": .int(120),
                "agentstudio.startup_diagnostic.bridge.file_view.code_text.length": .int(240),
                "agentstudio.startup_diagnostic.bridge.file_view.code_view.height_px": .int(720),
                "agentstudio.startup_diagnostic.bridge.file_view.code_view.visible": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.code_view.width_px": .int(1280),
                "agentstudio.startup_diagnostic.bridge.file_view.bridge_command.count": .int(2),
                "agentstudio.startup_diagnostic.bridge.file_view.bridge_response.count": .int(1),
                "agentstudio.startup_diagnostic.bridge.file_view.click.body_preview.length": .int(96),
                "agentstudio.startup_diagnostic.bridge.file_view.click.open_file_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.click.rendered_file_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.click.selected_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.click.target_found": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.click.target_path": .string("Sources/Clicked.swift"),
                "agentstudio.startup_diagnostic.bridge.file_view.second_click.body_preview.length": .int(128),
                "agentstudio.startup_diagnostic.bridge.file_view.second_click.open_file_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.second_click.rendered_file_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.second_click.selected_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.second_click.target_found": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.body_preview.length": .int(144),
                "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.open_file_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.rendered_file_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.selected_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.target_found": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.descriptor.count": .int(4),
                "agentstudio.startup_diagnostic.bridge.file_view.descriptor_request_command.count": .int(1),
                "agentstudio.startup_diagnostic.bridge.file_view.intake_frame.count": .int(2),
                "agentstudio.startup_diagnostic.bridge.file_view.intake_ready_command.count": .int(1),
                "agentstudio.startup_diagnostic.bridge.file_view.metadata_file_row.count": .int(164),
                "agentstudio.startup_diagnostic.bridge.file_view.metadata_tree_row.count": .int(200),
                "agentstudio.startup_diagnostic.bridge.file_view.mode_switch.count": .int(5),
                "agentstudio.startup_diagnostic.bridge.file_view.mode_switch.final_file_selected": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.count": .int(4),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.failure_drop.count": .int(0),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.final_generation": .int(1),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.final_generation_frame_evidence.count":
                    .int(5),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.frame_evidence.count": .int(5),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_frame_kind": .string(
                    "worktree.snapshot"),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_generation": .int(1),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_receiver_generation": .int(1),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_sequence": .int(7),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_reason": .string(
                    "snapshot_resolved"),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_receiver_reason": .string("none"),
                "agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_stream_id_matches": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.open_file.path": .string("Sources/App.swift"),
                "agentstudio.startup_diagnostic.bridge.file_view.open_file.state": .string("ready"),
                "agentstudio.startup_diagnostic.bridge.file_view.open_source_command.count": .int(1),
                "agentstudio.startup_diagnostic.bridge.file_view.rendered_file.path": .string("Sources/App.swift"),
                "agentstudio.startup_diagnostic.bridge.file_view.selected_path": .string("Sources/App.swift"),
                "agentstudio.startup_diagnostic.bridge.file_view.shell.visible": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.source.state": .string("live"),
                "agentstudio.startup_diagnostic.bridge.file_view.tree_extent.kind": .string("exactPathCount"),
                "agentstudio.startup_diagnostic.bridge.file_view.tree_path.count": .int(260),
                "agentstudio.startup_diagnostic.bridge.file_view.tree_scroll_stress.count": .int(4),
                "agentstudio.startup_diagnostic.bridge.file_view.tree_scroll_stress.reached_bottom": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.total_descriptor.count": .int(4),
                "agentstudio.startup_diagnostic.bridge.file_view.tree.height_px": .int(1024),
                "agentstudio.startup_diagnostic.bridge.file_view.tree.visible": .bool(true),
                "agentstudio.startup_diagnostic.bridge.file_view.tree_full_stream.satisfied": .bool(true),
                "agentstudio.startup_diagnostic.bridge.page_issue.count": .int(0),
                "agentstudio.startup_diagnostic.bridge.page_issue.last_class": .string("none"),
                "agentstudio.startup_diagnostic.bridge.page_issue.last_kind": .string("none"),
                "agentstudio.startup_diagnostic.bridge.worker_diagnostic.file_success_count": .int(1),
                "agentstudio.startup_diagnostic.render_proof.succeeded": .bool(true),
            ]
        )
    }

}
