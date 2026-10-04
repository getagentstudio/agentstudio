import AgentStudioCore
import Foundation

package enum SessionProviderSignalName: String, Codable, Sendable {
    case turnStart, turnDone, turnAbort, turnFailed
    case toolActivity, subagentActivity, permission, question
    case toolCompleted, toolFailed, elicitation, elicitationResult
}

package enum SessionPermissionHandling: String, Codable, Equatable, Sendable {
    case reportOnly, blockingAsk
}

/// Validated reducer inputs, retained as columns and question/option child rows.
/// Opaque provider form payloads participate in replay through their digest only.
package enum SessionProviderSignal: Codable, Equatable, Sendable {
    case turnStart, turnDone, turnAbort, subagentActivity
    case turnFailed(category: String)
    case toolActivity(toolName: String?)
    case permission(toolName: String?, questions: [SessionQuestion]?, handling: SessionPermissionHandling)
    case question(toolCallId: String, questions: [SessionQuestion])
    case toolCompleted(toolCallId: String)
    case toolFailed(toolCallId: String)
    case elicitation(id: String?, summary: String?)
    case elicitationResult(id: String?)

    package var name: SessionProviderSignalName {
        switch self {
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
        case .toolActivity(let name), .permission(let name, _, _): name
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
        case .permission(_, let questions, _): questions
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

    var permissionHandling: SessionPermissionHandling? {
        if case .permission(_, _, let handling) = self { return handling }
        return nil
    }

    func statusInput(occurrenceId: UUID) -> SessionStatusInput {
        switch self {
        case .turnStart: .userPromptSubmit
        case .turnDone: .stop
        case .turnAbort: .interrupt
        case .turnFailed(let category): .stopFailure(.init(category: category))
        case .toolActivity: .toolActivity
        case .subagentActivity: .subagentActivity
        case .permission(let name, let questions, let handling):
            .permission(toolName: name, questions: questions, handling: handling)
        case .question(let identifier, let questions): .question(toolCallId: identifier, questions: questions)
        case .toolCompleted(let identifier): .toolCompleted(toolCallId: identifier)
        case .toolFailed(let identifier): .toolFailed(toolCallId: identifier)
        case .elicitation(let identifier, let summary):
            .elicitation(id: identifier, occurrenceId: occurrenceId, summary: summary)
        case .elicitationResult(let identifier): .elicitationResult(id: identifier)
        }
    }
}
