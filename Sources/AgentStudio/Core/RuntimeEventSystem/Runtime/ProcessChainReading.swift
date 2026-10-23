import AgentStudioInfrastructure
import Foundation

/// Accept-time peer identity translated by App, without an IPC dependency in Core.
package struct ProcessChainPeer: Equatable, Sendable {
    package let pid: Int32
    package let pidVersion: UInt32

    package init(pid: Int32, pidVersion: UInt32) {
        self.pid = pid
        self.pidVersion = pidVersion
    }
}

package enum ChainUnknownReason: Error, Equatable, Sendable {
    case peerUnbound
    case processUnavailable
    case incarnationChanged
    case startOrder
    case readLimit
    case unrecognizedChain
    case unsupportedProvider
}

package enum ProcessChainObservation: Equatable, Sendable {
    package enum MultiplexerServer: Equatable, Sendable { case tmux, herdr }
    package enum ShellParent: Equatable, Sendable {
        case multiplexerServer(MultiplexerServer)
        case other
    }

    case agentShell(shell: ZmxProcessIncarnation, shellParent: ShellParent)
    case unknown(ChainUnknownReason)

    package func isMainEligible(terminalLeader: ZmxProcessIncarnation?) -> Bool {
        switch self {
        case .agentShell(_, .multiplexerServer): true
        case .agentShell(let shell, .other): shell == terminalLeader
        case .unknown: false
        }
    }
}

package protocol ProcessChainReading: Sendable {
    func observe(peer: ProcessChainPeer?, provider: String) -> ProcessChainObservation
}

package struct ProcessChainProcessFacts: Equatable, Sendable {
    package let incarnation: ZmxProcessIncarnation
    package let parentPID: Int32
    /// Basename of invoked argv[0], as measured by the probe's `ps -o comm`.
    /// Version-named and argv0-rewriting launchers require it; unreadable arguments use the kernel name.
    package let executableName: String

    package init(incarnation: ZmxProcessIncarnation, parentPID: Int32, executableName: String) {
        self.incarnation = incarnation
        self.parentPID = parentPID
        self.executableName = executableName
    }
}

package protocol ProcessChainFactsReading: Sendable {
    func pidVersion(of pid: Int32) -> UInt32?
    func bsdInfo(of pid: Int32) -> ProcessChainProcessFacts?
}

/// Synchronous admission observation; every walk owns its entire read budget.
package struct DarwinProcessChainReader: ProcessChainReading {
    private let facts: any ProcessChainFactsReading
    private let readLimit: Int

    package init() {
        facts = DarwinProcessChainFactsReader()
        readLimit = AppPolicies.Sessions.mainEligibilityReadLimit
    }

    package init(facts: any ProcessChainFactsReading, readLimit: Int) {
        self.facts = facts
        self.readLimit = readLimit
    }

    package func observe(peer: ProcessChainPeer?, provider: String) -> ProcessChainObservation {
        guard let peer else { return .unknown(.peerUnbound) }
        var walk = ProcessChainWalk(facts: facts, remainingReads: readLimit)
        do {
            return try walk.observe(peer: peer, provider: provider)
        } catch {
            return .unknown(error)
        }
    }
}

/// CLI → optional hook-script sh → Cursor's zsh if applicable → first provider → shell → shell parent.
/// The skipped hook shell uses the same hop continuity checks and read budget as every other edge.
private struct ProcessChainWalk {
    let facts: any ProcessChainFactsReading
    var remainingReads: Int

    mutating func observe(peer: ProcessChainPeer, provider: String) throws(ChainUnknownReason)
        -> ProcessChainObservation
    {
        let providerNames: Set<String>
        switch provider {
        case "claude-code": providerNames = ["claude"]
        case "codex": providerNames = ["codex"]
        case "cursor": providerNames = ["agent", "cursor-agent"]
        default: throw .unsupportedProvider
        }
        try requirePeerVersion(peer)
        var agent = try parent(of: peer.pid, expected: nil)
        if agent.executableName == "sh" {
            agent = try parent(of: agent.incarnation.pid, expected: agent)
        }
        if provider == "cursor" {
            guard agent.executableName == "zsh" else { throw .unrecognizedChain }
            agent = try parent(of: agent.incarnation.pid, expected: agent)
        }
        guard providerNames.contains(agent.executableName) else { throw .unrecognizedChain }
        // Stop at the first provider. Walking beyond it could turn a nested agent into the main.
        let shell = try parent(of: agent.incarnation.pid, expected: agent)
        let shellParent = try parent(of: shell.incarnation.pid, expected: shell)
        let parentKind: ProcessChainObservation.ShellParent
        switch shellParent.executableName {
        case "tmux": parentKind = .multiplexerServer(.tmux)
        case "herdr": parentKind = .multiplexerServer(.herdr)
        default: parentKind = .other
        }
        try requirePeerVersion(peer)
        return .agentShell(shell: shell.incarnation, shellParent: parentKind)
    }

    mutating func parent(of pid: Int32, expected: ProcessChainProcessFacts?) throws(ChainUnknownReason)
        -> ProcessChainProcessFacts
    {
        let child = try readProcess(pid)
        if let expected, !sameChild(child, expected) { throw .incarnationChanged }
        let parent = try readProcess(child.parentPID)
        let rereadChild = try readProcess(pid)
        guard sameChild(child, rereadChild) else { throw .incarnationChanged }
        let childStart = child.incarnation
        let parentStart = parent.incarnation
        guard
            parentStart.startSeconds < childStart.startSeconds
                || (parentStart.startSeconds == childStart.startSeconds
                    && parentStart.startMicroseconds <= childStart.startMicroseconds)
        else { throw .startOrder }
        return parent
    }

    private func sameChild(_ first: ProcessChainProcessFacts, _ second: ProcessChainProcessFacts) -> Bool {
        first.incarnation == second.incarnation && first.parentPID == second.parentPID
    }

    private mutating func readProcess(_ pid: Int32) throws(ChainUnknownReason) -> ProcessChainProcessFacts {
        try consumeRead()
        guard let process = facts.bsdInfo(of: pid) else { throw .processUnavailable }
        guard process.incarnation.pid == pid else { throw .incarnationChanged }
        return process
    }

    private mutating func requirePeerVersion(_ peer: ProcessChainPeer) throws(ChainUnknownReason) {
        try consumeRead()
        guard facts.pidVersion(of: peer.pid) == peer.pidVersion else { throw .peerUnbound }
    }

    private mutating func consumeRead() throws(ChainUnknownReason) {
        guard remainingReads > 0 else { throw .readLimit }
        remainingReads -= 1
    }
}
