import AgentStudioIPCClientCore
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Testing

@testable import AgentStudio

/// These contracts read immutable provider profiles and project fixture values.
/// They construct no App, atoms, dispatcher, SQLite store or socket.
@Suite("Cursor hook projection and provider contracts")
struct AgentStudioIPCCursorHookProjectionTests {
    @Test("Turn done lands against the turn that turn start opened")
    func turnDoneCarriesTheTurnItCompletes() throws {
        // Arrange: Cursor's `generation_id` is only a turn on the turn-boundary
        // events. If it were echoed from the conversation instead, Sessions
        // would drop completion evidence that carries no turn.

        // Act
        let turnStart = try CursorHookTestDocuments.projectedParams("beforeSubmitPrompt")
        let turnDone = try CursorHookTestDocuments.projectedParams("stop")
        let tool = try CursorHookTestDocuments.projectedParams("preToolUse")

        // Assert
        #expect(turnStart.event.turnId != nil)
        #expect(turnStart.event.turnId == turnDone.event.turnId)
        // A tool event carries no turn, so it is reported without one rather
        // than under a turn identifier the provider never issued.
        #expect(tool.event.turnId == nil)
    }

    @Test("The app's provider profile and the hook's reported identity agree")
    func profileAndHookIdentityAgree() throws {
        // Arrange
        let profile = SessionsProviderProfile.cursorCommandLine

        // Act
        let projected = try CursorHookTestDocuments.projectedParams("sessionStart")

        // Assert
        #expect(profile.providerIdentifier == projected.provider.identifier)
        #expect(profile.exactVersion == projected.provider.version)
        #expect(profile.operatingMode == projected.provider.mode)
        #expect(
            Set(profile.qualifiedCapabilities.map(\.rawValue))
                == Set(CursorProviderIdentity.projectedEventNames.map(\.rawValue))
        )
        // Cursor has no permission event, so the profile must not claim one.
        #expect(!profile.qualifiedCapabilities.contains(.permission))
    }

    @Test("Cursor and Claude Code are separate provider identities")
    func cursorIsNotClaudeCode() {
        // Arrange / Act / Assert
        #expect(
            SessionsProviderProfile.cursorCommandLine.providerIdentifier
                != SessionsProviderProfile.claudeCodeCommandLine.providerIdentifier
        )
    }
}
