import Foundation

enum AgentStudioOTLPRepoExplorerTaxonomy {
    static let structuredStringAttributeKeys: Set<String> = [
        "agentstudio.startup_diagnostic.sidebar_proof.standard_trace_tags",
        "agentstudio.startup_diagnostic.sidebar_proof.diagnostic_trace_tags",
        "agentstudio.startup_diagnostic.sidebar_proof.idle_populations",
        "agentstudio.startup_diagnostic.sidebar_proof.action_populations",
    ]

    static func isAllowedValue(key: String, value: String) -> Bool? {
        if let result = isAllowedSidebarProofValue(key: key, value: value) {
            return result
        }
        return switch key {
        case "agentstudio.performance.sidebar.proof.initial_readback.repo_accessibility":
            ["ready", "unavailable"].contains(value)
        case "agentstudio.startup_diagnostic.native_table_pilot.failure_reason":
            [
                "none", "completion_timeout", "fixture_invalid", "transaction_invalid",
                "measurement_count_mismatch", "membership_p95_exceeded", "doubled_growth_exceeded",
            ].contains(value)
        case "agentstudio.startup_diagnostic.native_table_pilot.policy_id":
            value == "sidebar-native-table-pilot"
        case "agentstudio.performance.repo_explorer.native_table_pilot.failure_reason":
            [
                "none", "completion_timeout", "fixture_invalid", "transaction_invalid",
                "measurement_count_mismatch", "membership_p95_exceeded", "doubled_growth_exceeded",
            ].contains(value)
        case "agentstudio.performance.repo_explorer.native_table_pilot.outcome":
            ["completed", "passed", "failed"].contains(value)
        case "agentstudio.performance.repo_explorer.native_table_pilot.policy_id":
            value == "sidebar-native-table-pilot"
        case "agentstudio.performance.repo_explorer.native_table_pilot.scale":
            ["baseline", "doubled", "summary"].contains(value)
        case "agentstudio.performance.repo_explorer.stage":
            [
                "observe_project", "distinct", "coalesce", "admission", "execute", "validate", "publish",
                "materialize", "deadline",
                "eager_admission", "projection_worker", "command_affected_row", "command_whole_surface",
                "capture_rebuild", "affected_row", "membership_path", "whole_surface", "mainactor_apply",
                "final_projection", "atom_slot", "other",
            ].contains(value)
        case "agentstudio.performance.repo_explorer.key_class":
            [
                "ordinary_run", "rendered_repo_favorite", "rendered_worktree_fact", "relevant",
                "unrelated_tab_arrangement_pane", "observed_tab_title", "unrendered_attendance",
                "missing_declared_key", "diagnostic_settle",
            ].contains(value)
        case "agentstudio.performance.repo_explorer.outcome":
            [
                "observed", "suppressed", "coalesced", "admitted", "executed", "published", "materialized",
                "equal", "changed", "unknown", "retained", "replaced", "deferred", "rejected",
                "capacity_limited", "started", "completed", "current", "cancelled", "superseded", "stale",
                "stale_generation", "stale_origin", "stale_scope", "failed", "invalidated", "revoked",
                "scheduled", "rescheduled", "fired", "relevant_key", "reference_equal",
                "reference_different", "other",
            ].contains(value)
        case "agentstudio.performance.repo_explorer.facet":
            ["attendance", "unread"].contains(value)
        case "agentstudio.performance.repo_explorer.row_relation":
            ["owning", "unrendered", "affected_row"].contains(value)
        case "agentstudio.performance.repo_explorer.row_body_evaluation.outcome":
            ["success", "failed", "incomplete"].contains(value)
        case "agentstudio.performance.repo_explorer.row_kind":
            [
                "section_header", "loading_section_header", "loading_repo", "resolved_group_header",
                "resolved_worktree", "resolved_pane", "topology_fault",
            ].contains(value)
        case "agentstudio.performance.repo_explorer.scroll_frame_gap.outcome":
            ["sampled", "incomplete"].contains(value)
        case "agentstudio.performance.repo_explorer.surface":
            value == "repo"
        case "agentstudio.performance.repo_explorer.visible_row_count_bucket":
            ["zero", "1_8", "9_16", "17_32", "33_plus"].contains(value)
        case "agentstudio.performance.filesystem.stage":
            ["affected_key_apply", "overflow_recovery"].contains(value)
        case "agentstudio.performance.filesystem.outcome":
            ["applied", "rejected", "overflow_coarse", "overflow_scoped"].contains(value)
        case "agentstudio.performance.forge.stage":
            ["follow_up", "facts_publication"].contains(value)
        case "agentstudio.performance.forge.outcome":
            ["admitted", "deferred", "equal"].contains(value)
        case "agentstudio.performance.repository_update.stage":
            ["captured", "admitted", "settled"].contains(value)
        case "agentstudio.performance.repository_update.outcome":
            [
                "captured", "loading", "no_applicable", "complete", "partial_failure",
                "failed", "cancelled", "obsolete", "mixed_terminal", "incomplete",
            ].contains(value)
        default:
            nil
        }
    }

    private static func isAllowedSidebarProofValue(key: String, value: String) -> Bool? {
        switch key {
        case "agentstudio.startup_diagnostic.sidebar_proof.policy_id":
            value == "strict-sidebar-cpu"
        case "agentstudio.startup_diagnostic.sidebar_proof.standard_trace_tags":
            value == "performance,app.startup,terminal.startup"
        case "agentstudio.startup_diagnostic.sidebar_proof.diagnostic_trace_tags":
            value == "performance,atoms,app.startup,terminal.startup"
        case "agentstudio.startup_diagnostic.sidebar_proof.idle_populations":
            value == "zero_pty_idle"
        case "agentstudio.startup_diagnostic.sidebar_proof.action_populations":
            value == "search_clear,grouping,hide_show,tab_switch"
        case "agentstudio.performance.sidebar.proof.population":
            ["zero_pty_idle", "search_clear", "grouping", "hide_show", "tab_switch"]
                .contains(value)
        case "agentstudio.performance.sidebar.proof.workload.kind":
            ["terminal_input", "terminal_output", "ordered_command"].contains(value)
        case "agentstudio.performance.sidebar.readback.grouping_mode":
            ["repo", "pane", "tab"].contains(value)
        case "agentstudio.performance.sidebar.proof.readback.grouping_mode":
            ["repo", "pane", "tab"].contains(value)
        case "agentstudio.performance.sidebar.readback.query_state":
            ["empty", "non_empty"].contains(value)
        case "agentstudio.performance.sidebar.readback.demand_state":
            ["demanded", "hidden"].contains(value)
        case "agentstudio.performance.sidebar.readback.presentation_state",
            "agentstudio.performance.sidebar.readback.accessibility_disposition":
            ["ready", "unavailable"].contains(value)
        case "agentstudio.performance.sidebar.readback.focus_disposition":
            ["filter_focused", "not_focused"].contains(value)
        default:
            nil
        }
    }
}
