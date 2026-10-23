import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Main agent process-chain observation")
struct ProcessChainReadingTests {
    @Test("only the observed provider wrappers and one multiplexer level are recognized", arguments: ChainCase.allCases)
    func observedChains(chainCase: ChainCase) {
        let fixture = ChainTableFixture(chainCase: chainCase)
        // Isolate wrapper classification from the separate hard read-budget checks.
        let reader = DarwinProcessChainReader(facts: fixture.facts, readLimit: 32)
        let observation = reader.observe(peer: fixture.peer, provider: fixture.provider)
        #expect(observation == fixture.expectedObservation)
        #expect(observation.isMainEligible(terminalLeader: fixture.leader) == fixture.expectedEligible)
    }

    @Test("each discontinuity fails closed independently of process names", arguments: ContinuityCase.allCases)
    func continuityFailures(continuity: ContinuityCase) {
        let fixture = ChainTableFixture(chainCase: .directClaude)
        let scenario = continuity.scenario(table: fixture.table)
        let facts = ScriptedChainFacts(
            table: scenario.table, versions: scenario.versions, overrides: scenario.overrides)
        let reader = DarwinProcessChainReader(facts: facts, readLimit: scenario.readLimit)
        let observation = reader.observe(peer: fixture.peer, provider: fixture.provider)
        #expect(observation == .unknown(scenario.reason))
        #expect(!observation.isMainEligible(terminalLeader: fixture.leader))
        #expect(facts.totalReads <= scenario.readLimit)
    }

    @Test("read exhaustion includes validation rereads and both audit-token lookups", arguments: [0, 1, 2, 10, 13])
    func readBudgetIsHard(limit: Int) {
        let fixture = ChainTableFixture(chainCase: .directCursor)
        let observation = DarwinProcessChainReader(facts: fixture.facts, readLimit: limit)
            .observe(peer: fixture.peer, provider: fixture.provider)
        #expect(observation == .unknown(.readLimit))
        #expect(fixture.facts.totalReads <= limit)
    }

    @Test("a reused leader pid is not the observed shell, and unknown never elects")
    func leaderIncarnationAndUnknown() {
        let shell = chainIncarnation(30)
        let observation = ProcessChainObservation.agentShell(shell: shell, shellParent: .other)
        #expect(observation.isMainEligible(terminalLeader: shell))
        #expect(!observation.isMainEligible(terminalLeader: chainIncarnation(30, started: 31)))
        #expect(!observation.isMainEligible(terminalLeader: nil))
        #expect(!ProcessChainObservation.unknown(.peerUnbound).isMainEligible(terminalLeader: shell))
        let fixture = ChainTableFixture(chainCase: .directClaude)
        #expect(
            DarwinProcessChainReader(facts: fixture.facts, readLimit: 16).observe(peer: nil, provider: "claude-code")
                == .unknown(.peerUnbound))
    }
}

extension ProcessChainReadingTests {
    enum ChainCase: CaseIterable, Sendable {
        case directClaude, directCodex, directCursor, cursorAgentAlias
        case claudeTmux, codexTmux, cursorTmux, claudeHerdr, codexHerdr, cursorHerdr
        case nestedCodex, claudeBackground, unknownWrapper, twoCursorWrappers, unknownProvider
    }

    enum ContinuityCase: CaseIterable, Sendable {
        case versionBefore, versionDuring, peerExitWithHeldSocket, peerGoneWithUnchangedToken
        case intermediateReplacement, childReplacementSameParent, parentExitDuringHop, parentReparentedBetweenHops
        case startOrder, exhausted, deniedRead, execAfterCapture, wrongPID

        fileprivate func scenario(table: [Int32: ProcessChainProcessFacts]) -> ContinuityScenario {
            var scenario = ContinuityScenario(table: table)
            switch self {
            case .versionBefore: scenario.versions = [18]
            case .versionDuring, .execAfterCapture: scenario.versions = [17, 18]
            case .peerExitWithHeldSocket:
                scenario.table.removeValue(forKey: 50)
                scenario.versions = [nil]
            case .peerGoneWithUnchangedToken:
                scenario.table.removeValue(forKey: 50)
                scenario.reason = .processUnavailable
            case .intermediateReplacement:
                scenario.overrides[.init(pid: 40, ordinal: 2)] = .available(
                    chainFact(40, parent: 30, name: "claude", started: 41))
                scenario.reason = .incarnationChanged
            case .childReplacementSameParent:
                scenario.overrides[.init(pid: 50, ordinal: 2)] = .available(
                    chainFact(50, parent: 40, name: "agentstudio-cli", started: 51))
                scenario.reason = .incarnationChanged
            case .parentExitDuringHop:
                scenario.overrides[.init(pid: 50, ordinal: 2)] = .available(
                    chainFact(50, parent: 1, name: "agentstudio-cli"))
                scenario.reason = .incarnationChanged
            case .parentReparentedBetweenHops:
                scenario.overrides[.init(pid: 40, ordinal: 2)] = .available(chainFact(40, parent: 1, name: "claude"))
                scenario.reason = .incarnationChanged
            case .startOrder:
                scenario.table[40] = chainFact(40, parent: 30, name: "claude", started: 60)
                scenario.reason = .startOrder
            case .exhausted:
                scenario.readLimit = 10
                scenario.reason = .readLimit
            case .deniedRead:
                scenario.overrides[.init(pid: 40, ordinal: 1)] = .unavailable
                scenario.reason = .processUnavailable
            case .wrongPID:
                scenario.overrides[.init(pid: 40, ordinal: 1)] = .available(chainFact(41, parent: 30, name: "claude"))
                scenario.reason = .incarnationChanged
            }
            return scenario
        }
    }
}

