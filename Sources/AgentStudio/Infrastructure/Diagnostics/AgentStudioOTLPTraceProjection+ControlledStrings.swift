import Foundation

extension AgentStudioOTLPPerformanceMetricEvent {
    static func isAllowedMetricDimensionValue(key: String, value: String, resource: [String: String]) -> Bool {
        guard isAllowedControlledStringValue(key: key, value: value) else { return false }
        // The projection overlays resource markers after filtering attributes. Keep
        // that resource boundary, including its 160-character limit, for metrics.
        if key == "agent.proof.marker", resource[key] == value {
            let normalizedValue = value.lowercased()
            return !value.isEmpty && value.count <= 160
                && !normalizedValue.hasPrefix("/") && !normalizedValue.contains("/users/")
                && !normalizedValue.contains("://") && !normalizedValue.contains("\\")
                && !normalizedValue.contains("\n") && !normalizedValue.contains("\r")
        }
        if AgentStudioOTLPRepoExplorerTaxonomy.structuredStringAttributeKeys.contains(key) {
            return true
        }
        // This is the existing attribute string boundary, moved out of the log
        // projection so deleting the log filter cannot widen metric dimensions.
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-" || scalar == ":"
        }
    }

    static func isAllowedControlledStringValue(key: String, value: String) -> Bool {
        if let allowedValues = BridgeTelemetryWireSchema.allowedStringValues(for: key) {
            return allowedValues.contains(value)
        }
        if let isAllowed = AgentStudioOTLPAttributionProjectionKeys.isAllowedValue(key: key, value: value) {
            return isAllowed
        }
        if let isAllowed = AgentStudioOTLPRepoExplorerTaxonomy.isAllowedValue(key: key, value: value) {
            return isAllowed
        }
        if let isAllowed = AgentStudioOTLPPaneDropTaxonomy.isAllowedValue(key: key, value: value) {
            return isAllowed
        }
        if let isAllowed = RendererLifecycleOTLPProjectionKeys.isAllowedStringValue(key: key, value: value) {
            return isAllowed
        }
        if let isAllowed = isAllowedIPCControlledStringValue(key: key, value: value) {
            return isAllowed
        }
        switch key {
        case "agentstudio.performance.sidebar.surface":
            return ["inbox", "repo", "panes"].contains(value)
        case "agentstudio.performance.sidebar.phase":
            return [
                "request_build_mainactor", "projection_worker", "mainactor_apply", "row_index", "startup_diagnostic",
                "surface_switch", "pinned_capture_mainactor", "pinned_projection_worker",
            ]
            .contains(value)
        case "agentstudio.performance.sidebar.query_state":
            return ["empty", "non_empty"].contains(value)
        case "agentstudio.performance.sidebar.group_mode":
            return ["repo", "pane", "tab", "none", "not_applicable", "activity"].contains(value)
        case "agentstudio.performance.sidebar.sort_order":
            return ["ascending", "descending"].contains(value)
        case "agentstudio.performance.sidebar.trigger":
            return [
                "grouping_switch", "surface_switch", "search", "sort_order", "collapse_toggle",
                "data_refresh", "startup_diagnostic", "pinned_navigation",
            ]
            .contains(value)
        case "agentstudio.performance.tabbar.terminal.outcome":
            return ["published", "equal", "superseded", "cancelled"].contains(value)
        case "agentstudio.performance.pane.association_outcome":
            return PaneAssociationOutcome(rawValue: value) != nil
        case "agentstudio.performance.terminal.accumulator.apply.outcome":
            return ["equal", "changed"].contains(value)
        case "agentstudio.performance.interaction.kind":
            return ["command_bar_open", "command_bar_close", "tab_move", "divider_frame", "cmd_r"]
                .contains(value)
        case "agentstudio.performance.focus.responder_change.reason":
            return AgentStudioFocusResponderChangeReason(rawValue: value) != nil
        case "agentstudio.performance.startup.source":
            return ["presented", "occluded_fallback"].contains(value)
        case "agentstudio.performance.startup.deferral.gate":
            return ["first_interactive_frame", "terminal_activation_release"].contains(value)
        case "agentstudio.performance.startup.deferral.outcome":
            return ["completed", "cancelled", "fallback_timeout"].contains(value)
        case "agentstudio.performance.repo_explorer.outline_apply_proxy.outcome":
            return ["equal", "changed"].contains(value)
        case "agentstudio.performance.tabbar.context_menu.phase":
            return ["input", "host_hit_test"].contains(value)
        case "agentstudio.performance.tabbar.context_menu.hit_view_class":
            return ["swiftui", "appkit", "none"].contains(value)
        case "agentstudio.persistence.reason":
            return [
                "topology_restore_main_role_repaired",
                "topology_restore_missing_main_degraded",
                "topology_scan_main_repaired",
                "topology_boot_normalization_flush_failed",
                "topology_normalization_rejected",
                "pane_location_restore_repaired",
                "pane_location_restore_degraded",
                "workspace_save_composition_rejected",
                "workspace_save_bridge_failed",
                "workspace_save_database_failed",
                "pane_topology_association_ambiguous",
            ]
            .contains(value)
        default:
            return true
        }
    }

    private static func isAllowedIPCControlledStringValue(key: String, value: String) -> Bool? {
        switch key {
        case "agentstudio.app.ipc.start.reason":
            return [
                "first_frame_cancelled", "first_frame_timeout", "initialization_cancelled",
                "local_store_unavailable",
                "optional_schema_unavailable", "no_active_window",
                "ipc_path_untrusted", "socket_in_use", "server_start_failed",
                "restore_bounds_unavailable",
            ]
            .contains(value)
        case "agentstudio.performance.ipc.outbox_refusal.reason":
            return [
                "malformedEnvelope", "ineligibleMethod", "ineligibleVariant", "foreignPane",
                "unknownKind", "invalidStoredRow", "qualificationRejected", "foreignStore",
            ].contains(value)
        case "agentstudio.performance.ipc.agent_authorization.outcome":
            return ["authorized", "not_yet_allowed", "refused_for_agent"].contains(value)
        default:
            return nil
        }
    }
}

extension AgentStudioOTLPTraceProjection {
    static func isAllowedControlledStringValue(key: String, value: String) -> Bool {
        AgentStudioOTLPPerformanceMetricEvent.isAllowedControlledStringValue(key: key, value: value)
    }
}
