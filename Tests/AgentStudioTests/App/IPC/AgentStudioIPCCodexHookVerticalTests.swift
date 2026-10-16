import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Codex hooks use the real projection, pane credential, socket and SQLite owner.
@MainActor
@Suite("App IPC Codex hook vertical", .serialized, SessionsVerticalHarnessTrait())
struct AgentStudioIPCCodexHookVerticalTests {
    @Test("a Codex session start, prompt and permission request reach the query as needs-you")
    func codexHooksDriveThePaneToNeedsYou() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let identity = CodexHookScenarioIdentity()

        // Act — SessionStart binds the pane.
        let bind = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .sessionStart, paneId: harness.boundPaneId, identity: identity))

        // Assert
        #expect(bind.disposition == .admitted)
        let bound = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(bound.sourceHealth == .live)
        #expect(bound.session?.status == .unknown)

        // Act — the user's prompt starts a turn.
        let turnStart = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .userPromptSubmit, paneId: harness.boundPaneId, identity: identity))

        // Assert
        #expect(turnStart.disposition == .admitted)
        let running = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(running.session?.status == .working(state: .active))
        #expect(running.sourceHealth == .live)

        // Act — Codex asks the user to approve a tool call.
        let permissionParams = try CodexHookVerticalFixtures.params(
            event: .permissionRequest, paneId: harness.boundPaneId, identity: identity)
        let permission = try await harness.sessionEvent(params: permissionParams)

        // Assert — the qualified permission opens one approval prompt.
        #expect(permission.disposition == .admitted)
        let waiting = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(waiting.session?.status == .needsYou(reason: .approval))
        #expect(waiting.session?.providerPrompts.count == 1)

        // Act — the session ends.
        let ended = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .sessionEnd, paneId: harness.boundPaneId, identity: identity))

        // Assert — SessionEnd is a stored fact and ends its session.
        #expect(ended.disposition == .admitted)
        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .ended)
    }

    /// Rev34 records a first End by binding and immediately ending its own source.
    @Test("a first Codex session end binds and ends an unbound pane")
    func firstSessionEndBindsAndEndsPane() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let identity = CodexHookScenarioIdentity()

        // Act
        let refused = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .sessionEnd, paneId: harness.sparePaneId, identity: identity))

        // Assert
        #expect(refused.disposition == .admitted)
        #expect(try await harness.sessionQuery(paneId: harness.sparePaneId).sourceHealth == .ended)
    }

    @Test("a Codex turn that finishes without a permission request reaches the query as done")
    func codexStopReachesTheQueryAsDone() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let identity = CodexHookScenarioIdentity()
        _ = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .sessionStart, paneId: harness.boundPaneId, identity: identity))
        _ = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .userPromptSubmit, paneId: harness.boundPaneId, identity: identity))

        // Act
        let stop = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .stop, paneId: harness.boundPaneId, identity: identity))

        // Assert
        #expect(stop.disposition == .admitted)
        let finished = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(finished.session?.status == .idle(state: .done))
        #expect(finished.sourceHealth == .live)
        #expect(finished.session?.providerPrompts.isEmpty == true)
    }

    @Test("a tool event and a subagent event are admitted against the shipped profile")
    func codexToolAndSubagentEventsAreAdmitted() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let identity = CodexHookScenarioIdentity()
        _ = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .sessionStart, paneId: harness.boundPaneId, identity: identity))

        // Act
        let tool = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .preToolUse, paneId: harness.boundPaneId, identity: identity))
        let subagent = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .subagentStart, paneId: harness.boundPaneId, identity: identity))

        // Assert
        #expect(tool.disposition == .admitted)
        #expect(subagent.disposition == .admitted)
    }

    @Test("a Codex version label does not gate a pane-authenticated session start")
    func arbitraryCodexVersionIsAdmitted() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let identity = CodexHookScenarioIdentity()
        let params = try CodexHookVerticalFixtures.params(
            event: .sessionStart, paneId: harness.boundPaneId, reportedVersion: "0.153.0", identity: identity)

        // Act
        let admitted = try await harness.sessionEvent(params: params)

        // Assert
        #expect(admitted.disposition == .admitted)
        let query = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(query.sourceHealth == .live)
        #expect(query.session?.conversationId == params.event.conversationId)
    }
}

/// Builds `session.event` parameters the way the shipped Codex hook does:
/// payload in, `CodexHookProjection` deciding everything, pane handle swapped in.
enum CodexHookVerticalFixtures {
    enum FixtureError: Error {
        case notProjected(CodexHookEventName)
    }

    static func params(
        event: CodexHookEventName,
        paneId: UUID,
        reportedVersion: String? = nil,
        identity: CodexHookScenarioIdentity
    ) throws -> IPCSessionEventParams {
        let payload = CodexHookPayload(
            sessionId: identity.sessionId,
            turnId: turnId(for: event, identity: identity),
            hookEventName: event.rawValue,
            toolName: event == .preToolUse || event == .permissionRequest ? "shell" : nil,
            toolUseId: event == .preToolUse ? "call_9f2c41ab" : nil,
            agentId: event == .subagentStart || event == .subagentStop ? "agent_4d71" : nil,
            codexVersion: reportedVersion
        )
        guard
            let projected = CodexHookProjection.project(eventName: event, payload: payload)
        else {
            throw FixtureError.notProjected(event)
        }
        return IPCSessionEventParams(
            handle: paneId.uuidString,
            provider: projected.provider,
            event: projected.event,
            correlationId: UUIDv7.generate()
        )
    }

    /// Codex sends no `turn_id` with the session lifecycle events.
    private static func turnId(for event: CodexHookEventName, identity: CodexHookScenarioIdentity) -> String? {
        switch event {
        case .sessionStart, .sessionEnd: nil
        default: identity.turnId
        }
    }
}

struct CodexHookScenarioIdentity {
    let sessionId = UUIDv7.generate().uuidString
    let turnId = UUIDv7.generate().uuidString
}
