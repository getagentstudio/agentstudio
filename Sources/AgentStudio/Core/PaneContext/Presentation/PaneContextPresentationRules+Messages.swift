import Foundation

extension PaneContextPresentationRules {
    package static func messageGroup(for message: AgentMessageDetail) -> MessageGroupKind? {
        switch message.shape {
        case .ask(_, _, _, let state):
            switch state {
            case .open: return .needsYou
            case .answered, .handedBack, .dismissed, .expired, .withdrawn, .stale: return .resolved
            }
        case .notice(.dismissed): return nil
        case .notice(.withdrawn): return .resolved
        case .notice(.read) where message.importance == .attention || message.importance == .failure:
            return .resolved
        case .notice(.read), .notice(.unread):
            switch message.importance {
            case .attention, .failure: return .needsYou
            case .done: return .done
            case .info: return .info
            }
        }
    }

    package static func rowActionAvailability(_ message: AgentMessageDetail) -> RowActionAvailability {
        switch message.shape {
        case .ask(_, _, _, let state):
            switch state {
            case .open: .askForm
            case .answered, .handedBack, .dismissed, .expired, .withdrawn, .stale: .none
            }
        case .notice(.unread), .notice(.read): .noticeActions
        case .notice(.withdrawn), .notice(.dismissed): .none
        }
    }

    package static func settledLabel(_ message: AgentMessageDetail) -> String? {
        switch message.shape {
        case .notice(.withdrawn): return "Withdrawn by the agent"
        case .notice(.read) where message.importance == .attention || message.importance == .failure: return "Read"
        case .notice(.unread), .notice(.dismissed), .notice(.read): return nil
        case .ask(_, _, _, .open): return nil
        case .ask(_, let form, _, .answered(_, let value, let receipt)):
            switch receipt {
            case .notYetConfirmed: return "Answer sent, waiting for the agent"
            case .confirmed: return "Answered: \(answerSummary(value, form: form))"
            case .unconfirmed: return "Answer sent; the agent didn't confirm it"
            }
        case .ask(_, _, _, .handedBack): return "Handed back to the agent"
        case .ask(_, _, _, .dismissed): return "Dismissed"
        case .ask(_, _, _, .expired): return "Expired"
        case .ask(_, _, _, .withdrawn): return "Withdrawn by the agent"
        case .ask(_, _, _, .stale): return "No longer current"
        }
    }

    private static func answerSummary(_ value: AskAnswerValue, form: AskForm) -> String {
        switch value {
        case .decision(let decision, _):
            switch decision {
            case .approve: return "Approve"
            case .deny: return "Deny"
            }
        case .choices(let selected):
            guard case .choice(let options, _) = form else { return "" }
            return selected.compactMap { id in options.first { $0.id == id }?.label }.joined(separator: ", ")
        case .text(let text): return text.split(whereSeparator: \.isNewline).joined(separator: " ")
        case .form: return "Form submitted"
        }
    }
}
