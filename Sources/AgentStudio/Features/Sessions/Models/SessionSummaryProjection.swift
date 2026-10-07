import AgentStudioCore
import AgentStudioInfrastructure

/// Bounds only what crosses the read boundary. Reduction uses the full state.
enum SessionSummaryProjection {
    static func prompts(_ prompts: [ProviderPromptKey: ProviderPrompt]) -> [SessionProviderPromptSummary] {
        prompts.values.sorted(by: newestPromptFirst)
            .prefix(AppPolicies.Sessions.maximumListedOpenPrompts)
            .map { prompt in
                SessionProviderPromptSummary(
                    reason: prompt.reason, observedAt: prompt.observedAt,
                    summary: prompt.summary.map {
                        boundedText($0, maximumBytes: AppPolicies.Sessions.maximumPromptSummaryBytes)
                    }
                )
            }
    }

    static func status(_ status: AgentSessionStatus) -> AgentSessionStatus {
        guard case .failed(let summary) = status else { return status }
        return .failed(
            .init(
                category: boundedText(summary.category, maximumBytes: AppPolicies.Sessions.maximumFailureSummaryBytes)))
    }

    private static func newestPromptFirst(_ left: ProviderPrompt, _ right: ProviderPrompt) -> Bool {
        if left.observedAt != right.observedAt { return left.observedAt > right.observedAt }
        return stablePromptKey(left.key) < stablePromptKey(right.key)
    }

    private static func stablePromptKey(_ key: ProviderPromptKey) -> String {
        switch key {
        case .toolCall(let identifier): "tool:\(identifier)"
        case .elicitation(let identifier): "elicitation:\(identifier)"
        case .permission(let sequence): "permission:\(sequence)"
        }
    }

    private static func boundedText(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.prefix(maximumBytes + 1).count > maximumBytes else { return text }
        let ellipsis = "…"
        let contentBudget = maximumBytes - ellipsis.utf8.count
        var result = ""
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard usedBytes + scalarBytes <= contentBudget else { break }
            result.unicodeScalars.append(scalar)
            usedBytes += scalarBytes
        }
        return result + ellipsis
    }
}
