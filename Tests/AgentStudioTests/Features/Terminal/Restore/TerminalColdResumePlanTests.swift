import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioTerminal

@Suite("R3 outcomes compose with the R2 restore notice")
struct TerminalColdResumePlanTests {
    @Test(arguments: ["claude-code", "codex"])
    func candidateNoticeAndInvocation(providerIdentifier: String) throws {
        let base = try resumeReadinessBasePlan(resumeReadinessDescriptor())
        let text = UUIDv7.generate().uuidString.lowercased()
        let provider = try #require(ResumeProvider(providerIdentifier: providerIdentifier))
        let invocation = ResumeInvocation(provider: provider, sessionId: try ProviderSessionId(rawValue: text))
        let plan = TerminalColdRestorePlanBuilder.applyingResumeEvidence(
            .interruptedCandidate(invocation), providerIdentifier: providerIdentifier, providerSessionId: text, to: base
        )
        let label = providerIdentifier == "codex" ? "Codex" : "Claude Code"
        #expect(plan.resume == invocation)
        #expect(
            plan.notice.linesByCandidateIndex
                == base.notice.linesByCandidateIndex.map {
                    $0 + "\nResumed \(label) session \(text.prefix(8)) after restart"
                })
        #expect(plan.folderCandidates == base.folderCandidates)
        #expect(plan.attemptID == base.attemptID)
        #expect(plan.replayFile == base.replayFile)
    }

    @Test("known exited adds no outcome line")
    func knownExitedKeepsR2NoticeUntouched() throws {
        let base = try resumeReadinessBasePlan(resumeReadinessDescriptor())
        let plan = TerminalColdRestorePlanBuilder.applyingResumeEvidence(
            .knownExited, providerIdentifier: "codex", providerSessionId: "raw-id", to: base)
        #expect(plan.notice == base.notice)
        #expect(plan.resume == nil)
    }

    @Test("raw identifiers are displayable; only printable ASCII enters the short id")
    func unknownNoticeUsesRawIdentity() throws {
        let base = try resumeReadinessBasePlan(resumeReadinessDescriptor())
        for (provider, rawId, identity) in [
            ("cursor", "\u{1b}A\u{1f}B\nCéD🎈E\tF GHI", "Cursor session ABCDEF G"),
            ("unknown-provider", "abcdefghijk", "unknown-provider session abcdefgh"),
            ("cursor", "\n\u{1b}é🎈", "Cursor"),
            ("codex", "--last", "Codex session --last"),
        ] {
            let plan = TerminalColdRestorePlanBuilder.applyingResumeEvidence(
                .unknown(.invalidSessionId), providerIdentifier: provider, providerSessionId: rawId, to: base)
            #expect(plan.resume == nil)
            #expect(
                plan.notice.linesByCandidateIndex
                    == base.notice.linesByCandidateIndex.map {
                        $0 + "\nCould not determine whether \(identity) exited; resume it manually."
                    })
        }
    }
}

extension TerminalColdResumePlanTests {
    @Test("R3 preserves nonnil replay and every R2 fallback notice prefix")
    func resumeOutcomePreservesReplayAndFallbackNotices() throws {
        let original = try resumeReadinessBasePlan(resumeReadinessDescriptor())
        let replay = URL(fileURLWithPath: "/tmp/saved-output.vt")
        let prefixes = [
            "Restored after restart",
            "Restored after restart (saved folder missing; using the repository's main folder)",
            "Restored after restart (saved and repository folders missing; using the home folder)",
        ]
        let base = TerminalColdRestorePlan(
            zmxExecutable: original.zmxExecutable, zmxDirectory: original.zmxDirectory, sessionID: original.sessionID,
            loginShell: original.loginShell,
            folderCandidates: ["/tmp/a", "/tmp/b", "/tmp/c"].map { URL(fileURLWithPath: $0) },
            notice: .init(linesByCandidateIndex: prefixes), replayFile: replay, resume: nil,
            attemptID: original.attemptID)
        let id = UUIDv7.generate().uuidString
        let invocation = ResumeInvocation(provider: .codex, sessionId: try ProviderSessionId(rawValue: id))
        let plan = TerminalColdRestorePlanBuilder.applyingResumeEvidence(
            .interruptedCandidate(invocation), providerIdentifier: "codex", providerSessionId: id, to: base)
        #expect(plan.replayFile == replay)
        #expect(plan.folderCandidates == base.folderCandidates)
        #expect(
            plan.notice.linesByCandidateIndex
                == prefixes.map { $0 + "\nResumed Codex session \(id.prefix(8)) after restart" })
    }
}
