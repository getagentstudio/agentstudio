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

/// Codex hook payloads driven through the real projection, the real socket, the
/// real admission registry and the real Sessions reduction.
///
/// The projection is the only place that decides what a Codex event means, and
/// the shipped provider profile is the only thing that lets it in. Proving them
/// apart proves nothing: a profile that omits a capability silently drops the
/// evidence, and the pane row just stays wrong.
///
/// One substitution: the harness authenticates with a diagnostic credential
/// rather than a pane token, so it addresses the pane by its canonical handle
/// where a real hook sends `self`.
@MainActor
@Suite("App IPC Codex hook vertical", .serialized, SessionsVerticalHarnessTrait(providerProfiles: .shipped))
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
        #expect(bound.state == .unknown)

        // Act — the user's prompt starts a turn.
        let turnStart = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .userPromptSubmit, paneId: harness.boundPaneId, identity: identity))

        // Assert
        #expect(turnStart.disposition == .admitted)
        let running = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(running.state == .running)
        #expect(running.origin == .reported)

        // Act — Codex asks the user to approve a tool call.
        let permissionParams = try CodexHookVerticalFixtures.params(
            event: .permissionRequest, paneId: harness.boundPaneId, identity: identity)
        let permission = try await harness.sessionEvent(params: permissionParams)

        // Assert — the derived request identity is what the query reports back.
        #expect(permission.disposition == .admitted)
        let waiting = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(waiting.state == .needsYou)
        #expect(waiting.needsYou?.requestId == permissionParams.event.requestId)

        // Act — the session ends.
        let ended = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .sessionEnd, paneId: harness.boundPaneId, identity: identity))

        // Assert — the source generation is retired, not merely recorded
        // against. `AgentStudioIPCSessionsAdapter` maps a session end to
        // `SessionsMutation.sourceEnded` using the binding's own source
        // generation, so the pane reports a source that has ended rather than
        // one that is still live with nothing arriving on it.
        #expect(ended.disposition == .admitted)
        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .ended)
    }

    /// Ending a pane that was never bound is not a caller error — there is no
    /// source generation to retire — so it is refused rather than rejected as a
    /// missing binding, and nothing is submitted.
    @Test("a session end on an unbound pane is refused without ending anything")
    func sessionEndOnUnboundPaneIsRefused() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let identity = CodexHookScenarioIdentity()

        // Act
        let refused = try await harness.sessionEvent(
            params: try CodexHookVerticalFixtures.params(
                event: .sessionEnd, paneId: harness.sparePaneId, identity: identity))

        // Assert
        #expect(refused.disposition == .unqualified)
        #expect(try await harness.sessionQuery(paneId: harness.sparePaneId).sourceHealth == .unbound)
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
        #expect(finished.state == .done)
        #expect(finished.origin == .reported)
        #expect(finished.needsYou == nil)
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

    /// The version in the profile is exact on purpose. A Codex that reported a
    /// different one would be a provider whose payload shape nobody verified.
    @Test("a Codex version the profile does not name is refused")
    func unqualifiedCodexVersionIsRefused() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let identity = CodexHookScenarioIdentity()
        let params = try CodexHookVerticalFixtures.params(
            event: .sessionStart, paneId: harness.boundPaneId, reportedVersion: "0.153.0", identity: identity)

        // Act
        let refused = try await harness.sessionEvent(params: params)

        // Assert
        #expect(refused.disposition == .unknownCapability)
        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .unbound)
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
        guard let projected = CodexHookProjection.project(eventName: event, payload: payload) else {
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