private struct ContinuityScenario {
    var table: [Int32: ProcessChainProcessFacts]
    var versions: [UInt32?] = [17, 17]
    var overrides: [ChainReadKey: ChainReadResult] = [:]
    var readLimit = 16
    var reason = ChainUnknownReason.peerUnbound
}

private struct ChainTableFixture {
    let peer = ProcessChainPeer(pid: 50, pidVersion: 17)
    let provider: String
    let table: [Int32: ProcessChainProcessFacts]
    let facts: ScriptedChainFacts
    let expectedObservation: ProcessChainObservation
    let expectedEligible: Bool
    let leader: ZmxProcessIncarnation

    init(chainCase: ProcessChainReadingTests.ChainCase) {
        var table: [Int32: ProcessChainProcessFacts] = [
            50: chainFact(50, parent: 40, name: "agentstudio-cli"),
            40: chainFact(40, parent: 30, name: "claude"),
            30: chainFact(30, parent: 20, name: "zsh"),
            20: chainFact(20, parent: 1, name: "zmx"),
        ]
        var provider = "claude-code"
        var parent = ProcessChainObservation.ShellParent.other
        var shell = chainIncarnation(30)
        var leader = chainIncarnation(30)
        var expectedEligible = true
        var unknown: ChainUnknownReason?
        switch chainCase {
        case .directCodex, .codexTmux, .codexHerdr, .nestedCodex:
            provider = "codex"
            table[40] = chainFact(40, parent: 30, name: "codex")
        case .directCursor, .cursorAgentAlias, .cursorTmux, .cursorHerdr, .twoCursorWrappers:
            provider = "cursor"
            table[50] = chainFact(50, parent: 45, name: "agentstudio-cli")
            table[45] = chainFact(45, parent: 40, name: "zsh")
            table[40] = chainFact(40, parent: 30, name: chainCase == .cursorAgentAlias ? "cursor-agent" : "agent")
        default: break
        }
        switch chainCase {
        case .claudeTmux, .codexTmux, .cursorTmux:
            table[20] = chainFact(20, parent: 1, name: "tmux")
            parent = .multiplexerServer(.tmux)
            leader = chainIncarnation(10)
        case .claudeHerdr, .codexHerdr, .cursorHerdr:
            table[20] = chainFact(20, parent: 1, name: "herdr")
            parent = .multiplexerServer(.herdr)
            leader = chainIncarnation(10)
        case .nestedCodex:
            table[40] = chainFact(40, parent: 35, name: "codex")
            table[35] = chainFact(35, parent: 30, name: "zsh")
            table[30] = chainFact(30, parent: 20, name: "claude")
            table[20] = chainFact(20, parent: 1, name: "zsh")
            shell = chainIncarnation(35)
            leader = chainIncarnation(20)
            expectedEligible = false
        case .claudeBackground:
            table[40] = chainFact(40, parent: 35, name: "claude")
            table[35] = chainFact(35, parent: 30, name: "claude")
            table[30] = chainFact(30, parent: 1, name: "claude")
            shell = chainIncarnation(35)
            leader = chainIncarnation(20)
            expectedEligible = false
        case .unknownWrapper:
            table[50] = chainFact(50, parent: 45, name: "agentstudio-cli")
            table[45] = chainFact(45, parent: 40, name: "zsh")
            unknown = .unrecognizedChain
            expectedEligible = false
        case .twoCursorWrappers:
            table[45] = chainFact(45, parent: 43, name: "zsh")
            table[43] = chainFact(43, parent: 40, name: "zsh")
            unknown = .unrecognizedChain
            expectedEligible = false
        case .unknownProvider:
            provider = "other"
            unknown = .unsupportedProvider
            expectedEligible = false
        default: break
        }
        self.provider = provider
        self.table = table
        facts = ScriptedChainFacts(table: table)
        expectedObservation =
            unknown.map(ProcessChainObservation.unknown)
            ?? .agentShell(shell: shell, shellParent: parent)
        self.expectedEligible = expectedEligible
        self.leader = leader
    }
}
