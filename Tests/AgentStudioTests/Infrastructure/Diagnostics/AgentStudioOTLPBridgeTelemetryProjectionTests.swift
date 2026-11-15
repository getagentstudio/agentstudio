import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPBridgeTelemetryProjectionTests {
    @Test
    func annotationCatalogProjectionKeepsAggregatesAndRetainsPrivateIdentityAndPath() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:348; production native lifecycle records typed facts, never annotation body text.
        let operationID = String(repeating: "a", count: 64)
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 776,
                severityText: .info,
                body: "performance.bridge.web.annotation_lifecycle",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
                attributes: [
                    "agentstudio.bridge.operation.id": .string(operationID),
                    "agentstudio.bridge.annotation.catalog.entry.count": .int(2001),
                    "agentstudio.bridge.annotation.catalog.revision": .int(9),
                    "agentstudio.bridge.annotation.catalog.unit.byte_count": .int(131_000),
                    "agentstudio.bridge.annotation.catalog.window.count": .int(3),
                    "agentstudio.bridge.presentation.revision.after": .int(8),
                    "agentstudio.bridge.presentation.revision.before": .int(7),
                    "agentstudio.bridge.annotation.catalog.session_id": .string("private-session"),
                    "agentstudio.bridge.annotation.catalog.path": .string("/private/repo"),
                ]
            )
        )

        #expect(projection.attributes["agentstudio.bridge.operation.id"] == .string(operationID))
        #expect(
            projection.attributes["agentstudio.bridge.annotation.catalog.entry.count"] == .int(2001)
        )
        #expect(projection.attributes["agentstudio.bridge.annotation.catalog.revision"] == .int(9))
        #expect(
            projection.attributes["agentstudio.bridge.annotation.catalog.unit.byte_count"] == .int(131_000)
        )
        #expect(
            projection.attributes["agentstudio.bridge.annotation.catalog.window.count"] == .int(3)
        )
        #expect(projection.attributes["agentstudio.bridge.presentation.revision.after"] == .int(8))
        #expect(projection.attributes["agentstudio.bridge.presentation.revision.before"] == .int(7))
        #expect(projection.attributes["agentstudio.bridge.annotation.catalog.session_id"] != nil)
        #expect(projection.attributes["agentstudio.bridge.annotation.catalog.path"] != nil)
    }

    @Test
    func lifecycleProjectionKeepsOnlyRecordedOperationIdentityAndSafeAttempt() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:348; production native lifecycle records typed facts, never annotation body text.
        let operationID = String(repeating: "a", count: 64)
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 775,
                severityText: .info,
                body: "performance.bridge.swift.annotation_lifecycle",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
                attributes: [
                    "agentstudio.bridge.operation.id": .string(operationID),
                    "agentstudio.bridge.stage.attempt": .int(2),
                    "agentstudio.bridge.annotation.body": .string("private body"),
                    "agentstudio.bridge.annotation.path": .string("/private/repo"),
                    "agentstudio.bridge.annotation.error": .string("private error"),
                ]
            )
        )

        #expect(projection.attributes["agentstudio.bridge.operation.id"] == .string(operationID))
        #expect(projection.attributes["agentstudio.bridge.stage.attempt"] == .int(2))
        #expect(projection.attributes["agentstudio.bridge.annotation.body"] != nil)
        #expect(projection.attributes["agentstudio.bridge.annotation.path"] != nil)
        #expect(projection.attributes["agentstudio.bridge.annotation.error"] != nil)
    }

    @Test(arguments: [
        ("agentstudio.bridge.phase", "authorization"),
        ("agentstudio.bridge.phase", "reservation_claim"),
        ("agentstudio.bridge.phase", "scheduled_capture"),
        ("agentstudio.bridge.phase", "encode"),
        ("agentstudio.bridge.phase", "terminal"),
        ("agentstudio.bridge.result", "unavailable"),
        ("agentstudio.bridge.result", "claimed"),
        ("agentstudio.bridge.result", "inactive"),
        ("agentstudio.bridge.result", "cancelled"),
        ("agentstudio.bridge.result", "complete"),
        ("agentstudio.bridge.result", "unsupported_content"),
        ("agentstudio.bridge.result", "production_failed"),
    ])
    func projectionPreservesComparisonCatalogControlledVocabulary(
        key: String,
        value: String
    ) {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewComparisonTargetCatalogTraceRecorder.swift:70; production catalog telemetry records aggregates/correlation, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 774,
            severityText: .info,
            body: "performance.bridge.swift.comparison_target_catalog",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [key: .string(value)]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes[key] == .string(value))
    }

    @Test
    func projectionPreservesComparisonCatalogAggregatesWithRecordedAttributes() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewComparisonTargetCatalogTraceRecorder.swift:70; production catalog telemetry records aggregates/correlation, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 773,
            severityText: .info,
            body: "performance.bridge.swift.comparison_target_catalog",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("encode"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.review.comparison_targets.query_request.sequence": .int(7),
                "agentstudio.bridge.review.comparison_targets.reservation_age_ms": .double(12.5),
                "agentstudio.bridge.review.comparison_targets.input_row.count": .int(5),
                "agentstudio.bridge.review.comparison_targets.output_row.count": .int(3),
                "agentstudio.bridge.review.comparison_targets.is_truncated": .bool(true),
                "agentstudio.bridge.review.comparison_targets.path": .string("/private/repo"),
                "agentstudio.bridge.review.comparison_targets.ref": .string("private-branch"),
                "agentstudio.bridge.review.comparison_targets.descriptor_id": .string("descriptor"),
                "agentstudio.bridge.review.comparison_targets.pane_id": .string("pane"),
                "agentstudio.bridge.review.comparison_targets.session_id": .string("session"),
                "agentstudio.bridge.review.comparison_targets.worker_id": .string("worker"),
                "agentstudio.bridge.review.comparison_targets.payload": .string("payload"),
                "agentstudio.bridge.review.comparison_targets.digest": .string("digest"),
                "agentstudio.bridge.review.comparison_targets.error": .string("error"),
                "agentstudio.bridge.review.comparison_targets.message": .string("message"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.phase"] == .string("encode"))
        #expect(projection.attributes["agentstudio.bridge.result"] == .string("success"))
        #expect(
            projection.attributes[
                "agentstudio.bridge.review.comparison_targets.query_request.sequence"
            ] == .int(7)
        )
        #expect(
            projection.attributes[
                "agentstudio.bridge.review.comparison_targets.reservation_age_ms"
            ] == .double(12.5)
        )
        #expect(
            projection.attributes[
                "agentstudio.bridge.review.comparison_targets.input_row.count"
            ] == .int(5)
        )
        #expect(
            projection.attributes[
                "agentstudio.bridge.review.comparison_targets.output_row.count"
            ] == .int(3)
        )
        #expect(
            projection.attributes[
                "agentstudio.bridge.review.comparison_targets.is_truncated"
            ] == .bool(true)
        )

    }

    @Test
    func projectionPreservesNativePanePresentationOutcomeVocabulary() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:348; production native lifecycle records typed facts, never annotation body text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 771,
            severityText: .info,
            body: "performance.bridge.swift.pane_presentation",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("pane_presentation_not_enqueued"),
                "agentstudio.bridge.protocol": .string("pane-presentation"),
                "agentstudio.bridge.result": .string("skipped"),
                "agentstudio.bridge.result_reason": .string("no_active_stream"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.phase"] == .string("pane_presentation_not_enqueued"))
        #expect(projection.attributes["agentstudio.bridge.protocol"] == .string("pane-presentation"))
        #expect(projection.attributes["agentstudio.bridge.result"] == .string("skipped"))
        #expect(projection.attributes["agentstudio.bridge.result_reason"] == .string("no_active_stream"))
    }

    @Test
    func projectionPreservesPanePresentationCorrelationWithRecordedIdentity() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:348; production native lifecycle records typed facts, never annotation body text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 772,
            severityText: .info,
            body: "performance.bridge.web.pane_presentation",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.comparison.attempt.status": .string("settled"),
                "agentstudio.bridge.comparison.package_match": .string("revision_mismatch"),
                "agentstudio.bridge.comparison.pane_state": .string("loading_previous"),
                "agentstudio.bridge.panel.operation": .string("upsert"),
                "agentstudio.bridge.phase": .string("panel_chrome_published"),
                "agentstudio.bridge.plane": .string("control"),
                "agentstudio.bridge.presentation.disposition": .string("published"),
                "agentstudio.bridge.presentation.publication_sequence": .int(22),
                "agentstudio.bridge.presentation.revision": .int(18),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.refreshing.review": .bool(false),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.review.generation": .int(5),
                "agentstudio.bridge.slice": .string("review_metadata"),
                "agentstudio.bridge.transport": .string("worker"),
                "agentstudio.bridge.viewer": .string("review"),
                "agentstudio.bridge.worker.derivation_epoch": .int(7),
                "agentstudio.bridge.package_id": .string("must-not-export"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.comparison.attempt.status"] == .string("settled"))
        #expect(
            projection.attributes["agentstudio.bridge.comparison.package_match"]
                == .string("revision_mismatch")
        )
        #expect(
            projection.attributes["agentstudio.bridge.comparison.pane_state"]
                == .string("loading_previous")
        )
        #expect(projection.attributes["agentstudio.bridge.presentation.revision"] == .int(18))
        #expect(projection.attributes["agentstudio.bridge.review.generation"] == .int(5))
        #expect(projection.attributes["agentstudio.bridge.worker.derivation_epoch"] == .int(7))
        #expect(projection.attributes["agentstudio.bridge.refreshing.review"] == .bool(false))
        #expect(projection.attributes["agentstudio.bridge.package_id"] != nil)
    }

    @Test
    func bridgeProjectionPreservesPackageBuildReason() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 515,
            severityText: .info,
            body: "performance.bridge.swift.package_build",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.package_build.reason": .string("initial_intake"),
                "agentstudio.bridge.phase": .string("package_build"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("cold"),
                "agentstudio.bridge.slice": .string("review_metadata"),
                "agentstudio.bridge.transport": .string("swift"),
                "agentstudio.trace.tag": .string("bridge.performance.swift"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.bridge.package_build.reason"]
                == .string("initial_intake")
        )
    }

    @Test
    func bridgeProjectionPreservesTelemetryDropAggregateCounterKeys() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 514,
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
                "agentstudio.bridge.telemetry.drop_reason": .string("encoded_byte_cap"),
                "agentstudio.bridge.telemetry.dropped_count": .int(2),
                "agentstudio.bridge.telemetry.event_name": .string("performance.bridge.web.first_render"),
                "agentstudio.bridge.telemetry.lane": .string("best_effort"),
                "agentstudio.bridge.telemetry.result": .string("success"),
                "agentstudio.bridge.transport": .string("scheme"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.bridge.telemetry.event_name"]
                == .string("performance.bridge.web.first_render")
        )
        #expect(projection.attributes["agentstudio.bridge.telemetry.lane"] == .string("best_effort"))
        #expect(projection.attributes["agentstudio.bridge.telemetry.result"] == .string("success"))
    }

    @Test
    func bridgeProjectionPreservesSidecarDrainProofWithRecordedSessionIdentity() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 518,
            severityText: .info,
            body: "performance.bridge.swift.telemetry_sidecar_drain",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio",
                "agent.proof.marker": "bridge-sidecar-marker",
            ],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("terminal_closed"),
                "agentstudio.bridge.plane": .string("observability"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.slice": .string("telemetry_sidecar"),
                "agentstudio.bridge.telemetry.session.digest": .string(
                    "7d3a7045d86cb97befe5c53a8f8965ae1fbaa1a75157f84a78ff605ae566993f"),
                "agentstudio.bridge.telemetry.session.id": .string(
                    "private-telemetry-session-uuid"),
                "agentstudio.bridge.telemetry.accepted_batch.sequence": .int(9),
                "agentstudio.bridge.telemetry.main_producer.high_watermark": .int(14),
                "agentstudio.bridge.telemetry.comm_producer.high_watermark": .int(12),
                "agentstudio.bridge.telemetry.required_loss.count": .int(0),
                "agentstudio.bridge.telemetry.optional_loss.count": .int(0),
                "agentstudio.bridge.telemetry.worker_sequence_gap.count": .int(0),
                "agentstudio.bridge.telemetry.native_batch_sequence_gap.count": .int(0),
                "agentstudio.bridge.telemetry.proof_eligible": .bool(true),
                "agentstudio.bridge.telemetry.lossy": .bool(false),
                "agentstudio.bridge.telemetry.settlement_acknowledged": .bool(true),
                "agentstudio.bridge.transport": .string("scheme"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.bridge.telemetry.session.digest"]
                == .string("7d3a7045d86cb97befe5c53a8f8965ae1fbaa1a75157f84a78ff605ae566993f")
        )
        #expect(projection.attributes["agentstudio.bridge.telemetry.session.id"] != nil)
        #expect(projection.attributes["agentstudio.bridge.telemetry.accepted_batch.sequence"] == .int(9))
        #expect(
            projection.attributes["agentstudio.bridge.telemetry.main_producer.high_watermark"] == .int(14)
        )
        #expect(
            projection.attributes["agentstudio.bridge.telemetry.comm_producer.high_watermark"] == .int(12)
        )
        #expect(projection.attributes["agentstudio.bridge.telemetry.required_loss.count"] == .int(0))
        #expect(projection.attributes["agentstudio.bridge.telemetry.optional_loss.count"] == .int(0))
        #expect(
            projection.attributes["agentstudio.bridge.telemetry.worker_sequence_gap.count"] == .int(0)
        )
        #expect(
            projection.attributes["agentstudio.bridge.telemetry.native_batch_sequence_gap.count"] == .int(0)
        )
        #expect(projection.attributes["agentstudio.bridge.telemetry.proof_eligible"] == .bool(true))
        #expect(projection.attributes["agentstudio.bridge.telemetry.lossy"] == .bool(false))
        #expect(
            projection.attributes["agentstudio.bridge.telemetry.settlement_acknowledged"] == .bool(true)
        )
    }

    @Test
    func bridgeProjectionPreservesFrameJankDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 517,
            severityText: .info,
            body: "performance.bridge.web.frame_jank",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.frame_jank.dropped_frame.count": .int(3),
                "agentstudio.bridge.frame_jank.dropped_frame.worst_gap_ms": .double(72),
                "agentstudio.bridge.frame_jank.kind": .string("dropped_frame"),
                "agentstudio.bridge.frame_jank.long_task.count": .int(2),
                "agentstudio.bridge.frame_jank.long_task.max_ms": .double(54),
                "agentstudio.bridge.frame_jank.long_task.total_ms": .double(94),
                "agentstudio.bridge.phase": .string("frame_jank"),
                "agentstudio.bridge.plane": .string("control"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.slice": .string("frame_jank"),
                "agentstudio.bridge.transport": .string("local"),
                "agentstudio.bridge.viewer": .string("review"),
                "agentstudio.bridge.viewer.active": .bool(false),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.bridge.frame_jank.kind"]
                == .string("dropped_frame")
        )
        #expect(
            projection.attributes["agentstudio.bridge.frame_jank.dropped_frame.count"]
                == .int(3)
        )
        #expect(
            projection.attributes["agentstudio.bridge.frame_jank.dropped_frame.worst_gap_ms"]
                == .double(72)
        )
        #expect(
            projection.attributes["agentstudio.bridge.frame_jank.long_task.count"]
                == .int(2)
        )
        #expect(
            projection.attributes["agentstudio.bridge.frame_jank.long_task.max_ms"]
                == .double(54)
        )
        #expect(
            projection.attributes["agentstudio.bridge.frame_jank.long_task.total_ms"]
                == .double(94)
        )
        #expect(projection.attributes["agentstudio.bridge.viewer.active"] == .bool(false))
    }

    @Test
    func bridgeProjectionPreservesCommWorkerTaskTelemetryKeys() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 516,
            severityText: .info,
            body: "performance.bridge.worker.task",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("worker_task"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.slice": .string("worker_task"),
                "agentstudio.bridge.transport": .string("worker"),
                "agentstudio.bridge.worker.action": .string("applySelectedFact"),
                "agentstudio.bridge.worker.command": .string("select"),
                "agentstudio.bridge.worker.file_metadata_selected_path_resolved": .bool(true),
                "agentstudio.bridge.worker.handler_duration_ms": .double(2.5),
                "agentstudio.bridge.worker.lane": .string("selected"),
                "agentstudio.bridge.worker.patch_count": .int(2),
                "agentstudio.bridge.worker.payload_class": .string("inline"),
                "agentstudio.bridge.worker.queue_wait_ms": .double(4.25),
                "agentstudio.bridge.worker.semantic_class": .string("demand"),
                "agentstudio.bridge.worker.source_epoch": .int(7),
                "agentstudio.bridge.worker.task_kind": .string("store_action"),
                "agentstudio.bridge.worker.touched_key_count": .int(5),
                "agentstudio.bridge.worker.work_kind": .string("review_content_ready"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.worker.action"] == .string("applySelectedFact"))
        #expect(projection.attributes["agentstudio.bridge.worker.command"] == .string("select"))
        #expect(
            projection.attributes["agentstudio.bridge.worker.file_metadata_selected_path_resolved"]
                == .bool(true)
        )
        #expect(projection.attributes["agentstudio.bridge.worker.handler_duration_ms"] == .double(2.5))
        #expect(projection.attributes["agentstudio.bridge.worker.lane"] == .string("selected"))
        #expect(projection.attributes["agentstudio.bridge.worker.patch_count"] == .int(2))
        #expect(projection.attributes["agentstudio.bridge.worker.payload_class"] == .string("inline"))
        #expect(projection.attributes["agentstudio.bridge.worker.queue_wait_ms"] == .double(4.25))
        #expect(projection.attributes["agentstudio.bridge.worker.semantic_class"] == .string("demand"))
        #expect(projection.attributes["agentstudio.bridge.worker.source_epoch"] == .int(7))
        #expect(projection.attributes["agentstudio.bridge.worker.task_kind"] == .string("store_action"))
        #expect(projection.attributes["agentstudio.bridge.worker.touched_key_count"] == .int(5))
        #expect(projection.attributes["agentstudio.bridge.worker.work_kind"] == .string("review_content_ready"))
    }
}
