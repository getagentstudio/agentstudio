import Foundation

/// Stateless presentation of the facts captured by each pane surface's owning worker.
package enum PaneContextPresentationRules {
    package static func age(referenceDate: Date, now: Date) -> AgeText {
        let elapsed = max(0, now.timeIntervalSince(referenceDate))
        let secondsPerUnit: Double = elapsed < 3600 ? 60 : (elapsed < 86_400 ? 3600 : 86_400)
        let count = Int(elapsed / secondsPerUnit)
        let text: String
        if elapsed < 60 {
            text = "Now"
        } else if elapsed < 3600 {
            text = "\(count) min ago"
        } else if elapsed < 86_400 {
            text = "\(count) hr ago"
        } else {
            text = count == 1 ? "1 day ago" : "\(count) days ago"
        }
        return AgeText(
            text: text, nextChange: referenceDate.addingTimeInterval(Double(count + 1) * secondsPerUnit))
    }

    package static func compactAge(referenceDate: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(referenceDate))
        if elapsed < 60 { return "Now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h" }
        return "\(Int(elapsed / 86_400))d"
    }

    package static func agentLineAge(referenceDate: Date, now: Date) -> String {
        "[\(age(referenceDate: referenceDate, now: now).text)]"
    }

    package static func kindChips(_ counts: PaneMessageKindCounts) -> [KindCount] {
        let kinds: [(MessageKind, Int)] = [
            (.failure, counts.failure), (.needsYou, counts.needsYou), (.done, counts.done), (.info, counts.info),
        ]
        return kinds.compactMap { kind, count in count > 0 ? KindCount(kind: kind, count: count) : nil }
    }

    package static func statusLine(
        _ presentation: PaneAgentStatusPresentation?,
        scopedPrompt: (source: PaneId, prompt: CompactProviderPrompt)? = nil
    ) -> StatusLine? {
        let prompt =
            scopedPrompt?.prompt
            ?? (presentation?.evidence == .verifiedLive ? presentation?.compactPrompt : nil)
        if let prompt {
            let reason = PaneContextLineActionSpecs.sessionStatus(.needsYou(prompt.reason)).label
            let summary = prompt.summary.flatMap { $0.isEmpty ? nil : $0 }
            return StatusLine(kind: .needsYou, text: reason + (summary.map { ": \($0)" } ?? ""))
        }
        guard let presentation else { return nil }
        switch presentation.evidence {
        case .verifiedLive, .verifiedEnded: return statusLine(for: presentation.status)
        case .unverified, .none: return nil
        }
    }

    package static func statusLine(for status: AgentSessionStatus) -> StatusLine? {
        let kind: StatusLine.Kind
        switch status {
        case .unknown: return nil
        case .working(.active): kind = .working
        case .working(.monitoring): kind = .monitoring
        case .needsYou: kind = .needsYou
        case .failed: kind = .failed
        case .idle: kind = .idle
        }
        return StatusLine(kind: kind, text: PaneContextLineActionSpecs.sessionStatus(status).label)
    }

    package static func scopedCompactPrompt(
        _ scope: [(PaneId, PaneAgentStatusPresentation?)]
    ) -> (source: PaneId, prompt: CompactProviderPrompt)? {
        var selected: (source: PaneId, prompt: CompactProviderPrompt)?
        for (source, presentation) in scope {
            guard let presentation, presentation.evidence == .verifiedLive, let prompt = presentation.compactPrompt
            else { continue }
            if selected.map({ prompt.observedAt > $0.prompt.observedAt }) ?? true {
                selected = (source, prompt)
            }
        }
        return selected
    }

    package static func cardStatusLine(
        _ presentation: PaneAgentStatusPresentation?,
        scopedPrompt: (source: PaneId, prompt: CompactProviderPrompt)? = nil
    ) -> StatusLine? {
        let prompt =
            scopedPrompt?.prompt
            ?? (presentation?.evidence == .verifiedLive ? presentation?.compactPrompt : nil)
        if let prompt { return statusLine(for: .needsYou(prompt.reason)) }
        return statusLine(presentation)
    }

    package static func activityChip(agentLine: AgentLineDetail?, activity: Date?, now: Date) -> AgeText? {
        guard agentLine == nil, let activity else { return nil }
        return AgeText(
            text: compactAge(referenceDate: activity, now: now),
            nextChange: age(referenceDate: activity, now: now).nextChange)
    }

    package static func toolbarSelection(
        counts: PaneMessageKindCounts, agentLine: AgentLineDetail?, now: Date
    ) -> ToolbarSelection {
        let chips = kindChips(counts)
        if !chips.isEmpty { return .chips(chips) }
        guard let agentLine else { return .none }
        return .agentLine(text: agentLine.summary, age: age(referenceDate: agentLine.updatedAt, now: now))
    }
}
