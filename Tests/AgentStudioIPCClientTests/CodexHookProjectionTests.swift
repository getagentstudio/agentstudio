import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

/// The hook projection is the whole contract between Codex and Sessions: if it
/// names the wrong event, loses the turn, or derives a different identity on a
/// retry, the pane row is wrong and no later layer can tell.
@Suite("Codex hook projection")
struct CodexHookProjectionTests {
    @Test(
        "each projected Codex event maps to its session event name",
        arguments: [
            (CodexHookEventName.sessionStart, IPCSessionEventName.sessionStart),
            (.userPromptSubmit, .turnStart),
            (.stop, .turnDone),
            (.interrupt, .turnAbort),
            (.permissionRequest, .permission),
            (.preToolUse, .toolActivity),
            (.subagentStart, .subagentActivity),
            (.subagentStop, .subagentActivity),
            (.sessionEnd, .sessionEnd),
        ]
    )
    func projectedEventNames(
        eventName: CodexHookEventName, expected: IPCSessionEventName
    ) throws {
        // Arrange
        let payload = try CodexFixtures.payload(for: eventName)

        // Act
        let projected = try #require(
            CodexHookProjection.project(eventName: eventName, payload: payload))

        // Assert
        #expect(projected.event.name == expected)
        #expect(projected.event.conversationId == CodexFixtures.sessionId)
        #expect(projected.provider.identifier == "codex")
        #expect(projected.provider.version == "0.154.0")
        #expect(projected.provider.mode == "cli")
    }

    @Test("the session lifecycle events carry no turn and the turn events do")
    func turnIdentityFollowsThePayload() throws {
        // Arrange / Act
        let start = try projected(.sessionStart)
        let end = try projected(.sessionEnd)
        let turnStart = try projected(.userPromptSubmit)

        // Assert
        #expect(start.event.turnId == nil)
        #expect(end.event.turnId == nil)
        #expect(turnStart.event.turnId == CodexFixtures.turnId)
    }

    @Test("a tool event carries the Codex tool use id and a subagent event its agent id")
    func subjectIdentityFollowsThePayload() throws {
        // Arrange / Act
        let tool = try projected(.preToolUse)
        let subagentStart = try projected(.subagentStart)
        let subagentStop = try projected(.subagentStop)

        // Assert
        #expect(tool.event.toolId == "call_9f2c41ab")
        #expect(tool.event.subagentId == nil)
        #expect(subagentStart.event.subagentId == "agent_4d71")
        #expect(subagentStop.event.subagentId == "agent_4d71")
        #expect(subagentStart.event.toolId == nil)
    }

    /// Codex 0.154.0's PermissionRequest payload carries no request identifier
    /// of any kind, but Sessions refuses a permission event without one. The
    /// derived identity fills that gap and stays stable across a retry.
    @Test("a permission request carries a derived request identity and nothing else does")
    func permissionRequestCarriesADerivedRequestIdentity() throws {
        // Arrange / Act
        let permission = try projected(.permissionRequest)
        let turnStart = try projected(.userPromptSubmit)

        // Assert
        let requestId = try #require(permission.event.requestId)
        #expect(requestId == permission.event.occurrenceId.uuidString)
        #expect(turnStart.event.requestId == nil)
    }

    @Test("the same hook payload always derives the same occurrence identity")
    func occurrenceIdentityIsDeterministic() throws {
        // Arrange
        let payload = try CodexFixtures.payload(for: .preToolUse)

        // Act
        let first = try #require(
            CodexHookProjection.project(eventName: .preToolUse, payload: payload))
        let second = try #require(
            CodexHookProjection.project(eventName: .preToolUse, payload: payload))

        // Assert
        #expect(first.event.occurrenceId == second.event.occurrenceId)
        #expect(
            first.event.occurrenceId
                == DeterministicUUIDv5.providerHookIdentifier(
                    name: "codex|\(CodexFixtures.sessionId)|\(CodexFixtures.turnId)|PreToolUse|call_9f2c41ab"
                )
        )
    }

    /// Codex sends no `tool_use_id` with a permission request, so without the
    /// tool name two approvals in one turn would derive one identity and the
    /// second would be deduplicated away — the pane would show one needs-you
    /// for two questions.
    @Test("two permission requests for different tools in one turn stay distinct")
    func permissionRequestsForDifferentToolsStayDistinct() throws {
        // Arrange
        let shell = Self.permissionPayload(toolName: "shell")
        let applyPatch = Self.permissionPayload(toolName: "apply_patch")

        // Act
        let first = try #require(
            CodexHookProjection.project(
                eventName: .permissionRequest,
                payload: shell))
        let second = try #require(
            CodexHookProjection.project(
                eventName: .permissionRequest,
                payload: applyPatch))

        // Assert
        #expect(first.event.occurrenceId != second.event.occurrenceId)
        #expect(first.event.requestId != second.event.requestId)
        #expect(
            first.event.occurrenceId
                == DeterministicUUIDv5.providerHookIdentifier(
                    name:
                        "codex|\(CodexFixtures.sessionId)|\(CodexFixtures.turnId)|PermissionRequest|shell|"
                )
        )
    }

    @Test("the same permission request retried derives the same identity")
    func permissionRequestRetryKeepsItsIdentity() throws {
        // Arrange
        let payload = Self.permissionPayload(toolName: "shell")

        // Act
        let first = try #require(
            CodexHookProjection.project(
                eventName: .permissionRequest,
                payload: payload))
        let second = try #require(
            CodexHookProjection.project(
                eventName: .permissionRequest,
                payload: payload))

        // Assert
        #expect(first.event.occurrenceId == second.event.occurrenceId)
        #expect(first.event.requestId == second.event.requestId)
    }

    @Test(
        "two subagents started in one turn stay distinct",
        arguments: [CodexHookEventName.subagentStart, .subagentStop]
    )
    func subagentsInOneTurnStayDistinct(eventName: CodexHookEventName) throws {
        // Arrange
        let reviewer = Self.subagentPayload(agentId: "agent_4d71")
        let researcher = Self.subagentPayload(agentId: "agent_91ba")

        // Act
        let first = try #require(
            CodexHookProjection.project(eventName: eventName, payload: reviewer))
        let second = try #require(
            CodexHookProjection.project(eventName: eventName, payload: researcher)
        )

        // Assert
        #expect(first.event.occurrenceId != second.event.occurrenceId)
        #expect(first.event.subagentId != second.event.subagentId)
        #expect(
            first.event.occurrenceId
                == DeterministicUUIDv5.providerHookIdentifier(
                    name:
                        "codex|\(CodexFixtures.sessionId)|\(CodexFixtures.turnId)|\(eventName.rawValue)||agent_4d71"
                )
        )
    }

    /// The same subagent starting and stopping are two different occurrences.
    @Test("a subagent's start and stop derive different identities")
    func subagentStartAndStopDiffer() throws {
        // Arrange
        let payload = Self.subagentPayload(agentId: "agent_4d71")

        // Act
        let start = try #require(
            CodexHookProjection.project(
                eventName: .subagentStart,
                payload: payload))
        let stop = try #require(
            CodexHookProjection.project(
                eventName: .subagentStop, payload: payload
            ))

        // Assert
        #expect(start.event.occurrenceId != stop.event.occurrenceId)
    }

    private static func permissionPayload(toolName: String) -> CodexHookPayload {
        CodexHookPayload(
            sessionId: CodexFixtures.sessionId,
            turnId: CodexFixtures.turnId,
            hookEventName: CodexHookEventName.permissionRequest.rawValue,
            toolName: toolName
        )
    }

    private static func subagentPayload(agentId: String) -> CodexHookPayload {
        CodexHookPayload(
            sessionId: CodexFixtures.sessionId,
            turnId: CodexFixtures.turnId,
            agentId: agentId
        )
    }

    @Test("different events in the same turn derive different occurrence identities")
    func occurrenceIdentityDistinguishesEvents() throws {
        // Arrange / Act
        let turnStart = try projected(.userPromptSubmit)
        let turnDone = try projected(.stop)
        let abort = try projected(.interrupt)

        // Assert
        let identities = Set([
            turnStart.event.occurrenceId, turnDone.event.occurrenceId, abort.event.occurrenceId,
        ])
        #expect(identities.count == 3)
    }

    @Test(
        "the events Agent Studio does not model project to nothing",
        arguments: [CodexHookEventName.postToolUse, .preCompact, .postCompact]
    )
    func unmodelledEventsDoNotProject(eventName: CodexHookEventName) {
        // Arrange
        let payload = CodexHookPayload(sessionId: CodexFixtures.sessionId, turnId: CodexFixtures.turnId)

        // Act / Assert
        #expect(CodexHookProjection.isProjected(eventName) == false)
        #expect(
            CodexHookProjection.project(eventName: eventName, payload: payload)
                == nil)
    }

    @Test("a payload version overrides the verified default when a provider reports one")
    func reportedVersionWins() {
        // Arrange
        let payload = CodexHookPayload(sessionId: "s", codexVersion: "0.155.1")

        // Act
        let projected = CodexHookProjection.project(eventName: .sessionStart, payload: payload)

        // Assert
        #expect(projected?.provider.version == "0.155.1")
    }

    @Test("a name-based identity matches RFC 4122 version and variant bits")
    func derivedIdentityIsAVersionFiveUUID() {
        // Arrange / Act
        let identifier = DeterministicUUIDv5.providerHookIdentifier(name: "codex|a|b|Stop|")

        // Assert
        #expect(identifier.uuid.6 & 0xF0 == 0x50)
        #expect(identifier.uuid.8 & 0xC0 == 0x80)
    }

    private func projected(_ eventName: CodexHookEventName) throws -> CodexHookProjectedEvent {
        try #require(
            CodexHookProjection.project(
                eventName: eventName, payload: try CodexFixtures.payload(for: eventName)))
    }
}
