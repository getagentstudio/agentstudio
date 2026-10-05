import AgentStudioAppIPC
import AgentStudioProgrammaticControl
import AgentStudioSessions
import CryptoKit
import Foundation

extension AgentStudioIPCSessionsAdapter {
    private struct ProviderIntent: Encodable {
        let provider: IPCSessionProviderIdentity
        let event: IPCSessionEventIdentity
        let permissionHandling: IPCSessionPermissionHandling?
    }

    static func providerIntentFingerprint(_ params: IPCSessionEventParams) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let normalizedEvent = try IPCSessionEventIdentity.ipcSchema().decode(
            IPCSessionEventIdentity.self, from: encoder.encode(params.event)
        )
        var providerFields = normalizedEvent.providerFields
        providerFields.sourceOccurredAt = nil
        let canonicalEvent = IPCSessionEventIdentity(
            name: normalizedEvent.name, conversationId: normalizedEvent.conversationId,
            turnId: normalizedEvent.turnId, requestId: normalizedEvent.requestId, toolId: normalizedEvent.toolId,
            subagentId: normalizedEvent.subagentId, occurrenceId: normalizedEvent.occurrenceId,
            providerFields: providerFields)
        encoder.dateEncodingStrategy = .secondsSince1970
        return SHA256.hash(
            data: try encoder.encode(
                ProviderIntent(
                    provider: params.provider, event: canonicalEvent,
                    permissionHandling: params.event.name == .permission
                        ? (params.permissionHandling ?? .reportOnly) : nil))
        )
        .map { String(format: "%02x", $0) }.joined()
    }

    static func providerSignal(
        for event: IPCSessionEventIdentity, permissionHandling: IPCSessionPermissionHandling? = nil
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
        case .turnStart: return .turnStart
        case .turnDone: return .turnDone
        case .turnAbort: return .turnAbort
        case .turnFailed:
            guard let category = event.failureSummary else { throw AppIPCSessionsError(reason: .validationRejected) }
            return .turnFailed(category: category)
        case .toolActivity: return .toolActivity(toolName: event.toolName)
        case .subagentActivity: return .subagentActivity
        case .permission:
            let handling: SessionPermissionHandling =
                switch permissionHandling ?? .reportOnly {
                case .reportOnly: .reportOnly
                case .blockingAsk: .blockingAsk
                }
            return .permission(toolName: event.toolName, questions: questions, handling: handling)
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

    static func sourceEndMutation(
        paneId: UUID, sourceGenerationId: UUID, params: IPCSessionEventParams,
        admittedAt: Date, fingerprint: String
    ) -> SessionsSourceEndMutation {
        var end = SessionsSourceEndMutation(
            paneId: paneId, sourceGenerationId: sourceGenerationId, endedAt: admittedAt)
        end.occurrenceId = params.event.occurrenceId
        end.providerIntentFingerprint = fingerprint
        end.sourceOccurredAt = params.event.sourceOccurredAt
        return end
    }

    static func resumeHint(provider: String, conversationId: String) -> String? {
        switch provider {
        case "claude-code": "claude --resume \(conversationId)"
        case "codex": "codex resume \(conversationId)"
        default: nil
        }
    }
}
