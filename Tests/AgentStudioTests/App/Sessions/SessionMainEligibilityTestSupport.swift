import AgentStudioCore
import AgentStudioSessions
import Foundation

enum TestMainAgentChain {
    static let shell = ZmxProcessIncarnation(pid: 58, startSeconds: 1, startMicroseconds: 0)
    static let observation = ProcessChainObservation.agentShell(shell: shell, shellParent: .other)
}

struct MatchingTestPaneTerminalLeaderReader: PaneTerminalLeaderReading {
    let sessionID = ZmxSessionID.generateUUIDv7()

    func terminalSessionID(for paneId: UUID) async -> ZmxSessionID? { sessionID }
    func terminalLeader(for sessionID: ZmxSessionID) async -> ZmxProcessIncarnation? {
        sessionID == self.sessionID ? TestMainAgentChain.shell : nil
    }
}

struct EligibleTestProcessChainReader: ProcessChainReading {
    func observe(peer: ProcessChainPeer?, provider: String) -> ProcessChainObservation {
        TestMainAgentChain.observation
    }
}
