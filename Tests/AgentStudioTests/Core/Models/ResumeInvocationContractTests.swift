import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Resume invocation contract")
struct ResumeInvocationContractTests {
    @Test("only the closed providers produce their fixed resume templates", arguments: ["claude-code", "codex"])
    func fixedProviderTemplates(providerIdentifier: String) throws {
        let identifier = UUIDv7.generate().uuidString
        let sessionId = try ProviderSessionId(rawValue: identifier)
        let provider = try #require(ResumeProvider(providerIdentifier: providerIdentifier))
        let invocation = ResumeInvocation(provider: provider, sessionId: sessionId)
        #expect(invocation.sessionId == sessionId)
        #expect(invocation.provider == provider)
        #expect(
            invocation.argv
                == (providerIdentifier == "claude-code"
                    ? ["claude", "--resume", identifier] : ["codex", "resume", identifier]))
    }

    @Test(
        "a provider session id must be one UUID, never an option or command text",
        arguments: [
            "", "--last", "latest", "uuid; touch /tmp/forbidden", "$(echo injected)", "../session", "not-a-uuid",
        ])
    func invalidSessionIdIsRejected(rawValue: String) {
        #expect(throws: (any Error).self) { try ProviderSessionId(rawValue: rawValue) }
    }

    @Test(
        "unknown providers never invent a resume command", arguments: ["claude", "shell", "future-agent", "", "CODEX"])
    func unknownProviderIsRejected(providerIdentifier: String) {
        #expect(ResumeProvider(providerIdentifier: providerIdentifier) == nil)
    }

    @Test("an older UUID session id remains usable without being replaced by a newly generated id")
    func exactExistingIdIsKept() throws {
        let text = "ad692c75-0fbb-4614-8b5d-96044dd0b3a9"
        let session = try ProviderSessionId(rawValue: text)
        let invocation = ResumeInvocation(provider: .claudeCode, sessionId: session)
        #expect(invocation.argv.last?.lowercased() == text)
    }
}
