import Foundation

package enum ResumeProvider: Equatable, Sendable {
    case claudeCode, codex

    package init?(providerIdentifier: String) {
        switch providerIdentifier {
        case "claude-code": self = .claudeCode
        case "codex": self = .codex
        default: return nil
        }
    }

    package var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
}

package struct ProviderSessionId: Equatable, Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) throws {
        guard UUID(uuidString: rawValue) != nil else { throw ProviderSessionIdError.invalidUUID }
        self.rawValue = rawValue
    }
}

package enum ProviderSessionIdError: Error { case invalidUUID }

// The agent-resume argv run before the fresh login shell's interactive handoff.
package struct ResumeInvocation: Equatable, Sendable {
    /// The command line the shell runs before the interactive handoff.
    package let argv: [String]
    package let provider: ResumeProvider
    package let sessionId: ProviderSessionId

    package init(provider: ResumeProvider, sessionId: ProviderSessionId) {
        self.provider = provider
        self.sessionId = sessionId
        argv =
            provider == .claudeCode
            ? ["claude", "--resume", sessionId.rawValue] : ["codex", "resume", sessionId.rawValue]
    }
}
