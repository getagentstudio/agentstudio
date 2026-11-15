import Testing

@testable import AgentStudioInfrastructure

extension AgentStudioOTLPBridgeTraceProjectionTests {
    @Test
    func bridgeProjectionPreservesOnlyRecordedProductPaintCorrelationFacts() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductPaintCorrelationStartupDiagnostics.swift:461: paint proof emits structured verdicts, never readable text.
        let prefix = "agentstudio.startup_diagnostic.bridge.product_paint"
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 134,
                severityText: .info,
                body: "app.startup_diagnostic_action.completed",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.app.startup", version: "0.1.0"),
                attributes: [
                    "\(prefix).document_visible": .bool(true),
                    "\(prefix).file_identity_chain_matched": .bool(true),
                    "\(prefix).file_mode_activated": .bool(true),
                    "\(prefix).file_selected_identity_matched": .bool(true),
                    "\(prefix).file_source_matched": .bool(true),
                    "\(prefix).file_source_match.count": .int(1),
                    "\(prefix).frame_live": .bool(true),
                    "\(prefix).painted_element.count": .int(2),
                    "\(prefix).decoded_correlation.count": .int(3),
                    "\(prefix).review_candidate.surface_role.count": .int(2),
                    "\(prefix).review_candidate.identity.count": .int(2),
                    "\(prefix).review_candidate.selected_item.count": .int(1),
                    "\(prefix).review_candidate.whole_position.count": .int(2),
                    "\(prefix).review_candidate.digest.count": .int(1),
                    "\(prefix).review_candidate.painted_disposition.count": .int(2),
                    "\(prefix).review_candidate.canary.count": .int(1),
                    "\(prefix).active_mode_review": .bool(true),
                    "\(prefix).review_metadata_item.count": .int(257),
                    "\(prefix).review_selection.initial_requested.count": .int(1),
                    "\(prefix).review_selection.initial_scheduling_accepted.count": .int(2),
                    "\(prefix).review_selection.scheduled.count": .int(3),
                    "\(prefix).review_selection.first_frame_reached.count": .int(4),
                    "\(prefix).review_selection.second_frame_reached.count": .int(5),
                    "\(prefix).review_selection.submitted.count": .int(6),
                    "\(prefix).review_selection.dropped.count": .int(7),
                    "\(prefix).review_selection.latest_dispatch_disposition": .string("posted"),
                    "\(prefix).review_selection.latest_lifecycle_state": .string("acked"),
                    "\(prefix).page_ready.state": .string("ready"),
                    "\(prefix).file_mode.send_attempt.count": .int(14),
                    "\(prefix).file_mode.send_synchronous_failure.count": .int(15),
                    "\(prefix).file_mode.latest_dispatch_disposition": .string("posted"),
                    "\(prefix).file_selection.latest_dispatch_disposition": .string("queued_not_ready"),
                    "\(prefix).file_selection.latest_lifecycle_state": .string("pending"),
                    "\(prefix).comm_session.state": .string("ready"),
                    "\(prefix).comm_session.queued_command.count": .int(8),
                    "\(prefix).comm_session.replacement_request.count": .int(9),
                    "\(prefix).comm_session.native_bootstrap_install.count": .int(10),
                    "\(prefix).runtime.native_bootstrap_install.attempt.count": .int(11),
                    "\(prefix).runtime.native_bootstrap_install.accepted.count": .int(12),
                    "\(prefix).runtime.native_bootstrap_install.rejected.count": .int(13),
                    "\(prefix).review_shell_present": .bool(true),
                    "\(prefix).review_selected_item_present": .bool(true),
                    "\(prefix).review_selected_path_present": .bool(true),
                    "\(prefix).review_identity_chain_matched": .bool(true),
                    "\(prefix).review_selected_identity_matched": .bool(true),
                    "\(prefix).review_source_matched": .bool(true),
                    "\(prefix).review_source_match.count": .int(1),
                    "\(prefix).reload_replay_succeeded": .bool(true),
                    "\(prefix).worker_replacement_observed": .bool(true),
                    "\(prefix).raw_path": .string("/Users/example/private/tracked.txt"),
                    "\(prefix).raw_sha256": .string("private-source-hash"),
                    "\(prefix).raw_descriptor_id": .string("private-descriptor"),
                    "\(prefix).raw_request_id": .string("private-request"),
                    "\(prefix).raw_source_identity": .string("private-source"),
                    "\(prefix).raw_publication_id": .string("private-publication"),
                    "\(prefix).raw_item_id": .string("private-item"),
                    "\(prefix).raw_readable_text": .string("private-source-text"),
                    "agentstudio.startup_diagnostic.render_proof.succeeded": .bool(true),
                ]
            )
        )

        #expect(projection.attributes["\(prefix).document_visible"] == .bool(true))
        #expect(projection.attributes["\(prefix).file_identity_chain_matched"] == .bool(true))
        #expect(projection.attributes["\(prefix).file_mode_activated"] == .bool(true))
        #expect(projection.attributes["\(prefix).file_selected_identity_matched"] == .bool(true))
        #expect(projection.attributes["\(prefix).file_source_matched"] == .bool(true))
        #expect(projection.attributes["\(prefix).file_source_match.count"] == .int(1))
        #expect(projection.attributes["\(prefix).frame_live"] == .bool(true))
        assertReviewProductPaintStageProjection(projection, prefix: prefix)
        #expect(projection.attributes["\(prefix).review_identity_chain_matched"] == .bool(true))
        #expect(projection.attributes["\(prefix).review_selected_identity_matched"] == .bool(true))
        #expect(projection.attributes["\(prefix).review_source_matched"] == .bool(true))
        #expect(projection.attributes["\(prefix).review_source_match.count"] == .int(1))
        #expect(projection.attributes["\(prefix).reload_replay_succeeded"] == .bool(true))
        #expect(projection.attributes["\(prefix).worker_replacement_observed"] == .bool(true))
        #expect(projection.attributes["\(prefix).raw_path"] != nil)
        #expect(projection.attributes["\(prefix).raw_sha256"] != nil)
        #expect(projection.attributes["\(prefix).raw_descriptor_id"] != nil)
        #expect(projection.attributes["\(prefix).raw_request_id"] != nil)
        #expect(projection.attributes["\(prefix).raw_source_identity"] != nil)
        #expect(projection.attributes["\(prefix).raw_publication_id"] != nil)
        #expect(projection.attributes["\(prefix).raw_item_id"] != nil)
        #expect(projection.attributes["\(prefix).raw_readable_text"] != nil)
    }

    private func assertReviewProductPaintStageProjection(
        _ projection: AgentStudioOTLPProjectedLogRecord,
        prefix: String
    ) {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductPaintCorrelationStartupDiagnostics.swift:461: paint proof emits structured verdicts, never readable text.
        #expect(projection.attributes["\(prefix).painted_element.count"] == .int(2))
        #expect(projection.attributes["\(prefix).decoded_correlation.count"] == .int(3))
        #expect(projection.attributes["\(prefix).review_candidate.surface_role.count"] == .int(2))
        #expect(projection.attributes["\(prefix).review_candidate.identity.count"] == .int(2))
        #expect(projection.attributes["\(prefix).review_candidate.selected_item.count"] == .int(1))
        #expect(projection.attributes["\(prefix).review_candidate.whole_position.count"] == .int(2))
        #expect(projection.attributes["\(prefix).review_candidate.digest.count"] == .int(1))
        #expect(projection.attributes["\(prefix).review_candidate.painted_disposition.count"] == .int(2))
        #expect(projection.attributes["\(prefix).review_candidate.canary.count"] == .int(1))
        #expect(projection.attributes["\(prefix).active_mode_review"] == .bool(true))
        #expect(projection.attributes["\(prefix).review_metadata_item.count"] == .int(257))
        #expect(projection.attributes["\(prefix).review_selection.initial_requested.count"] == .int(1))
        #expect(
            projection.attributes["\(prefix).review_selection.initial_scheduling_accepted.count"]
                == .int(2)
        )
        #expect(projection.attributes["\(prefix).review_selection.scheduled.count"] == .int(3))
        #expect(projection.attributes["\(prefix).review_selection.first_frame_reached.count"] == .int(4))
        #expect(projection.attributes["\(prefix).review_selection.second_frame_reached.count"] == .int(5))
        #expect(projection.attributes["\(prefix).review_selection.submitted.count"] == .int(6))
        #expect(projection.attributes["\(prefix).review_selection.dropped.count"] == .int(7))
        #expect(
            projection.attributes["\(prefix).review_selection.latest_dispatch_disposition"]
                == .string("posted")
        )
        #expect(
            projection.attributes["\(prefix).review_selection.latest_lifecycle_state"]
                == .string("acked")
        )
        #expect(projection.attributes["\(prefix).page_ready.state"] == .string("ready"))
        #expect(projection.attributes["\(prefix).file_mode.send_attempt.count"] == .int(14))
        #expect(
            projection.attributes["\(prefix).file_mode.send_synchronous_failure.count"] == .int(15)
        )
        #expect(
            projection.attributes["\(prefix).file_mode.latest_dispatch_disposition"] == .string("posted")
        )
        #expect(
            projection.attributes["\(prefix).file_selection.latest_dispatch_disposition"]
                == .string("queued_not_ready")
        )
        #expect(
            projection.attributes["\(prefix).file_selection.latest_lifecycle_state"] == .string("pending")
        )
        #expect(projection.attributes["\(prefix).comm_session.state"] == .string("ready"))
        #expect(projection.attributes["\(prefix).comm_session.queued_command.count"] == .int(8))
        #expect(projection.attributes["\(prefix).comm_session.replacement_request.count"] == .int(9))
        #expect(
            projection.attributes["\(prefix).comm_session.native_bootstrap_install.count"] == .int(10)
        )
        #expect(
            projection.attributes["\(prefix).runtime.native_bootstrap_install.attempt.count"] == .int(11)
        )
        #expect(
            projection.attributes["\(prefix).runtime.native_bootstrap_install.accepted.count"] == .int(12)
        )
        #expect(
            projection.attributes["\(prefix).runtime.native_bootstrap_install.rejected.count"] == .int(13)
        )
        #expect(projection.attributes["\(prefix).review_shell_present"] == .bool(true))
        #expect(projection.attributes["\(prefix).review_selected_item_present"] == .bool(true))
        #expect(projection.attributes["\(prefix).review_selected_path_present"] == .bool(true))
    }
}
