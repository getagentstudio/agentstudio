import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation

/// The Codex hook events this package installs and projects. The raw values are
/// the exact `hook_event_name` strings Codex writes, verified against
/// `codex-rs/config/src/hook_config.rs` (`HookEventsToml`) at tag
/// `rust-v0.154.0`.
package enum CodexHookEventName: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case permissionRequest = "PermissionRequest"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    case interrupt = "Interrupt"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"

    /// The eight events the installer declares. `PostToolUse`, `PreCompact` and
    /// `PostCompact` carry no Sessions meaning, so the package never asks Codex
    /// to run a hook for them.
    package static let installedEvents: [Self] = [
        .sessionStart, .userPromptSubmit, .stop, .interrupt,
        .permissionRequest, .preToolUse, .subagentStart, .subagentStop,
        .sessionEnd,
    ]
}

/// One Codex hook payload as read from stdin.
///
/// Every field beyond `session_id` is optional here because the payload shape
/// differs per event: `SessionStart` and `SessionEnd` carry no `turn_id`,
/// `PermissionRequest` carries no `tool_use_id`, and only the subagent events
/// carry a required `agent_id`. Decoding leniently keeps one type for all
/// twelve events and lets the projection decide what each event needs.
package struct CodexHookPayload: Decodable, Equatable, Sendable {
    package let sessionId: String
    package let turnId: String?
    package let hookEventName: String?
    package let toolName: String?
    package let toolUseId: String?
    package let agentId: String?
    /// Codex 0.154.0 does not report its own version in a hook payload. The
    /// field is decoded so a later Codex that does report one is honoured
    /// without another release of this package.
    package let codexVersion: String?

    package init(
        sessionId: String,
        turnId: String? = nil,
        hookEventName: String? = nil,
        toolName: String? = nil,
        toolUseId: String? = nil,
        agentId: String? = nil,
        codexVersion: String? = nil
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.agentId = agentId
        self.codexVersion = codexVersion
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case turnId = "turn_id"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolUseId = "tool_use_id"
        case agentId = "agent_id"
        case codexVersion = "codex_version"
    }
}

/// One projected `session.event` payload, ready for the authenticated client.
package struct CodexHookProjectedEvent: Equatable, Sendable {
    package let provider: IPCSessionProviderIdentity
    package let event: IPCSessionEventIdentity

    package init(provider: IPCSessionProviderIdentity, event: IPCSessionEventIdentity) {
        self.provider = provider
        self.event = event
    }
}

/// Purely projects a Codex hook payload onto the `session.event` vocabulary.
/// Sessions assigns admission time when the projected hook is accepted.
///
/// The projection is total: an event Agent Studio does not
/// model returns `nil` rather than throwing, because a hook that fails must
/// never block the provider.
package enum CodexHookProjection {
    /// The provider identity every Codex projection carries. The default version
    /// is the release this projection was verified against, a descriptive label.
    package static let providerIdentifier = "codex"
    package static let defaultProviderVersion = "0.154.0"
    package static let providerMode = "cli"

    /// Whether this event projects at all. The hook runner asks before it reads
    /// stdin so an unprojected event costs nothing and reads nothing.
    package static func isProjected(_ eventName: CodexHookEventName) -> Bool {
        sessionEventName(for: eventName) != nil
    }

    package static func project(
        eventName: CodexHookEventName,
        payload: CodexHookPayload,
        freshOccurrenceIdentifier: () -> UUID = { UUIDv7.generate() }
    ) -> CodexHookProjectedEvent? {
        guard let name = sessionEventName(for: eventName) else { return nil }
        let providerFields = IPCSessionProviderEventFields()
        return CodexHookProjectedEvent(
            provider: IPCSessionProviderIdentity(
                identifier: providerIdentifier,
                version: payload.codexVersion ?? defaultProviderVersion,
                mode: providerMode
            ),
            event: IPCSessionEventIdentity(
                name: name,
                conversationId: payload.sessionId,
                turnId: payload.turnId,
                requestId: nil,
                toolId: toolId(eventName: eventName, payload: payload),
                subagentId: subagentId(eventName: eventName, payload: payload),
                occurrenceId: freshOccurrenceIdentifier(), providerFields: providerFields
            )
        )
    }

    private static func sessionEventName(for eventName: CodexHookEventName) -> IPCSessionEventName? {
        switch eventName {
        case .sessionStart: .sessionStart
        case .sessionEnd: .sessionEnd
        case .userPromptSubmit: .turnStart
        case .stop: .turnDone
        case .interrupt: .turnAbort
        case .permissionRequest: .permission
        case .preToolUse: .toolActivity
        case .subagentStart, .subagentStop: .subagentActivity
        case .postToolUse, .preCompact, .postCompact: nil
        }
    }

    private static func toolId(eventName: CodexHookEventName, payload: CodexHookPayload) -> String? {
        switch eventName {
        case .preToolUse: payload.toolUseId
        default: nil
        }
    }

    private static func subagentId(eventName: CodexHookEventName, payload: CodexHookPayload) -> String? {
        switch eventName {
        case .subagentStart, .subagentStop: payload.agentId
        default: nil
        }
    }
}
