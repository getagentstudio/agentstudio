import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPStartupDiagnosticProjectionTests {
    @Test
    func startupDiagnosticProjectionKeepsCommandAndRenderProofFields() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/StartupDiagnosticRenderProofs.swift:35: geometry proof emits counts/verdicts, never message text.
        let projection = OTLPProjectionAssertions.project(startupDiagnosticProjectionRecord)

        #expect(projection.body == "app.startup_diagnostic_action.blocked")
        assertStartupDiagnosticProjectionKeepsExpectedAttributes(projection)
        #expect(projection.attributes["agentstudio.startup_diagnostic.pane.id"] != nil)
    }

    @Test
    func sidebarProofFixtureProjectionKeepsEveryRecordedRootVerdict() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/StartupDiagnosticRenderProofs.swift:35: geometry proof emits counts/verdicts, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 101,
            severityText: .info,
            body: "app.startup_diagnostic.sidebar_proof.fixture_ready",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.app.startup", version: "0.1.0"),
            attributes: [
                "agentstudio.startup_diagnostic.sidebar_proof.open_source_root_present": .bool(true),
                "agentstudio.startup_diagnostic.sidebar_proof.project_dev_root_present": .bool(true),
                "agentstudio.startup_diagnostic.sidebar_proof.control_root_present": .bool(true),
                "agentstudio.startup_diagnostic.sidebar_proof.unknown_repository_count": .int(1),
                "agentstudio.startup_diagnostic.sidebar_proof.unknown_worktree_count": .int(2),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.open_source_root_present"
            ] == .bool(true)
        )
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.project_dev_root_present"
            ] == .bool(true)
        )
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.control_root_present"
            ] == .bool(true)
        )
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.unknown_repository_count"
            ] == .int(1)
        )
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.unknown_worktree_count"
            ] == .int(2)
        )
    }

    private func assertStartupDiagnosticProjectionKeepsExpectedAttributes(
        _ projection: AgentStudioOTLPProjectedLogRecord
    ) {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/StartupDiagnosticRenderProofs.swift:35: geometry proof emits counts/verdicts, never message text.
        for (key, value) in startupDiagnosticProjectionExpectedAttributes {
            #expect(projection.attributes[key] == value, "attribute \(key)")
        }
    }

    private var startupDiagnosticProjectionExpectedAttributes: [String: AgentStudioTraceValue] {
        var attributes = startupDiagnosticProjectionAttributes
        attributes.removeValue(forKey: "agentstudio.startup_diagnostic.pane.id")
        return attributes
    }

    private var startupDiagnosticProjectionRecord: AgentStudioTraceRecord {
        AgentStudioTraceRecord(
            timeUnixNano: 150,
            severityText: .info,
            body: "app.startup_diagnostic_action.blocked",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "agentstudio.trace.name": "debug-observability-marker",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.app.startup", version: "0.1.0"),
            attributes: startupDiagnosticProjectionAttributes
        )
    }

    private var startupDiagnosticProjectionAttributes: [String: AgentStudioTraceValue] {
        [
            "agentstudio.app.startup.outcome": .string("blocked"),
            "agentstudio.app.startup.phase": .string("startup_diagnostic_action"),
            "agentstudio.command.name": .string("cross-tab-move-geometry-smoke"),
            "agentstudio.command.source": .string("startup_diagnostic"),
            "agentstudio.startup_diagnostic.action": .string("cross-tab-move-geometry-smoke"),
            "agentstudio.startup_diagnostic.created_pane.count": .int(1),
            "agentstudio.startup_diagnostic.expected_visible_pane.count": .int(3),
            "agentstudio.startup_diagnostic.fixture.surface.count": .int(0),
            "agentstudio.startup_diagnostic.fixture.surface_reference.count": .int(1),
            "agentstudio.startup_diagnostic.fixture.terminal_view.count": .int(3),
            "agentstudio.startup_diagnostic.fixture.valid_geometry.count": .int(0),
            "agentstudio.startup_diagnostic.bridge.code_line.count": .int(4),
            "agentstudio.startup_diagnostic.bridge.code_line_with_data_line.count": .int(4),
            "agentstudio.startup_diagnostic.bridge.code_shadow_text.length": .int(88),
            "agentstudio.startup_diagnostic.bridge.code_text.length": .int(120),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.first_item.height_px": .int(680),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.first_item.top_px": .int(0),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.height_px": .int(720),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.item.count": .int(2),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.render_state.first_index": .int(0),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.render_state.last_index": .int(1),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.scroll_height_px": .int(1440),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.window.bottom_px": .int(720),
            "agentstudio.startup_diagnostic.bridge.code_view.instance.window.top_px": .int(0),
            "agentstudio.startup_diagnostic.bridge.code_view.rendered_item.count": .int(1),
            "agentstudio.startup_diagnostic.bridge.code_view.rendered_item.element.child.count": .int(1),
            "agentstudio.startup_diagnostic.bridge.code_view.rendered_item.element.first_child.tag": .string(
                "diffs-container"),
            "agentstudio.startup_diagnostic.bridge.code_view.rendered_item.element.height_px": .int(680),
            "agentstudio.startup_diagnostic.bridge.code_view.rendered_item.type": .string("diff"),
            "agentstudio.startup_diagnostic.bridge.code_view.rendered_item.version": .int(3),
            "agentstudio.startup_diagnostic.bridge.code_view_scroll_owner.child.count": .int(1),
            "agentstudio.startup_diagnostic.bridge.code_view_scroll_owner.first_child.tag": .string("diffs-container"),
            "agentstudio.startup_diagnostic.bridge.code_view_scroll_owner.height_px": .int(720),
            "agentstudio.startup_diagnostic.bridge.code_view_scroll_owner.scroll_height_px": .int(1440),
            "agentstudio.startup_diagnostic.bridge.code_view_panel.height_px": .int(720),
            "agentstudio.startup_diagnostic.bridge.code_view_panel.width_px": .int(1280),
            "agentstudio.startup_diagnostic.bridge.code_view.visible": .bool(false),
            "agentstudio.startup_diagnostic.bridge.diff_container.count": .int(1),
            "agentstudio.startup_diagnostic.bridge.diff_container.display": .string("block"),
            "agentstudio.startup_diagnostic.bridge.diff_container.height_px": .int(680),
            "agentstudio.startup_diagnostic.bridge.diff_container.offset_height_px": .int(680),
            "agentstudio.startup_diagnostic.bridge.diff_container.pre.count": .int(1),
            "agentstudio.startup_diagnostic.bridge.diff_container.pre.height_px": .int(600),
            "agentstudio.startup_diagnostic.bridge.diff_container.pre_text.length": .int(88),
            "agentstudio.startup_diagnostic.bridge.diff_container.scroll_height_px": .int(1440),
            "agentstudio.startup_diagnostic.bridge.diff_container.shadow_child.count": .int(3),
            "agentstudio.startup_diagnostic.bridge.diff_container.width_px": .int(1260),
            "agentstudio.startup_diagnostic.bridge.page_issue.count": .int(2),
            "agentstudio.startup_diagnostic.bridge.review_canvas.branch": .string("code"),
            "agentstudio.startup_diagnostic.bridge.review_metadata.converged": .bool(true),
            "agentstudio.startup_diagnostic.bridge.review_shell.visible": .bool(true),
            "agentstudio.startup_diagnostic.bridge.review_shell.selected_content.state": .string("failed"),
            "agentstudio.startup_diagnostic.bridge.review_shell.selected_path.visible": .bool(true),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.rendered_row.count": .int(22),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.target_row.index": .int(21),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.target_row.visible": .bool(true),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.click_attempt.count": .int(1),
            "agentstudio.startup_diagnostic.bridge.review_tree_click.selected_matches_target": .bool(true),
            "agentstudio.startup_diagnostic.bridge.modified_click.filter_requested": .bool(true),
            "agentstudio.startup_diagnostic.bridge.modified_click.click_attempt.count": .int(2),
            "agentstudio.startup_diagnostic.bridge.modified_click.target_found": .bool(true),
            "agentstudio.startup_diagnostic.bridge.modified_click.first_rendered_present": .bool(true),
            "agentstudio.startup_diagnostic.bridge.frame_liveness.raf_alive": .string("false"),
            "agentstudio.startup_diagnostic.bridge.frame_liveness.raf_fired_latency.bucket": .string(
                "not_fired"),
            "agentstudio.startup_diagnostic.bridge.modified_click.selected_matches_target": .bool(true),
            "agentstudio.startup_diagnostic.bridge.modified_click.shell_selected_matches_target": .bool(true),
            "agentstudio.startup_diagnostic.bridge.modified_click.rendered_row.count": .int(2),
            "agentstudio.startup_diagnostic.bridge.modified_click.set_filter.reason": .string("none"),
            "agentstudio.startup_diagnostic.bridge.modified_click.set_filter.status": .string("accepted"),
            "agentstudio.startup_diagnostic.bridge.modified_click.selected_content.cache_keys_present": .bool(true),
            "agentstudio.startup_diagnostic.bridge.selected_content.state": .string("ready"),
            "agentstudio.startup_diagnostic.bridge.selected_content.visible": .bool(false),
            "agentstudio.startup_diagnostic.bridge.selected_content.cache_keys_present": .bool(true),
            "agentstudio.startup_diagnostic.bridge.selected_content_cache_key.count": .int(2),
            "agentstudio.startup_diagnostic.bridge.selected_content_character.count": .int(180),
            "agentstudio.startup_diagnostic.bridge.selected_content_line.count": .int(12),
            "agentstudio.startup_diagnostic.bridge.selected_content_role.count": .int(2),
            "agentstudio.startup_diagnostic.bridge.selected_demand.deferred.count": .int(0),
            "agentstudio.startup_diagnostic.bridge.selected_demand.failed.count": .int(1),
            "agentstudio.startup_diagnostic.bridge.selected_demand.loaded.count": .int(0),
            "agentstudio.startup_diagnostic.bridge.selected_demand.load_failure.kind": .string(
                "integrity_mismatch"),
            "agentstudio.startup_diagnostic.bridge.selected_demand.result.reason": .string("descriptor_missing"),
            "agentstudio.startup_diagnostic.bridge.selected_demand.result.status": .string("failed"),
            "agentstudio.startup_diagnostic.bridge.selected_materialized.addition_line.count": .int(4),
            "agentstudio.startup_diagnostic.bridge.selected_materialized.deletion_line.count": .int(2),
            "agentstudio.startup_diagnostic.bridge.selected_materialized.file_line.count": .int(0),
            "agentstudio.startup_diagnostic.bridge.selected_materialized.item_type": .string("diff"),
            "agentstudio.startup_diagnostic.bridge.selected_materialized.item_version": .int(3),
            "agentstudio.startup_diagnostic.bridge.selected_materialized.update_result": .string("updated"),
            "agentstudio.startup_diagnostic.bridge.worker_pool.active_tasks": .int(0),
            "agentstudio.startup_diagnostic.bridge.worker_pool.busy_workers": .int(0),
            "agentstudio.startup_diagnostic.bridge.worker_pool.diff_cache_size": .int(1),
            "agentstudio.startup_diagnostic.bridge.worker_pool.file_cache_size": .int(1),
            "agentstudio.startup_diagnostic.bridge.worker_pool.init_probe.failure_reason": .string(
                "highlighter_loading_failed"),
            "agentstudio.startup_diagnostic.bridge.worker_pool.init_probe.language_count": .int(7),
            "agentstudio.startup_diagnostic.bridge.worker_pool.init_probe.stage": .string("highlighter-loaded"),
            "agentstudio.startup_diagnostic.bridge.worker_pool.init_probe.theme_count": .int(2),
            "agentstudio.startup_diagnostic.bridge.worker_pool.manager_state": .string("initialized"),
            "agentstudio.startup_diagnostic.bridge.worker_pool.queued_tasks": .int(0),
            "agentstudio.startup_diagnostic.bridge.worker_pool.state": .string("ready"),
            "agentstudio.startup_diagnostic.bridge.worker_pool.total_workers": .int(2),
            "agentstudio.startup_diagnostic.bridge.worker_pool.workers_failed": .bool(false),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.bootstrap_state": .string("started"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.initialize_request_id_state": .string("present"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.failure_count": .int(0),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.last_failure_kind": .string("none"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.last_message_type": .string("success"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.last_request_type": .string("initialize"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.last_success_matches_initialize_request": .string(
                "yes"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.last_success_id_state": .string("present"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.last_success_id_prefix": .string("req"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.last_success_request_type": .string("diff"),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.success_count": .int(2),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.initialize_success_count": .int(1),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.diff_success_count": .int(1),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.file_success_count": .int(0),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.forwarded_message_count": .int(2),
            "agentstudio.startup_diagnostic.bridge.worker_diagnostic.last_forward_result": .string("ok"),
            "agentstudio.startup_diagnostic.bridge.selected_item.visible": .bool(true),
            "agentstudio.startup_diagnostic.bridge.selected_path.visible": .bool(true),
            "agentstudio.startup_diagnostic.pane.id": .string("019ECB5A-7A66-7109-B45E-ED52BC59DA78"),
            "agentstudio.startup_diagnostic.render_proof.succeeded": .bool(false),
            "agentstudio.startup_diagnostic.skip_reason": .string("missing_bounds"),
            "agentstudio.trace.tag": .string("app.startup"),
        ]
    }

}
