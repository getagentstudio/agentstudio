import AgentStudioCore
import Testing

@testable import AgentStudioSessions

@Suite("SR11/SR12 revision 13 cold verdicts")
struct SessionResumeResolverTests {
    @Test(
        "report vetoes precede missing main and provider/id validation",
        arguments: ResumeEvidenceCase.allCases.filter { $0 != .noEvidence })
    func reportVetoPrecedence(evidence: ResumeEvidenceCase) async throws {
        let fixture = ResumeResolverFixture(provider: "cursor")
        let expected: ResumeEvidence
        switch evidence {
        case .end: expected = .knownExited
        case .otherEnd, .otherStart: expected = .unknown(.changedWhileClosed)
        case .historyLost: expected = .unknown(.historyLost)
        case .refused: expected = .unknown(.reportRefused)
        case .noEvidence:
            Issue.record("not a report row")
            return
        }
        let input = try fixture.input(mainExists: false, validID: false, evidence: evidence)
        #expect(await SessionsResumeResolver().resumeEvidence(for: input) == expected)
    }

    @Test("same boot requires complete inventory proving absence or refusal", arguments: ResumeDeathCase.allCases)
    func sameBootInventory(death: ResumeDeathCase) async throws {
        let fixture = ResumeResolverFixture(provider: "codex")
        let result = await SessionsResumeResolver().resumeEvidence(for: try fixture.input(sameBoot: true, death: death))
        switch death {
        case .absent, .refused:
            #expect(
                result
                    == .interruptedCandidate(
                        .init(provider: .codex, sessionId: try ProviderSessionId(rawValue: fixture.sessionID))))
        case .alive, .unresponsive, .unavailable:
            #expect(result == .unknown(.observationMismatch))
        }
    }

    @Test("different boot does not consult inventory", arguments: ResumeDeathCase.allCases)
    func differentBootIgnoresInventory(death: ResumeDeathCase) async throws {
        let fixture = ResumeResolverFixture(provider: "claude-code")
        let input = try fixture.input(sameBoot: false, death: death)
        #expect(
            await SessionsResumeResolver().resumeEvidence(for: input)
                == .interruptedCandidate(
                    .init(provider: .claudeCode, sessionId: try ProviderSessionId(rawValue: fixture.sessionID))))
    }

    @Test("no cold-ended main is known exited even for an unknown provider")
    func noMainKnownExited() async throws {
        let fixture = ResumeResolverFixture(provider: "cursor")
        #expect(
            await SessionsResumeResolver().resumeEvidence(
                for: try fixture.input(mainExists: false, validID: false)) == .knownExited)
    }

    @Test("unsupported providers and invalid UUIDs retain exact reasons")
    func providerAndIDValidation() async throws {
        for provider in ["cursor", "unrecognized-provider"] {
            let fixture = ResumeResolverFixture(provider: provider)
            #expect(
                await SessionsResumeResolver().resumeEvidence(
                    for: try fixture.input(validID: false)) == .unknown(.unknownProvider))
        }
        let fixture = ResumeResolverFixture(provider: "codex")
        #expect(
            await SessionsResumeResolver().resumeEvidence(
                for: try fixture.input(validID: false)) == .unknown(.invalidSessionId))
        #expect(
            await SessionsResumeResolver().resumeEvidence(
                for: try fixture.input(validID: false, sameBoot: true, death: .alive)) == .unknown(.observationMismatch)
        )
    }
}
