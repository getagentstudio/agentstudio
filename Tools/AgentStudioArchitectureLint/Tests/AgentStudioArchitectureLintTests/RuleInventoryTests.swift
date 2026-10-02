import Testing

@testable import AgentStudioArchitectureLintCore

@Suite
struct RuleInventoryTests {
    @Test("registry preserves all expected rule ids and severities")
    func registryPreservesExpectedRules() {
        let actual =
            ArchitectureRuleRegistry.rules.map { ExpectedRule(id: $0.id, severity: $0.severity) }
            + ArchitectureRuleRegistry.documentRules.map { ExpectedRule(id: $0.id, severity: $0.severity) }

        #expect(actual.sorted() == ExpectedRuleInventory.rules.sorted())
    }
}

struct ExpectedRule: Comparable, Equatable {
    let id: String
    let severity: ArchitectureSeverity

    static func < (left: Self, right: Self) -> Bool {
        left.id < right.id
    }
}

enum ExpectedRuleInventory {
    static let rules: [ExpectedRule] = [
        ExpectedRule(id: "agentstudio_import_direction", severity: .error),
        ExpectedRule(id: "agentstudio_drawer_toolbar_owned_controls", severity: .error),
        ExpectedRule(id: "agentstudio_retired_worktrunk_cli", severity: .error),
        ExpectedRule(id: "agentstudio_product_atom_boundary", severity: .error),
        ExpectedRule(id: "agentstudio_canonical_atom_mutation", severity: .error),
        ExpectedRule(id: "agentstudio_shared_components_are_stateless", severity: .error),
        ExpectedRule(id: "agentstudio_atomlib_is_generic", severity: .error),
        ExpectedRule(id: "agentstudio_derived_atom_declared_inputs", severity: .error),
        ExpectedRule(id: "agentstudio_repo_cache_keyed_reads", severity: .error),
        ExpectedRule(id: "agentstudio_hot_pane_snapshot_reads", severity: .error),
        ExpectedRule(id: "agentstudio_worktree_enrichment_comparator", severity: .error),
        ExpectedRule(id: "agentstudio_state_actor_path", severity: .warning),
        ExpectedRule(id: "agentstudio_ipc_programmatic_control_boundary", severity: .error),
        ExpectedRule(id: "agentstudio_appipc_port_boundary", severity: .error),
        ExpectedRule(id: "agentstudio_ipc_composition_location", severity: .error),
        ExpectedRule(id: "agentstudio_features_do_not_import_appipc", severity: .error),
        ExpectedRule(id: "agentstudio_ipc_public_surface_sanitization", severity: .error),
        ExpectedRule(id: "agentstudio_ipc_no_direct_atom_access", severity: .error),
        ExpectedRule(id: "agentstudio_no_forbidden_architecture_marker", severity: .error),
        ExpectedRule(id: "agentstudio_no_generic_clock_sleep", severity: .error),
        ExpectedRule(id: "agentstudio_no_task_sleep_in_tests", severity: .error),
        ExpectedRule(id: "agentstudio_no_polling_wait_in_tests", severity: .error),
        ExpectedRule(id: "agentstudio_no_forbidden_test_wait", severity: .error),
        ExpectedRule(id: "agentstudio_no_adhoc_continuation_wait", severity: .error),
        ExpectedRule(id: "agentstudio_no_blocking_socket_io_in_tests", severity: .error),
        ExpectedRule(id: "agentstudio_test_blocking_wait_off_cooperative_pool", severity: .error),
        ExpectedRule(id: "agentstudio_no_expectation_off_test_task", severity: .error),
        ExpectedRule(id: "agentstudio_no_test_elapsed_time_budget", severity: .error),
        ExpectedRule(id: "agentstudio_test_core_atom_fallback_ownership", severity: .error),
        ExpectedRule(id: "agentstudio_completion_handle_not_discardable", severity: .error),
        ExpectedRule(id: "agentstudio_toolbar_tooltip_source", severity: .error),
        ExpectedRule(id: "agentstudio_eventbus_subscriber_policy_required", severity: .error),
        ExpectedRule(id: "agentstudio_terminal_local_disposition_publication", severity: .error),
        ExpectedRule(id: "agentstudio_comparison_target_query_control_production", severity: .error),
        ExpectedRule(id: "agentstudio_observation_capture_keyed_reads", severity: .error),
        ExpectedRule(id: "agentstudio_mainactor_unbounded_collection_work", severity: .error),
        ExpectedRule(id: "agentstudio_performance_constants_in_app_policies", severity: .error),
        ExpectedRule(id: "agentstudio_nonisolated_async_blocking_io_requires_concurrent", severity: .error),
        ExpectedRule(id: "agentstudio_observation_rearm_guarded", severity: .error),
        ExpectedRule(id: "agentstudio_swiftui_body_derivation", severity: .error),
        ExpectedRule(id: "agentstudio_atom_assign_only", severity: .error),
        ExpectedRule(id: "agentstudio_mainactor_hop_per_element", severity: .error),
        ExpectedRule(id: "agentstudio_probe_reports_off_main", severity: .error),
        ExpectedRule(id: "agentstudio_test_ad_hoc_gate", severity: .error),
        ExpectedRule(id: "agentstudio_test_wait_helper_returns_observation", severity: .error),
        ExpectedRule(id: "agentstudio_agent_doc_reference_resolves", severity: .error),
    ]
}
