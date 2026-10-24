import Foundation

enum AgentStudioOTLPAttributionProjectionKeys {
    static func isAllowedValue(key: String, value: String) -> Bool? {
        switch key {
        case "agentstudio.performance.commandbar.cache_outcome":
            return ["hit", "miss"].contains(value)
        case "agentstudio.performance.commandbar.invalidation_reason":
            return [
                "scope_change", "focused_pane", "command_context", "open_generation",
                "query_meaningful_transition", "topology_observation",
            ].contains(value)
        case "agentstudio.performance.git.demand_class":
            return ["active_pane", "visible_sidebar", "open_pane", "explicit", "background"].contains(value)
        case "agentstudio.performance.git.trigger_source":
            return [
                "registration", "filesystem_change", "periodic", "visibility_change",
                "remote_reference_refresh", "retry",
            ].contains(value)
        case "agentstudio.performance.git.cadence_tier":
            return ["active_pane", "visible_sidebar", "open_pane", "background"].contains(value)
        case "agentstudio.performance.git.visibility_admission.outcome":
            return ["batched", "tier_deferred", "superseded", "admitted_uncovered"].contains(value)
        default:
            return nil
        }
    }
}
