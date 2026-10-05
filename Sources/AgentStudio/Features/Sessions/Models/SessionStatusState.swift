import AgentStudioCore
import Foundation

package enum SessionBindingPhase: Sendable, Equatable {
    case bound(UUID)
    case ended(at: Date)
    case replaced(by: UUID, at: Date)
}

package enum SessionTurnPhase: Sendable, Equatable {
    case notStarted
    case working
    case done(at: Date, admittedAt: ContinuousClock.Instant)
    case interrupted(at: Date)
    case failed(SessionFailureSummary, at: Date)
}

package enum ProviderPromptKey: Sendable, Equatable, Hashable {
    case toolCall(String)
    case elicitation(String)
    case permission(Int64)
}

package struct SessionQuestion: Sendable, Codable, Equatable {
    package let question: String
    package let header: String
    package let options: [SessionQuestionOption]
    package let multiSelect: Bool
    package init(question: String, header: String, options: [SessionQuestionOption], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

package struct SessionQuestionOption: Sendable, Codable, Equatable {
    package let label: String
    package let description: String
    package init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

package struct ProviderPrompt: Sendable, Equatable {
    package let key: ProviderPromptKey
    package let reason: AskReason
    package let observedAt: Date
    package let summary: String?
    package let turnId: String?
    package let questions: [SessionQuestion]?
    package var absorbedPermission: Bool
}

package struct OpenAskSummary: Sendable, Equatable {
    package let sequence: Int64
    package let approval: Int
    package let question: Int
    package let blocked: Int
    package init(sequence: Int64, approval: Int, question: Int, blocked: Int) {
        self.sequence = sequence
        self.approval = approval
        self.question = question
        self.blocked = blocked
    }
}

package enum AgentLineWork: Sendable, Equatable {
    case monitoring
}

package struct SessionStatusState: Sendable, Equatable {
    package var binding: SessionBindingPhase
    package var turn: SessionTurnPhase = .notStarted
    package var providerPrompts: [ProviderPromptKey: ProviderPrompt] = [:]
    package var openAsks = OpenAskSummary(sequence: 0, approval: 0, question: 0, blocked: 0)
    package var lineWork: AgentLineWork?
    package var seenAfterDone = false
}

package enum SessionStatusInput: Sendable, Equatable {
    case sessionStart(generation: UUID)
    case userPromptSubmit
    case toolActivity
    case subagentActivity
    case permission(toolName: String?, questions: [SessionQuestion]?)
    case question(toolCallId: String, questions: [SessionQuestion])
    case toolCompleted(toolCallId: String)
    case toolFailed(toolCallId: String)
    case elicitation(id: String?, occurrenceId: UUID, summary: String?)
    case elicitationResult(id: String?)
    case stop
    case stopFailure(SessionFailureSummary)
    case interrupt
    case sessionEnd
    case bindingReplaced(by: UUID)
    case openAsks(OpenAskSummary)
    case agentLine(AgentLineWork?)
    case paneViewed(ContinuousClock.Instant)
}

package struct SessionStatusEvent: Sendable, Equatable {
    package let input: SessionStatusInput
    package let sequence: Int64
    package let occurredAt: Date
    package let admittedAt: ContinuousClock.Instant
    package let turnId: String?
}

/// Reduces ordered Sessions facts and the independently sequenced ask summary.
/// Nothing here reads an atom or schedules a publication.
package enum SessionStatusReducer {
    package static func apply(_ event: SessionStatusEvent, to state: inout SessionStatusState) {
        switch event.input {
        case .sessionStart(let generation):
            let asks = state.openAsks
            let lineWork = state.lineWork
            state = SessionStatusState(binding: .bound(generation))
            state.openAsks = asks
            state.lineWork = lineWork
        case .userPromptSubmit:
            state.providerPrompts.removeAll()
            state.turn = .working
        case .toolActivity, .subagentActivity:
            state.turn = .working
        case .question(let toolCallId, let questions):
            state.turn = .working
            openPrompt(.toolCall(toolCallId), reason: .question, questions: questions, event: event, state: &state)
        case .permission(let toolName, let questions):
            applyPermission(toolName: toolName, questions: questions, event: event, state: &state)
        case .toolCompleted(let toolCallId), .toolFailed(let toolCallId):
            state.providerPrompts.removeValue(forKey: .toolCall(toolCallId))
        case .elicitation(let identifier, let occurrenceId, let summary):
            openPrompt(
                .elicitation(identifier ?? occurrenceId.uuidString), reason: .question, summary: summary, event: event,
                state: &state)
        case .elicitationResult(let identifier):
            if let identifier { state.providerPrompts.removeValue(forKey: .elicitation(identifier)) }
        case .stop:
            state.providerPrompts.removeAll()
            state.turn = .done(at: event.occurredAt, admittedAt: event.admittedAt)
            state.seenAfterDone = false
        case .stopFailure(let summary):
            state.providerPrompts.removeAll()
            state.turn = .failed(summary, at: event.occurredAt)
        case .interrupt:
            state.turn = .interrupted(at: event.occurredAt)
        case .sessionEnd:
            state.providerPrompts.removeAll()
            state.binding = .ended(at: event.occurredAt)
        case .bindingReplaced(let generation):
            state.providerPrompts.removeAll()
            state.binding = .replaced(by: generation, at: event.occurredAt)
        case .openAsks(let summary):
            if summary.sequence > state.openAsks.sequence { state.openAsks = summary }
        case .agentLine(let work):
            state.lineWork = work
        case .paneViewed(let viewedAt):
            if case .done(_, let admittedAt) = state.turn, admittedAt < viewedAt,
                case .bound = state.binding
            {
                state.seenAfterDone = true
            }
        }
    }

    package static func status(of state: SessionStatusState) -> AgentSessionStatus {
        let reasons = state.providerPrompts.values.map(\.reason)
        if state.openAsks.approval > 0 || reasons.contains(.approval) { return .needsYou(.approval) }
        if state.openAsks.question > 0 || reasons.contains(.question) { return .needsYou(.question) }
        if state.openAsks.blocked > 0 || reasons.contains(.blocked) { return .needsYou(.blocked) }
        switch state.binding {
        case .ended, .replaced: return .idle(.ended)
        case .bound: break
        }
        switch state.turn {
        case .notStarted: return .unknown
        case .working: return .working(state.lineWork == .monitoring ? .monitoring : .active)
        case .done: return .idle(state.seenAfterDone ? .ready : .done)
        case .interrupted: return .idle(.interrupted)
        case .failed(let summary, _): return .failed(summary)
        }
    }
}

extension SessionStatusReducer {
    private static func applyPermission(
        toolName: String?, questions: [SessionQuestion]?, event: SessionStatusEvent,
        state: inout SessionStatusState
    ) {
        guard toolName == "AskUserQuestion" else {
            openPrompt(.permission(event.sequence), reason: .approval, event: event, state: &state)
            return
        }
        let candidates = state.providerPrompts.values.filter { prompt in
            guard case .toolCall = prompt.key else { return false }
            return prompt.turnId == event.turnId && prompt.questions == questions
                && questions != nil && !prompt.absorbedPermission
        }
        if candidates.count == 1, var matching = candidates.first {
            matching.absorbedPermission = true
            state.providerPrompts[matching.key] = matching
        } else {
            openPrompt(
                .permission(event.sequence), reason: .question, questions: questions, event: event, state: &state)
        }
    }

    private static func openPrompt(
        _ key: ProviderPromptKey, reason: AskReason, questions: [SessionQuestion]? = nil,
        summary: String? = nil, event: SessionStatusEvent, state: inout SessionStatusState
    ) {
        state.providerPrompts[key] = ProviderPrompt(
            key: key, reason: reason, observedAt: event.occurredAt, summary: summary,
            turnId: event.turnId, questions: questions, absorbedPermission: false
        )
    }
}
