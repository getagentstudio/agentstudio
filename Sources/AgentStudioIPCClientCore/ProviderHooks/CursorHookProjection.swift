import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation

package enum CursorHookEventName: String, CaseIterable, Sendable {
    case beforeSubmitPrompt
    case stop
    case sessionEnd

    package static let installedEvents = Self.allCases
}

package struct CursorHookPayload: Decodable, Equatable, Sendable {
    package let conversationId: String
    package let generationId: String?
    package let hookEventName: String?
    package let status: String?
    package let cursorVersion: String?

    private enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case generationId = "generation_id"
        case hookEventName = "hook_event_name"
        case status
        case cursorVersion = "cursor_version"
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
        let name: IPCSessionEventName
        switch eventName {
        case .beforeSubmitPrompt: name = .turnStart
        case .sessionEnd: name = .sessionEnd
        case .stop:
            switch payload.status {
            case "completed": name = .turnDone
            case "aborted": name = .turnAbort
            case "error": name = .turnFailed
            default: return nil
            }
        }
        var fields = IPCSessionProviderEventFields()
        if name == .turnFailed { fields.failureSummary = "unknown" }
        return CursorHookProjectedEvent(
            provider: .init(identifier: providerIdentifier, version: payload.cursorVersion ?? "unknown", mode: "cli"),
            event: .init(
                name: name, conversationId: payload.conversationId,
                turnId: eventName == .sessionEnd ? nil : payload.generationId,
                requestId: nil, toolId: nil, subagentId: nil,
                occurrenceId: freshOccurrenceIdentifier(), providerFields: fields))
    }
}
