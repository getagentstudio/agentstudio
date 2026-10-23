import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension ZmxBackendTests {
    @Test("the fixed resume is run by an interactive login shell before shell handoff")
    func resumeClauseUsesInteractiveLoginShell() throws {
        let invocation = ResumeInvocation(
            provider: .codex, sessionId: try ProviderSessionId(rawValue: UUIDv7.generate().uuidString))
        let plan = TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: "/unused/zmx"), zmxDirectory: URL(fileURLWithPath: "/unused/zmx-root"),
            sessionID: .generateUUIDv7(), loginShell: URL(fileURLWithPath: "/bin/zsh"),
            folderCandidates: [URL(fileURLWithPath: "/tmp/resume-proof")],
            notice: .init(linesByCandidateIndex: ["Restored after restart"]), replayFile: nil,
            resume: invocation, attemptID: .generate())
        let script = ZmxBackend.coldRestoreScript(for: plan)
        #expect(script.contains("exec '/bin/zsh' -i -l -c "))
        #expect(!script.contains("then :; else :; fi"))
    }
}
