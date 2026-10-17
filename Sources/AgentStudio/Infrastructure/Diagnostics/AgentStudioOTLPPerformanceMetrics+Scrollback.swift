/// The scrollback pass exports only aggregate cost and bounded classifications.
enum AgentStudioOTLPScrollbackTaxonomy {
    static let attributePrefix = "agentstudio.performance.scrollback.pass"
    static let stringAttributeKeys: Set<String> = [
        "\(attributePrefix).phase", "\(attributePrefix).reason",
    ]
    static let numericAttributeKeys: Set<String> = Set([
        "\(attributePrefix).pane.count",
        "\(attributePrefix).captured.bytes",
        "\(attributePrefix).written.bytes",
    ]).union(outcomeKinds.map { "\(attributePrefix).outcome.\($0).count" })

    private static let outcomeKinds = [
        "written", "invalid_utf8", "keep_previous", "unchanged", "empty",
        "deadline_exceeded", "exceeded_ceiling", "launch_failed", "read_failed",
        "exited_nonzero", "retired", "cancelled", "write_failed",
    ]

    static let counterMetricLabels: Set<String> = Set([
        "agentstudio_performance_scrollback_pass_pane_count"
    ]).union(outcomeKinds.map { "agentstudio_performance_scrollback_pass_outcome_\($0)_count" })
}

extension AgentStudioOTLPTraceProjection {
    static func isAllowedScrollbackControlledStringValue(key: String, value: String) -> Bool? {
        switch key {
        case "\(AgentStudioOTLPScrollbackTaxonomy.attributePrefix).phase": ["started", "finished"].contains(value)
        case "\(AgentStudioOTLPScrollbackTaxonomy.attributePrefix).reason": ["periodic", "quit"].contains(value)
        default: nil
        }
    }
}

extension AgentStudioOTLPPerformanceMetricEvent {
    static func appendScrollbackPassDimensions(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard record.body == "performance.scrollback.pass" else { return }
        for name in ["phase", "reason"] {
            let attributeKey = "\(AgentStudioOTLPScrollbackTaxonomy.attributePrefix).\(name)"
            guard case .string(let value) = record.attributes[attributeKey],
                AgentStudioOTLPTraceProjection.isAllowedScrollbackControlledStringValue(
                    key: attributeKey, value: value) == true
            else { continue }
            dimensions.append(AgentStudioOTLPPerformanceMetricDimension(name: name, value: value))
        }
    }

    static func isScrollbackCounterMetricLabel(_ label: String) -> Bool {
        AgentStudioOTLPScrollbackTaxonomy.counterMetricLabels.contains(label)
    }
}
