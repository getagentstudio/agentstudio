import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Drives real Claude Code hook documents through the projection, the real IPC
/// socket and the real Sessions database. Nothing here hand-writes a
/// `session.event` body: whatever the installed hook would send is what the app
/// admits, so a projection change that the app refuses fails here.
@MainActor
@Suite("Claude Code hook vertical", .serialized, SessionsVerticalHarnessTrait())
struct AgentStudioIPCClaudeHookVerticalTests {
    /// `Tests/AgentStudioTests/App/IPC` -> repository root -> the CLI suite's
    /// recorded Claude Code documents.
    private static func fixtureURL(_ event: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tests/AgentStudioIPCClientTests/Fixtures/claude-code-2.1/\(event).json")
    }

    private static func projectedParams(_ event: String, sessionId: String? = nil) throws -> IPCSessionEventParams {
        let recordedPayload = try JSONDecoder().decode(
            ClaudeCodeHookPayload.self, from: try Data(contentsOf: fixtureURL(event))
        )
        // Real hook invocations carry a new session ID for each session. Give
        // each suite case its own ID so deterministic tool occurrences do not
        // replay against another case's durable row in the shared database.
        let payload =
            sessionId.map {
                ClaudeCodeHookPayload(
                    sessionId: $0,
                    hookEventName: recordedPayload.hookEventName,
                    promptId: recordedPayload.promptId,
                    toolUseId: recordedPayload.toolUseId,
                    agentId: recordedPayload.agentId
                )
            } ?? recordedPayload
        let outcome = ClaudeCodeHookProjection.project(
            announcedEvent: event,
            payload: payload,
            providerVersion: ClaudeCodeProviderIdentity.supportedExactVersion,
            correlationIdentifier: UUIDv7.generate(),
            freshOccurrenceIdentifier: { UUIDv7.generate() }
        )
        guard case .projected(let params) = outcome else {
            throw ClaudeCodeHookVerticalError.notProjected(event)
        }
        return params
    }

    /// The projected call uses this case's session ID and addresses its pane.
    /// The recorded hook event, provider, turn and request fields stay intact.
    private static func addressed(_ event: String, to paneId: UUID) throws -> IPCSessionEventParams {
        let params = try projectedParams(event, sessionId: paneId.uuidString)
        return IPCSessionEventParams(
            handle: paneId.uuidString,
            provider: params.provider,
            event: params.event,
            correlationId: params.correlationId
        )
    }

    private func send(
        _ event: String,
        paneId: UUID,
        harness: SessionsVerticalHarness
    ) async throws -> IPCSessionEventResult {
        try await harness.decoded(
            method: "session.event",
            params: try JSONDecoder().decode(
                JSONValue.self, from: try JSONEncoder().encode(Self.addressed(event, to: paneId))
            ), authentication: .pane(paneId)
        )
    }

    @Test("A real Claude Code session's hooks bind the pane, raise needs-you and complete the turn")
    func claudeCodeHooksDriveTheSessionLifecycle() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let paneId = harness.boundPaneId

        // Act
        let sessionStart = try await send("SessionStart", paneId: paneId, harness: harness)
        let turnStart = try await send("UserPromptSubmit", paneId: paneId, harness: harness)
        let permission = try await send("PermissionRequest", paneId: paneId, harness: harness)
        let afterPermission = try await harness.sessionQuery(paneId: paneId)
        let turnDone = try await send("Stop", paneId: paneId, harness: harness)
        let afterStop = try await harness.sessionQuery(paneId: paneId)
        let sessionEnd = try await send("SessionEnd", paneId: paneId, harness: harness)
        let afterSessionEnd = try await harness.sessionQuery(paneId: paneId)

        // Assert
        #expect(sessionStart.disposition == .admitted)
        #expect(turnStart.disposition == .admitted)
        #expect(permission.disposition == .admitted)
        #expect(turnDone.disposition == .admitted)
        #expect(sessionEnd.disposition == .admitted)
        #expect(afterPermission.sourceHealth == .live)
        #expect(afterPermission.session?.status == .needsYou(reason: .approval))
        #expect(afterPermission.session?.providerPrompts.count == 1)
        // Stop clears provider prompts and leaves the completed turn visible.
        #expect(afterStop.session?.status == .idle(state: .done))
        #expect(afterStop.sourceHealth == .live)
        #expect(afterStop.session?.providerPrompts.isEmpty == true)
        // SessionEnd is stored as typed evidence and ends the binding through
        // the same serialized table used by every provider.
        #expect(afterSessionEnd.sourceHealth == .ended)
    }

    @Test("Another Claude Code release is recorded as a label and admitted")
    func arbitraryReleaseIsRecorded() async throws {
        // Arrange
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let projected = try Self.projectedParams("SessionStart")
        let upgraded = IPCSessionEventParams(
            handle: harness.sparePaneId.uuidString,
            provider: IPCSessionProviderIdentity(
                identifier: projected.provider.identifier,
                version: "99.0.0",
                mode: projected.provider.mode
            ),
            event: projected.event,
            correlationId: UUIDv7.generate()
        )

        // Act
        let result: IPCSessionEventResult = try await harness.decoded(
            method: "session.event",
            params: try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(upgraded)),
            authentication: .pane(harness.sparePaneId)
        )

        // Assert
        #expect(result.disposition == .admitted)
        #expect(try await harness.sessionQuery(paneId: harness.sparePaneId).sourceHealth == .live)
    }

}

private enum ClaudeCodeHookVerticalError: Error {
    case notProjected(String)
}
