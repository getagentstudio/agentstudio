import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation

package enum CursorHookEventName: String, CaseIterable, Sendable {
    case beforeSubmitPrompt
    case stop
    case sessionEnd
    case sessionStart
    case preToolUse
    case postToolUse
    case postToolUseFailure
    case subagentStart
    case subagentStop

    package static let installedEvents = Self.allCases
}

package struct CursorHookPayload: Decodable, Equatable, Sendable {
    package let conversationId: String
    package let generationId: String?
    package let hookEventName: String?
    package let status: String?
    package let cursorVersion: String?
    package let toolUseId: String?
    package let toolName: String?
    package let failureType: String?
    package let isInterrupt: Bool?
    package let subagentId: String?
    package let parentConversationId: String?

    private enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case generationId = "generation_id"
        case hookEventName = "hook_event_name"
        case status
        case cursorVersion = "cursor_version"
        case toolUseId = "tool_use_id"
        case toolName = "tool_name"
        case failureType = "failure_type"
        case isInterrupt = "is_interrupt"
        case subagentId = "subagent_id"
        case parentConversationId = "parent_conversation_id"
    }
}

package struct CursorHookProjectedEvent: Equatable, Sendable {
    package let provider: IPCSessionProviderIdentity
    package let event: IPCSessionEventIdentity
}

package enum CursorHookProjection {
    package static let providerIdentifier = "cursor"

    package static func project(
        eventName: CursorHookEventName, payload: CursorHookPayload,
        freshOccurrenceIdentifier: () -> UUID = { UUIDv7.generate() }
    ) -> CursorHookProjectedEvent? {
        guard !payload.conversationId.isEmpty else { return nil }
        let name: IPCSessionEventName
        var fields = IPCSessionProviderEventFields()
        var toolId: String?
        var subagentId: String?
        switch eventName {
        case .beforeSubmitPrompt: name = .turnStart
        case .sessionEnd: name = .sessionEnd
        case .sessionStart: name = .sessionStart
        case .preToolUse, .postToolUse, .postToolUseFailure:
            guard let identifier = payload.toolUseId,
                !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            toolId = identifier
            switch eventName {
            case .preToolUse:
                name = .toolActivity
                fields.toolName = payload.toolName
            case .postToolUse:
                name = .toolCompleted
                fields.toolName = payload.toolName
            default:
                name = .toolFailed
                fields.failureSummary = payload.isInterrupt == true ? "interrupted" : payload.failureType ?? "unknown"
            }
        case .subagentStart, .subagentStop:
            guard let identifier = payload.subagentId,
                !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            subagentId = identifier
            name = .subagentActivity
        case .stop:
            switch payload.status {
            case "completed": name = .turnDone
            case "aborted": name = .turnAbort
            case "error": name = .turnFailed
            default: return nil
            }
        }
        if name == .turnFailed { fields.failureSummary = "unknown" }
        return CursorHookProjectedEvent(
            provider: .init(identifier: providerIdentifier, version: payload.cursorVersion ?? "unknown", mode: "cli"),
            event: .init(
                name: name, conversationId: payload.conversationId,
                turnId: eventName == .sessionEnd || eventName == .sessionStart ? nil : payload.generationId,
                requestId: nil, toolId: toolId, subagentId: subagentId,
                occurrenceId: freshOccurrenceIdentifier(), providerFields: fields))
    }
}
