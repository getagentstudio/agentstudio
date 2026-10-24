// Bridge numeric measurements; classification decisions are in AgentStudioOTLPMeasurementList.swift.
extension AgentStudioOTLPMeasurementList {
    static let bridgeNames: Set<String> = [
        // Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+ActiveViewerMode.swift:226; count
        "agentstudio.bridge.active_viewer.signal_accepted.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+ActiveViewerMode.swift:192; count
        "agentstudio.bridge.active_viewer.signal_rejected.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:89; count
        "agentstudio.bridge.anchor_restore.call.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:90; count
        "agentstudio.bridge.anchor_restore.direct_scroll_top_write.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:91; count
        "agentstudio.bridge.anchor_restore.synthetic_scroll.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeAnnotationCatalogTelemetryContract.swift:11; count
        "agentstudio.bridge.annotation.catalog.entry.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeAnnotationCatalogTelemetryContract.swift:13; size
        "agentstudio.bridge.annotation.catalog.unit.byte_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeAnnotationCatalogTelemetryContract.swift:14; count
        "agentstudio.bridge.annotation.catalog.window.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:4; count
        "agentstudio.bridge.batch.sample_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:11; duration
        "agentstudio.bridge.content.body_registry_commit_ms",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewComparisonTargetCatalogTraceRecorder.swift:89; size
        "agentstudio.bridge.content.byte_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:9; size
        "agentstudio.bridge.content.byte_length",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:10; size
        "agentstudio.bridge.content.byte_size_bucket",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:12; size
        "agentstudio.bridge.content.chunk_byte_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:13; count
        "agentstudio.bridge.content.chunk_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:14; size
        "agentstudio.bridge.content.estimated_bytes",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:15; duration
        "agentstudio.bridge.content.first_chunk_wait_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:16; count
        "agentstudio.bridge.content.line_count_bucket",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:18; count
        "agentstudio.bridge.content.resource_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:17; duration
        "agentstudio.bridge.content.response_wait_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:19; duration
        "agentstudio.bridge.content.stream_read_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:20; size
        "agentstudio.bridge.content.total_bytes_read",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:26; count
        "agentstudio.bridge.demand.active.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:27; count
        "agentstudio.bridge.demand.deferred.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:28; duration
        "agentstudio.bridge.demand.duration_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:29; count
        "agentstudio.bridge.demand.enqueue_accepted.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:30; count
        "agentstudio.bridge.demand.enqueue_rejected.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:31; duration
        "agentstudio.bridge.demand.executor_in_flight_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:32; duration
        "agentstudio.bridge.demand.executor_pending_wait_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:33; count
        "agentstudio.bridge.demand.failed.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:34; count
        "agentstudio.bridge.demand.foreground.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:35; count
        "agentstudio.bridge.demand.idle.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:36; count
        "agentstudio.bridge.demand.intent.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:37; count
        "agentstudio.bridge.demand.loaded.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:38; count
        "agentstudio.bridge.demand.nearby.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:40; duration
        "agentstudio.bridge.demand.scheduler_queue_wait_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:41; count
        "agentstudio.bridge.demand.speculative.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:42; count
        "agentstudio.bridge.demand.visible.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:21; count
        "agentstudio.bridge.frame_jank.dropped_frame.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:22; duration
        "agentstudio.bridge.frame_jank.dropped_frame.worst_gap_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:23; count
        "agentstudio.bridge.frame_jank.long_task.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:24; duration
        "agentstudio.bridge.frame_jank.long_task.max_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:25; duration
        "agentstudio.bridge.frame_jank.long_task.total_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:46; size
        "agentstudio.bridge.markdown.input_bytes",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:47; size
        "agentstudio.bridge.markdown.output_bytes",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:66; count
        "agentstudio.bridge.mode_gate.catch_up.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:67; count
        "agentstudio.bridge.mode_gate.suppressed.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:71; occupancy
        "agentstudio.bridge.native_capacity.coalesced_waiter.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:74; occupancy
        "agentstudio.bridge.native_capacity.deadline.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:62; occupancy
        "agentstudio.bridge.native_capacity.draining.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:107; occupancy
        "agentstudio.bridge.native_capacity.entry.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:83; occupancy
        "agentstudio.bridge.native_capacity.fairness_history.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:111; occupancy
        "agentstudio.bridge.native_capacity.in_flight.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:109; occupancy
        "agentstudio.bridge.native_capacity.lease.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:112; occupancy
        "agentstudio.bridge.native_capacity.locator.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:68; occupancy
        "agentstudio.bridge.native_capacity.logical_waiter.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:65; occupancy
        "agentstudio.bridge.native_capacity.occupied_slot.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:80; occupancy
        "agentstudio.bridge.native_capacity.pane_activity.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:110; occupancy
        "agentstudio.bridge.native_capacity.payload.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:56; occupancy
        "agentstudio.bridge.native_capacity.queued.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:116; size
        "agentstudio.bridge.native_capacity.retained_artifact_byte.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:59; occupancy
        "agentstudio.bridge.native_capacity.running.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:113; occupancy
        "agentstudio.bridge.native_capacity.tombstone.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:108; occupancy
        "agentstudio.bridge.native_capacity.waiter.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeNativeCapacityTraceRecorder.swift:77; occupancy
        "agentstudio.bridge.native_capacity.worktree.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:11; count
        "agentstudio.bridge.render_disposition.accepted_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:12; count
        "agentstudio.bridge.render_disposition.batch_receipt_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:13; count
        "agentstudio.bridge.render_disposition.duplicate_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:14; count
        "agentstudio.bridge.render_disposition.in_flight_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:15; duration
        "agentstudio.bridge.render_disposition.oldest_pending_age_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:16; count
        "agentstudio.bridge.render_disposition.pending_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:17; occupancy; occupancy, not sequence
        "agentstudio.bridge.render_disposition.pending_high_water_mark",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:18; count
        "agentstudio.bridge.render_disposition.produced_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:19; count
        "agentstudio.bridge.render_disposition.rejected_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:20; count
        "agentstudio.bridge.render_disposition.retained_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:21; occupancy
        "agentstudio.bridge.render_publication.current_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:22; occupancy
        "agentstudio.bridge.render_publication.high_water_mark",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeRenderDispositionTelemetryContract.swift:23; duration
        "agentstudio.bridge.render_publication.oldest_age_ms",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewComparisonTargetCatalogTraceRecorder.swift:81; count
        "agentstudio.bridge.review.comparison_targets.input_row.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewComparisonTargetCatalogTraceRecorder.swift:85; count
        "agentstudio.bridge.review.comparison_targets.output_row.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewComparisonTargetCatalogTraceRecorder.swift:77; duration
        "agentstudio.bridge.review.comparison_targets.reservation_age_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:70; count
        "agentstudio.bridge.review.item_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:80; count
        "agentstudio.bridge.review.metadata_carry_forward.unverified_keep.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:81; count
        "agentstudio.bridge.review.metadata_carry_forward.verified_drop.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:82; count
        "agentstudio.bridge.review.metadata_carry_forward.verified_keep.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:480; count
        "agentstudio.bridge.review.publication.emitted_events",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:478; count
        "agentstudio.bridge.review.publication.published_subscriptions",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:469; occupancy
        "agentstudio.bridge.review.publication.retained",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:482; count
        "agentstudio.bridge.review.publication.superseded",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:72; count
        "agentstudio.bridge.review.refresh.active_bank.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewRefreshLifecycleTraceRecorder.swift:63; count
        "agentstudio.bridge.review.refresh.affected_file.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewRefreshLifecycleTraceRecorder.swift:73; count
        "agentstudio.bridge.review.refresh.affected_stable_file.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:75; count
        "agentstudio.bridge.review.refresh.candidate_bank.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewRefreshLifecycleTraceRecorder.swift:68; count
        "agentstudio.bridge.review.refresh.changed_line.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewRefreshLifecycleTraceRecorder.swift:58; count
        "agentstudio.bridge.review.refresh.imported_commit.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewRefreshLifecycleTraceRecorder.swift:78; count
        "agentstudio.bridge.review.refresh.retained_publication.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeReviewRefreshLifecycleTraceRecorder.swift:83; count
        "agentstudio.bridge.review.refresh.source_lease.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:92; duration
        "agentstudio.bridge.scroll.frame_gap.max_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:93; count
        "agentstudio.bridge.scroll.frame_gap.over_16ms.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:94; count
        "agentstudio.bridge.scroll.frame_gap.over_33ms.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:95; count
        "agentstudio.bridge.scroll.frame_gap.over_50ms.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:96; duration
        "agentstudio.bridge.scroll.frame_gap.p95_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:86; duration
        "agentstudio.bridge.selected_content.click_to_paint_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:87; duration
        "agentstudio.bridge.selected_content.frame_wait_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:88; duration
        "agentstudio.bridge.selected_content.materialize_ms",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgePerformanceTraceRecorder.swift:66; count
        "agentstudio.bridge.telemetry.dropped_count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeTelemetryProofReport.swift:129; count
        "agentstudio.bridge.telemetry.native_batch_sequence_gap.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeTelemetryProofReport.swift:125; count
        "agentstudio.bridge.telemetry.optional_loss.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgePerformanceTraceRecorder.swift:69; count
        "agentstudio.bridge.telemetry.required_dropped_count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeTelemetryProofReport.swift:124; count
        "agentstudio.bridge.telemetry.required_loss.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeTelemetryProofReport.swift:126; count
        "agentstudio.bridge.telemetry.worker_sequence_gap.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:99; count
        "agentstudio.bridge.visible_descriptor.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:100; count
        "agentstudio.bridge.visible_item.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:101; count
        "agentstudio.bridge.visible_publisher.skipped.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:102; count
        "agentstudio.bridge.visible_row.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:108; duration
        "agentstudio.bridge.worker.handler_duration_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:109; count
        "agentstudio.bridge.worker.native_bootstrap_install.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:111; count
        "agentstudio.bridge.worker.patch_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:113; duration
        "agentstudio.bridge.worker.queue_wait_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:112; count
        "agentstudio.bridge.worker.queued_command.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:114; count
        "agentstudio.bridge.worker.replacement_request.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:116; count
        "agentstudio.bridge.worker.touched_key_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:103; occupancy
        "agentstudio.bridge.worktree_file.tree.current_row.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:104; count
        "agentstudio.bridge.worktree_file.tree.descriptor.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema+AttributeKeys.swift:105; count
        "agentstudio.bridge.worktree_file.tree.incoming_frame.count",
        // Sources/AgentStudio/Features/Bridge/Runtime/Telemetry/BridgeProductMetadataLifecycleTraceRecorder.swift:421; count
        "agentstudio.bridge.worktree_file.tree.window.row.count",
    ]
}
