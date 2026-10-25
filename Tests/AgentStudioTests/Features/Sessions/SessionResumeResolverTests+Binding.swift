import AgentStudioCore
import Testing

@testable import AgentStudioSessions

extension SessionResumeResolverTests {
    @Test("an elected active binding resumes without a foreground observation", arguments: ["claude-code", "codex"])
    func activeBindingNeedsNoLook(provider: String) async throws {
        // Arrange: SR11 r13 uses the eligible binding, with no process observation.
        let fixture = ResumeResolverFixture(provider: provider)
        let input = try fixture.input(evidence: .noEvidence)

        // Act
        let result = await SessionsResumeResolver().resumeEvidence(for: input)

        // Assert
        #expect(
            result
                == .interruptedCandidate(
                    .init(
                        provider: provider == "codex" ? .codex : .claudeCode,
                        sessionId: try ProviderSessionId(rawValue: fixture.sessionID))))
    }
}
