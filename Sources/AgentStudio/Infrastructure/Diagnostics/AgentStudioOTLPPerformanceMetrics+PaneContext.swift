import Foundation

extension AgentStudioOTLPPerformanceMetricEvent {
    static func appendPaneContextPopoverDimensions(
        record: AgentStudioOTLPProjectedLogRecord, dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard
            ["performance.pane_context.popover", "performance.pane_context.popover.main_actor_held"].contains(
                record.body)
        else { return }
        let vocabulary: [(String, Set<String>)] = [
            (
                "stage",
                [
                    "observed", "coalesced", "deferred", "admission", "execution", "storage_read", "projection",
                    "publication", "validation_publication", "input_publication", "wake", "empty_wake",
                    "capture", "materialize", "admit", "classify", "complete", "equal", "superseded", "cancelled",
                    "retired",
                    "family_admission",
                ]
            ),
            (
                "surface",
                [
                    "sidebar_messages", "pane_messages", "card_messages", "agent_line", "management_card", "toolbar",
                    "shared", "arrangements",
                ]
            ),
            ("kind", ["none", "opening", "background", "age", "action", "page"]),
        ]
        for (name, allowed) in vocabulary {
            guard case .string(let value) = record.attributes["agentstudio.performance.pane_context.popover." + name],
                allowed.contains(value)
            else { continue }
            dimensions.append(.init(name: name, value: value))
        }
    }
}
