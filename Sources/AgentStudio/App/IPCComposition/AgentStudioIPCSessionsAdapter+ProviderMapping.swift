import AgentStudioAppIPC
import AgentStudioProgrammaticControl
import AgentStudioSessions

extension AgentStudioIPCSessionsAdapter {
    static func providerSignal(
        for event: IPCSessionEventIdentity
    ) throws -> SessionProviderSignal {
        guard let name = SessionProviderSignalName(rawValue: event.name.rawValue) else {
            throw AppIPCSessionsError(reason: .validationRejected)
        }
        if [.question, .toolCompleted, .toolFailed].contains(event.name), event.toolId == nil {
            throw AppIPCSessionsError(reason: .validationRejected)
        }
        if event.name == .turnFailed, event.failureSummary == nil {
            throw AppIPCSessionsError(reason: .validationRejected)
        }
        let questions = event.questions?.map { question in
            SessionQuestion(
                question: question.question, header: question.header,
                options: question.options.map {
                    SessionQuestionOption(label: $0.label, description: $0.description)
                }, multiSelect: question.multiSelect)
        }
        switch name {
        case .sessionStart: return .sessionStart
        case .sessionEnd: return .sessionEnd
        case .turnStart: return .turnStart
        case .turnDone: return .turnDone
        case .turnAbort: return .turnAbort
        case .turnFailed:
            guard let category = event.failureSummary else { throw AppIPCSessionsError(reason: .validationRejected) }
            return .turnFailed(category: category)
        case .toolActivity: return .toolActivity(toolName: event.toolName)
        case .subagentActivity: return .subagentActivity
        case .permission: return .permission(toolName: event.toolName, questions: questions)
        case .question:
            guard let identifier = event.toolId, let questions else {
                throw AppIPCSessionsError(reason: .validationRejected)
            }
            return .question(toolCallId: identifier, questions: questions)
        case .toolCompleted:
            guard let identifier = event.toolId else { throw AppIPCSessionsError(reason: .validationRejected) }
            return .toolCompleted(toolCallId: identifier)
        case .toolFailed:
            guard let identifier = event.toolId else { throw AppIPCSessionsError(reason: .validationRejected) }
            return .toolFailed(toolCallId: identifier)
        case .elicitation: return .elicitation(id: event.elicitationId, summary: event.providerFields.message)
        case .elicitationResult: return .elicitationResult(id: event.elicitationId)
        }
    }

    static func resumeHint(provider: String, conversationId: String) -> String? {
        switch provider {
        case "claude-code": "claude --resume \(conversationId)"
        case "codex": "codex resume \(conversationId)"
        default: nil
        }
    }
}
