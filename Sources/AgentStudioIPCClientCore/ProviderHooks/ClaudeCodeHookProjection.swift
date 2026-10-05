import AgentStudioProgrammaticControl
import CryptoKit
import Foundation

/// The Claude Code hook events this package installs. Every other event Claude
/// Code emits is deliberately absent: an unprojected event is silence, never a
/// nearby lifecycle name.
package enum ClaudeCodeHookEvent: String, CaseIterable, Equatable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case elicitation = "Elicitation"
    case elicitationResult = "ElicitationResult"
    case sessionEnd = "SessionEnd"

    /// The Sessions lifecycle capability this hook event reports.
    package var projectedEventName: IPCSessionEventName {
        switch self {
        case .sessionStart: .sessionStart
        case .userPromptSubmit: .turnStart
        case .preToolUse: .toolActivity
        case .postToolUse: .toolCompleted
        case .postToolUseFailure: .toolFailed
        case .permissionRequest: .permission
        case .subagentStart, .subagentStop: .subagentActivity
        case .stop: .turnDone
        case .stopFailure: .turnFailed
        case .elicitation: .elicitation
        case .elicitationResult: .elicitationResult
        case .sessionEnd: .sessionEnd
        }
    }
}

/// The subset of one Claude Code hook's stdin document the projection reads.
/// Decoding ignores every other field, so a Claude Code release that adds
/// fields keeps working and one that removes `session_id` fails loudly.
package struct ClaudeCodeHookPayload: Decodable, Equatable, Sendable {
    package let sessionId: String
    package let hookEventName: String
    package let promptId: String?
    package let toolUseId: String?
    package let agentId: String?
    package let toolName: String?
    package let toolInput: ClaudeCodeToolInput?
    package let error: String?
    package let elicitationId: String?
    package let message: String?

    package init(
        sessionId: String,
        hookEventName: String,
        promptId: String?,
        toolUseId: String?,
        agentId: String?
    ) {
        self.sessionId = sessionId
        self.hookEventName = hookEventName
        self.promptId = promptId
        self.toolUseId = toolUseId
        self.agentId = agentId
        toolName = nil
        toolInput = nil
        error = nil
        elicitationId = nil
        message = nil
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case promptId = "prompt_id"
        case toolUseId = "tool_use_id"
        case agentId = "agent_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case error
        case elicitationId = "elicitation_id"
        case message
    }
}

/// Why one hook invocation produced no `session.event` call. Each case is a
/// silent, successful outcome for the hook process: Claude Code must never see
/// a failure because Agent Studio declined an event.
package enum ClaudeCodeHookProjectionRefusal: Equatable, Sendable {
    case unprojectedEvent(String)
    case announcedEventMismatch(announced: String, reported: String)
}

package enum ClaudeCodeHookProjectionOutcome: Equatable, Sendable {
    case projected(IPCSessionEventParams)
    case refused(ClaudeCodeHookProjectionRefusal)
}

