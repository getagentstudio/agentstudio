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
@Suite("Claude Code hook vertical", .serialized, SessionsVerticalHarnessTrait(providerProfiles: .claudeCode))
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
            )
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
        #expect(afterPermission.state == .needsYou)
        #expect(afterPermission.needsYou?.requestId == "toolu_01PermissionFixture")
        // The permission is still open, so completing the turn does not clear
        // the pane's demand for the user.
        #expect(afterStop.state == .needsYou)
        #expect(afterStop.origin == .reported)
        // `SessionEnd` retires the source generation itself rather than
        // recording evidence against it, so the pane reports a source that has
        // ended rather than one that is live with nothing arriving on it. The
        // adapter decides this before the provider registry, so Claude Code and
        // Codex end a session through the same path.
        #expect(afterSessionEnd.sourceHealth == .ended)
    }

    @Test("A replayed tool-use hook is refused, not counted twice")
    func replayedToolHookIsRefused() async throws {
        // Arrange: the hook derives one occurrence identity per tool invocation
        // but mints a fresh correlation per process, so a Claude Code retry of
        // the same hook arrives as the same occurrence under a new correlation.
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let paneId = harness.boundPaneId
        _ = try await send("SessionStart", paneId: paneId, harness: harness)
        _ = try await send("UserPromptSubmit", paneId: paneId, harness: harness)
        let first = try await send("PreToolUse", paneId: paneId, harness: harness)

        // Act
        let replay = try await harness.response(
            method: "session.event",
            params: try JSONDecoder().decode(
                JSONValue.self,
                from: try JSONEncoder().encode(Self.addressed("PreToolUse", to: paneId))
            )
        )

        // Assert
        #expect(first.disposition == .admitted)
        #expect(
            replay.error?.data
                == .object([
                    "reason": .string("correlationConflict"),
                    "fieldPath": .string("$.correlationId"),
                ])
        )
        #expect(try await harness.sessionQuery(paneId: paneId).state == .running)
    }

    @Test("Another Claude Code release is refused rather than admitted as qualified")
    func unknownReleaseIsRefused() async throws {
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
            params: try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(upgraded))
        )

        // Assert
        #expect(result.disposition == .unknownCapability)
        #expect(try await harness.sessionQuery(paneId: harness.sparePaneId).sourceHealth == .unbound)
    }

    @Test("The app's provider profile and the hook's reported identity agree")
    func profileAndHookIdentityAgree() throws {
        // Arrange
        let profile = SessionsProviderProfile.claudeCodeCommandLine

        // Act
        let projected = try Self.projectedParams("SessionStart")

        // Assert
        #expect(profile.providerIdentifier == projected.provider.identifier)
        #expect(profile.exactVersion == projected.provider.version)
        #expect(profile.operatingMode == projected.provider.mode)
        #expect(
            Set(profile.qualifiedCapabilities.map(\.rawValue))
                == Set(ClaudeCodeProviderIdentity.projectedEventNames.map(\.rawValue))
        )
    }
}

private enum ClaudeCodeHookVerticalError: Error {
    case notProjected(String)
}
