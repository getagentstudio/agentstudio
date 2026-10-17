import Foundation

package enum SessionProviderSignalName: String, Codable, Sendable {
    case sessionStart, sessionEnd, turnStart, turnDone, turnAbort, turnFailed
    case toolActivity, subagentActivity, permission, question
    case toolCompleted, toolFailed, elicitation, elicitationResult
}

/// Validated reducer inputs, retained as columns and question/option child rows.
package enum SessionProviderSignal: Codable, Equatable, Sendable {
    case sessionStart, sessionEnd, turnStart, turnDone, turnAbort, subagentActivity
    case turnFailed(category: String)
    case toolActivity(toolName: String?)
    case permission(toolName: String?, questions: [SessionQuestion]?)
    case question(toolCallId: String, questions: [SessionQuestion])
    case toolCompleted(toolCallId: String)
    case toolFailed(toolCallId: String)
    case elicitation(id: String?, summary: String?)
    case elicitationResult(id: String?)

    package var name: SessionProviderSignalName {
        switch self {
        case .sessionStart: .sessionStart
        case .sessionEnd: .sessionEnd
        case .turnStart: .turnStart
        case .turnDone: .turnDone
        case .turnAbort: .turnAbort
        case .turnFailed: .turnFailed
        case .toolActivity: .toolActivity
        case .subagentActivity: .subagentActivity
        case .permission: .permission
        case .question: .question
        case .toolCompleted: .toolCompleted
        case .toolFailed: .toolFailed
        case .elicitation: .elicitation
        case .elicitationResult: .elicitationResult
        }
    }

    var toolName: String? {
        switch self {
        case .toolActivity(let name), .permission(let name, _): name
        case .question: "AskUserQuestion"
        default: nil
        }
    }
    var toolCallId: String? {
        switch self {
        case .question(let identifier, _), .toolCompleted(let identifier), .toolFailed(let identifier): identifier
        default: nil
        }
    }
    var questions: [SessionQuestion]? {
        switch self {
        case .question(_, let questions): questions
        case .permission(_, let questions): questions
        default: nil
        }
    }
    var failureSummary: String? {
        if case .turnFailed(let category) = self { return category }
        return nil
    }
    var elicitationId: String? {
        switch self {
        case .elicitation(let identifier, _), .elicitationResult(let identifier): identifier
        default: nil
        }
    }
    var summary: String? {
        if case .elicitation(_, let summary) = self { return summary }
        return nil
    }

    func statusInput(occurrenceId: UUID, bindingId: UUID) -> SessionStatusInput {
        switch self {
        case .sessionStart: .sessionStart(generation: bindingId)
        case .sessionEnd: .sessionEnd
        case .turnStart: .userPromptSubmit
        case .turnDone: .stop
        case .turnAbort: .interrupt
        case .turnFailed(let category): .stopFailure(.init(category: category))
        case .toolActivity: .toolActivity
        case .subagentActivity: .subagentActivity
        case .permission(let name, let questions):
            .permission(toolName: name, questions: questions)
        case .question(let identifier, let questions): .question(toolCallId: identifier, questions: questions)
        case .toolCompleted(let identifier): .toolCompleted(toolCallId: identifier)
        case .toolFailed(let identifier): .toolFailed(toolCallId: identifier)
        case .elicitation(let identifier, let summary):
            .elicitation(id: identifier, occurrenceId: occurrenceId, summary: summary)
        case .elicitationResult(let identifier): .elicitationResult(id: identifier)
        }
    }
}