/// Purely translates one Claude Code hook document into one `session.event` call.
/// Wire identifiers are supplied by the caller; Sessions assigns admission time.
package enum ClaudeCodeHookProjection {
    /// - Parameters:
    ///   - announcedEvent: the event name the installed hook command passed as
    ///     its argument. It must agree with the document's `hook_event_name`;
    ///     a disagreement is refused rather than resolved by preference.
    ///   - providerVersion: the Claude Code release recorded when the hooks
    ///     were installed.
    ///   - freshOccurrenceIdentifier: used only when the document carries no
    ///     `tool_use_id`, where no stable natural key exists.
    package static func project(
        announcedEvent: String,
        payload: ClaudeCodeHookPayload,
        providerVersion: String,
        correlationIdentifier: UUID,
        freshOccurrenceIdentifier: () -> UUID
    ) -> ClaudeCodeHookProjectionOutcome {
        guard payload.hookEventName == announcedEvent else {
            return .refused(
                .announcedEventMismatch(announced: announcedEvent, reported: payload.hookEventName)
            )
        }
        guard let event = ClaudeCodeHookEvent(rawValue: payload.hookEventName) else {
            return .refused(.unprojectedEvent(payload.hookEventName))
        }
        let name: IPCSessionEventName =
            event == .preToolUse && payload.toolName == "AskUserQuestion" ? .question : event.projectedEventName
        let requestIdentifier = name == .permission ? payload.toolUseId : nil
        var providerFields = IPCSessionProviderEventFields()
        providerFields.toolName = payload.toolName
        providerFields.questions = payload.toolInput?.questions
        providerFields.failureSummary = event == .stopFailure ? payload.error : nil
        providerFields.elicitationId = payload.elicitationId
        providerFields.message = payload.message
        return .projected(
            IPCSessionEventParams(
                handle: "self",
                provider: IPCSessionProviderIdentity(
                    identifier: ClaudeCodeProviderIdentity.identifier,
                    version: providerVersion,
                    mode: ClaudeCodeProviderIdentity.operatingMode
                ),
                event: IPCSessionEventIdentity(
                    name: name,
                    conversationId: payload.sessionId,
                    // `prompt_id` is Claude Code's own per-turn correlation: it
                    // is absent on SessionStart and identical across every
                    // later event of the same turn. The status turn guard uses
                    // this identity to distinguish current-turn reports.
                    turnId: payload.promptId,
                    requestId: requestIdentifier,
                    toolId: [.toolActivity, .question, .toolCompleted, .toolFailed].contains(name)
                        ? payload.toolUseId : nil,
                    subagentId: name == .subagentActivity ? payload.agentId : nil,
                    occurrenceId: ClaudeCodeHookOccurrenceIdentity.occurrenceIdentifier(
                        sessionId: payload.sessionId,
                        hookEventName: payload.hookEventName,
                        toolUseId: payload.toolUseId,
                        freshIdentifier: freshOccurrenceIdentifier
                    ),
                    providerFields: providerFields
                ),
                correlationId: correlationIdentifier
            )
        )
    }
}

package struct ClaudeCodeToolInput: Decodable, Equatable, Sendable {
    package let questions: [IPCSessionQuestion]?
}

/// Derives the occurrence identity for one projected Claude Code hook event.
///
/// A `tool_use_id` is Claude Code's own stable key for the work the event
/// describes, so the same event retried by the same session derives the same
/// wire identifier. Without one there is no natural key, so it is fresh.
/// Sessions assigns each accepted invocation a new record identity; neither
/// this wire identity nor correlation deduplicates hook facts.
package enum ClaudeCodeHookOccurrenceIdentity {
    package static func occurrenceIdentifier(
        sessionId: String,
        hookEventName: String,
        toolUseId: String?,
        freshIdentifier: () -> UUID
    ) -> UUID {
        guard let toolUseId, !toolUseId.isEmpty else { return freshIdentifier() }
        return nameBasedIdentifier(name: "claude|\(sessionId)|\(hookEventName)|\(toolUseId)")
    }

    /// Namespace for Agent Studio provider hook occurrence names. Fixed for the
    /// life of the wire contract: changing it re-identifies every event.
    private static let namespace = UUID(uuidString: "9F2F4D3C-6B1A-4F5E-8C7D-2A1B3C4D5E6F")

    /// RFC 4122 section 4.3 name-based identifier, SHA-1 variant. The digest is
    /// an identity derivation, never an integrity or authentication claim.
    private static func nameBasedIdentifier(name: String) -> UUID {
        var input = Data()
        if let namespace { withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) } }
        input.append(contentsOf: Array(name.utf8))
        var digest = Array(Insecure.SHA1.hash(data: input).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3],
                digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11],
                digest[12], digest[13], digest[14], digest[15]
            )
        )
    }
}
