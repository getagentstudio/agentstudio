import AgentStudioInfrastructure
import Darwin
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

extension DarwinProcessChainFactsReaderTests {
    @Test(
        "provider paths classify through the facts boundary without arguments", arguments: ExecutableIdentityCase.cases)
    func pathIdentification(identity: ExecutableIdentityCase) throws {
        let executable = CountingExecutableFacts(path: identity.path, argument: "rewritten-argv0")
        let reader = DarwinProcessChainFactsReader(executableReader: executable)
        let process = try #require(reader.bsdInfo(of: getpid()))
        let identified = reader.executableName(of: process)
        #expect(identified == identity.expected)
        #expect(executable.pathReads == (identity.expected == "rewritten-argv0" ? 2 : 1))
        #expect(executable.argumentReads == (identity.expected == "rewritten-argv0" ? 1 : 0))
    }

    @Test("a changed executable path during argv0 fallback is rejected")
    func fallbackRejectsExecutableChange() throws {
        let executable = CountingExecutableFacts(paths: ["/first/node", "/second/node"], argument: "claude")
        let reader = DarwinProcessChainFactsReader(executableReader: executable)
        let process = try #require(reader.bsdInfo(of: getpid()))
        #expect(reader.executableName(of: process) == nil)
        #expect(executable.argumentReads == 1)
        #expect(executable.pathReads == 2)
    }

    @Test(
        "supported provider paths preserve wrapper, nested and background chain decisions",
        arguments: IdentifiedChainScenario.allCases)
    func identifiedChains(scenario: IdentifiedChainScenario) {
        let cursor = scenario == .cursorHook
        let parentPID: Int32 = scenario == .nested || scenario == .background ? 35 : 30
        var table: [Int32: ProcessChainProcessFacts] = [
            60: chainFact(60, parent: 50, name: "agentstudio-cli"),
            50: chainFact(50, parent: cursor ? 45 : 40, name: "sh"),
            45: chainFact(45, parent: 40, name: "zsh"),
            40: chainFact(40, parent: parentPID, name: cursor ? "node" : "2.1.310"),
            30: chainFact(30, parent: 20, name: "zsh"),
            20: chainFact(20, parent: 1, name: "herdr"),
        ]
        if parentPID == 35 {
            table[35] = chainFact(35, parent: 30, name: scenario == .nested ? "zsh" : "2.1.302")
            // The ancestor provider is not inspected to rescue a nested or background chain.
            table[30] = chainFact(30, parent: 1, name: "2.1.302")
        }
        let executable = CountingExecutableFacts(
            path: cursor ? "/local/cursor-agent/versions/2026.10.16-old/node" : "/local/claude/versions/2.1.310",
            argument: "rewritten-argv0")
        let facts = IdentifiedChainFacts(table: table, executable: executable)
        let observation = DarwinProcessChainReader(facts: facts, readLimit: 20)
            .observe(peer: .init(pid: 60, pidVersion: 17), provider: cursor ? "cursor" : "claude-code")
        let expectedShell = chainIncarnation(parentPID)
        #expect(
            observation
                == .agentShell(
                    shell: expectedShell,
                    shellParent: parentPID == 30 ? .multiplexerServer(.herdr) : .other))
        #expect(observation.isMainEligible(terminalLeader: chainIncarnation(30)) == (parentPID == 30))
        #expect(executable.pathReads == 1)
        #expect(executable.argumentReads == 0)
    }
}

struct ExecutableIdentityCase: Sendable {
    let path: String?
    let expected: String
    static let cases: [Self] = [
        .init(path: "/home/.local/share/claude/versions/2.1.310", expected: "claude"),
        .init(path: "/home/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", expected: "claude"),
        .init(
            path: "/home/.codex/packages/standalone/releases/0.163.0-aarch64-apple-darwin/bin/codex", expected: "codex"),
        .init(path: "/home/.local/share/cursor-agent/versions/2026.10.22-new/node", expected: "agent"),
        .init(path: "/home/.local/share/cursor-agent/versions/2026.10.16-old/node", expected: "agent"),
        .init(path: "/usr/local/bin/node", expected: "rewritten-argv0"),
        .init(path: "/local/unrelated/versions/2.1.310", expected: "rewritten-argv0"),
        .init(path: "/local/claude/versions/2.1.310/other", expected: "rewritten-argv0"),
        .init(path: "/local/cursor-agent/other/2026.10.16/node", expected: "rewritten-argv0"),
        .init(path: nil, expected: "rewritten-argv0"),
    ]
}

enum IdentifiedChainScenario: CaseIterable, Sendable { case claudeHook, cursorHook, nested, background }

private final class CountingExecutableFacts: ProcessChainExecutableReading {
    private let paths: [String?]
    private let argument: String?
    private let counts = Mutex((paths: 0, arguments: 0))
    init(path: String?, argument: String?) {
        self.paths = [path]
        self.argument = argument
    }
    init(paths: [String?], argument: String?) {
        self.paths = paths
        self.argument = argument
    }
    var pathReads: Int { counts.withLock { $0.paths } }
    var argumentReads: Int { counts.withLock { $0.arguments } }
    func executablePath(of pid: Int32) -> String? {
        counts.withLock {
            let path = paths[min($0.paths, paths.count - 1)]
            $0.paths += 1
            return path
        }
    }
    func argumentZero(of pid: Int32) -> String? {
        counts.withLock { $0.arguments += 1 }
        return argument
    }
}

private struct IdentifiedChainFacts: ProcessChainFactsReading {
    let table: [Int32: ProcessChainProcessFacts]
    let executable: CountingExecutableFacts
    func bsdInfo(of pid: Int32) -> ProcessChainProcessFacts? { table[pid] }
    func pidVersion(of pid: Int32) -> UInt32? { 17 }
    func executableName(of process: ProcessChainProcessFacts) -> String? {
        DarwinProcessChainFactsReader(executableReader: executable).executableName(of: process)
    }
}
