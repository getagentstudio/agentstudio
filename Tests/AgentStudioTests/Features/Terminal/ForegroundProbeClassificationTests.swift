import AgentStudioInfrastructure
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

@Suite("Foreground probe classification")
struct ForegroundProbeClassificationTests {
    @Test("foreground group classification ignores stopped and background agents")
    func backgroundAgentDoesNotBecomeForeground() {
        let shell = foregroundTestProcess(pid: 4100)
        let samples = [
            foregroundTestSample(process: shell, group: 4100, foregroundGroup: 4100, argv0: "/bin/zsh"),
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4101), group: 4101, foregroundGroup: 4100, argv0: "claude"),
        ]
        #expect(
            DarwinTerminalForegroundProbe.classify(
                leader: shell, samples: samples, incompleteLeaders: [], leadersWithVanishedRows: []) == .shell)
    }

    @Test(
        "both known binaries classify only inside tpgid",
        arguments: [("/tmp/claude", ForegroundProgram.claudeCode), ("codex", .codex)])
    func foregroundAgentsAreRecognized(argv0: String, expected: ForegroundProgram) {
        let shell = foregroundTestProcess(pid: 4100)
        let samples = [
            foregroundTestSample(process: shell, group: 4100, foregroundGroup: 4200, argv0: "/bin/zsh"),
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4200), group: 4200, foregroundGroup: 4200, argv0: argv0),
        ]
        #expect(
            DarwinTerminalForegroundProbe.classify(
                leader: shell, samples: samples, incompleteLeaders: [], leadersWithVanishedRows: []) == expected)
    }

    @Test("a foreground program that is not a shell or agent is other")
    func anotherForegroundProgramIsOther() {
        let shell = foregroundTestProcess(pid: 4100)
        let samples = [
            foregroundTestSample(process: shell, group: 4100, foregroundGroup: 4200, argv0: "/bin/zsh"),
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4200), group: 4200, foregroundGroup: 4200, argv0: "vim"),
        ]
        #expect(
            DarwinTerminalForegroundProbe.classify(
                leader: shell, samples: samples, incompleteLeaders: [], leadersWithVanishedRows: []) == .other)
    }

    @Test("incomplete or empty ps is unknown, never shell", arguments: [false, true])
    func incompletePassIsUnknown(empty: Bool) {
        let shell = foregroundTestProcess(pid: 4100)
        let samples =
            empty ? [] : [foregroundTestSample(process: shell, group: 4100, foregroundGroup: 4100, argv0: "/bin/zsh")]
        #expect(
            DarwinTerminalForegroundProbe.classify(
                leader: shell, samples: samples, incompleteLeaders: empty ? [] : [shell.pid],
                leadersWithVanishedRows: []) == .unknown)
    }

    // MARK: - Per-leader completeness (F3, review round 1, 2026-10-02)
    //
    // `classify` moves from one pass-wide `complete: Bool` to two per-leader
    // sets, `incompleteLeaders`/`leadersWithVanishedRows` (PD 7
    // classification; RS6/SR11). These three tests are written against that
    // new shape; they do not compile against today's `classify(leader:
    // samples:complete:)` on b83e9db86 -- the Lead treats that compile
    // failure on these exact symbols as the expected RED.

    @Test("an incomplete leader is unknown even when another leader in the same pass is fully readable")
    func incompleteLeaderIsUnknownIndependentOfOtherLeaders() {
        let leaderA = foregroundTestProcess(pid: 4700)
        let leaderB = foregroundTestProcess(pid: 4800)
        let samplesForB = [
            foregroundTestSample(process: leaderB, group: 4800, foregroundGroup: 4900, argv0: "/bin/zsh"),
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4900), group: 4900, foregroundGroup: 4900, argv0: "claude"),
        ]

        let resultA = DarwinTerminalForegroundProbe.classify(
            leader: leaderA, samples: [], incompleteLeaders: [leaderA.pid], leadersWithVanishedRows: [])
        let resultB = DarwinTerminalForegroundProbe.classify(
            leader: leaderB, samples: samplesForB, incompleteLeaders: [leaderA.pid], leadersWithVanishedRows: [])

        #expect(resultA == .unknown)
        #expect(resultB == .claudeCode)
    }

    @Test("a readable agent foreground row still classifies even when another row for the same leader vanished")
    func readableAgentRowWinsDespiteVanishedRows() {
        let leader = foregroundTestProcess(pid: 4700)
        let samples = [
            foregroundTestSample(process: leader, group: 4700, foregroundGroup: 4800, argv0: "/bin/zsh"),
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4800), group: 4800, foregroundGroup: 4800, argv0: "claude"),
        ]

        let result = DarwinTerminalForegroundProbe.classify(
            leader: leader, samples: samples, incompleteLeaders: [], leadersWithVanishedRows: [leader.pid])

        #expect(result == .claudeCode)
    }

    @Test("a vanished row makes a shell-only leader unknown, never shell")
    func vanishedRowMakesShellOnlyLeaderUnknownNeverShell() {
        let leader = foregroundTestProcess(pid: 4700)
        let samples = [
            foregroundTestSample(process: leader, group: 4700, foregroundGroup: 4700, argv0: "/bin/zsh")
        ]

        let result = DarwinTerminalForegroundProbe.classify(
            leader: leader, samples: samples, incompleteLeaders: [], leadersWithVanishedRows: [leader.pid])

        #expect(result == .unknown)
    }

    @Test(
        "a neighbouring pane's failed foreground row is attributed only to that pane",
        arguments: [false, true])
    func neighbourReadFailurePreservesAgentPane(unreadable: Bool) throws {
        let leaderA = foregroundTestProcess(pid: 4100)
        let leaderB = foregroundTestProcess(pid: 5100)
        let pass = try DarwinTerminalForegroundProbe.attributeSamples(
            rows: attributionRows(), requestedLeaderPids: [leaderA.pid, leaderB.pid]
        ) { pid, readArguments in
            if pid == 5200 { return unreadable ? .unreadable : .vanished }
            return .sample(try attributionSample(pid: pid, readArguments: readArguments))
        }
        let resultA = DarwinTerminalForegroundProbe.classify(
            leader: leaderA, samples: pass.samples, incompleteLeaders: pass.incompleteLeaders,
            leadersWithVanishedRows: pass.leadersWithVanishedRows)
        let resultB = DarwinTerminalForegroundProbe.classify(
            leader: leaderB, samples: pass.samples, incompleteLeaders: pass.incompleteLeaders,
            leadersWithVanishedRows: pass.leadersWithVanishedRows)
        let expectedIncomplete: Set<Int32> = unreadable ? [leaderB.pid] : []
        let expectedVanished: Set<Int32> = unreadable ? [] : [leaderB.pid]

        #expect(resultA == .claudeCode)
        #expect(resultB == .unknown)
        #expect(pass.incompleteLeaders == expectedIncomplete)
        #expect(pass.leadersWithVanishedRows == expectedVanished)
    }

    @Test("regrouping a requested leader invalidates only that pane's native pass")
    func regroupedLeaderDoesNotInvalidateNeighbour() throws {
        let leaderA = foregroundTestProcess(pid: 4100)
        let leaderB = foregroundTestProcess(pid: 5100)
        let pass = try DarwinTerminalForegroundProbe.attributeSamples(
            rows: attributionRows(), requestedLeaderPids: [leaderA.pid, leaderB.pid]
        ) { pid, readArguments in
            if pid == leaderA.pid {
                return .sample(foregroundTestSample(process: leaderA, group: 4300, foregroundGroup: 4200, argv0: ""))
            }
            return .sample(try attributionSample(pid: pid, readArguments: readArguments))
        }
        let resultA = DarwinTerminalForegroundProbe.classify(
            leader: leaderA, samples: pass.samples, incompleteLeaders: pass.incompleteLeaders,
            leadersWithVanishedRows: pass.leadersWithVanishedRows)
        let resultB = DarwinTerminalForegroundProbe.classify(
            leader: leaderB, samples: pass.samples, incompleteLeaders: pass.incompleteLeaders,
            leadersWithVanishedRows: pass.leadersWithVanishedRows)

        #expect(pass.incompleteLeaders == [leaderA.pid])
        #expect(pass.leadersWithVanishedRows.isEmpty)
        #expect(resultA == .unknown)
        #expect(resultB == .codex)
    }

    @Test("a requested leader missing from ps makes only that pane incomplete")
    func missingLeaderDoesNotInvalidatePresentPane() throws {
        let leaderA = foregroundTestProcess(pid: 4100)
        let leaderB = foregroundTestProcess(pid: 5100)
        // Keep A's readable agent alongside one vanished foreground sibling:
        // B's missing leader must not inherit even A's vanished-row attribution.
        let rows = attributionRows().filter { $0.pid != leaderB.pid } + [(4201, 4200, 4200)]
        let pass = try DarwinTerminalForegroundProbe.attributeSamples(
            rows: rows, requestedLeaderPids: [leaderA.pid, leaderB.pid]
        ) { pid, readArguments in
            #expect(pid != 5200, "without B's leader row its foreground group cannot authorize an argv read")
            if pid == 4201 { return .vanished }
            return .sample(try attributionSample(pid: pid, readArguments: readArguments))
        }
        let resultA = DarwinTerminalForegroundProbe.classify(
            leader: leaderA, samples: pass.samples, incompleteLeaders: pass.incompleteLeaders,
            leadersWithVanishedRows: pass.leadersWithVanishedRows)
        let resultB = DarwinTerminalForegroundProbe.classify(
            leader: leaderB, samples: pass.samples, incompleteLeaders: pass.incompleteLeaders,
            leadersWithVanishedRows: pass.leadersWithVanishedRows)

        #expect(pass.incompleteLeaders == [leaderB.pid])
        #expect(pass.leadersWithVanishedRows == [leaderA.pid])
        #expect(resultA == .claudeCode)
        #expect(resultB == .unknown)
    }

    private func attributionRows() -> [(pid: Int32, group: Int32, foreground: Int32)] {
        [(4100, 4100, 4200), (4200, 4200, 4200), (5100, 5100, 5200), (5200, 5200, 5200)]
    }

    private func attributionSample(pid: Int32, readArguments: Bool) throws -> ForegroundProcessSample {
        let row = try #require(attributionRows().first { $0.pid == pid })
        let argv0 = readArguments ? (pid == 4200 ? "claude" : "codex") : ""
        return foregroundTestSample(
            process: foregroundTestProcess(pid: pid), group: row.group, foregroundGroup: row.foreground, argv0: argv0)
    }

    @Test("one ps pass serves every requested pane and retains only typed process identity")
    func onePassClassifiesSeveralSessions() async throws {
        let firstId = ZmxSessionID.generateUUIDv7()
        let secondId = ZmxSessionID.generateUUIDv7()
        let firstIdentity = try foregroundTestIdentity()
        let secondIdentity = try foregroundTestIdentity(leaderPid: 4500)
        let identities = ForegroundTestSessionControl(identities: [firstId: firstIdentity, secondId: secondIdentity])
        let reads = ForegroundPassCounter()
        let samples = [
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4100), group: 4100, foregroundGroup: 4200, argv0: "/bin/zsh"),
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4200), group: 4200, foregroundGroup: 4200, argv0: "claude"),
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4500), group: 4500, foregroundGroup: 4600, argv0: "/bin/zsh"),
            foregroundTestSample(
                process: foregroundTestProcess(pid: 4600), group: 4600, foregroundGroup: 4600, argv0: "codex"),
        ]
        let probe = DarwinTerminalForegroundProbe(
            sessionDirectory: "/unused-proof", bootId: "foreground-proof-boot",
            sessionControl: identities,
            readSamples: {
                reads.increment()
                return .init(samples: samples, incompleteLeaders: [], leadersWithVanishedRows: [])
            })
        let result = try await probe.probeForeground(of: [firstId, secondId])
        #expect(reads.value() == 1)
        #expect(result[firstId]?.program == .claudeCode)
        #expect(result[secondId]?.program == .codex)
        #expect(result[firstId]?.foregroundProcess == foregroundTestProcess(pid: 4200))
        #expect(result[firstId]?.sessionIdentity == firstIdentity)
    }
}

private final class ForegroundPassCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    func value() -> Int { count.withLock { $0 } }
}

private struct ForegroundTestSessionControl: ZmxSessionControlling {
    let identities: [ZmxSessionID: Data]
    func observeSessionIdentity(_ sessionID: ZmxSessionID) -> Data? { identities[sessionID] }
    func retireVerifiedSession(_ sessionID: ZmxSessionID, expectedIdentity: Data) throws -> ZmxSessionCleanupStatus {
        throw ZmxSessionControlFailure.unavailable
    }
}

func foregroundTestProcess(pid: Int32) -> ProcessIncarnation {
    ProcessIncarnation(pid: pid, startSeconds: 100, startMicroseconds: UInt64(pid))
}

func foregroundTestSample(
    process: ProcessIncarnation, group: Int32, foregroundGroup: Int32, argv0: String
) -> ForegroundProcessSample {
    ForegroundProcessSample(
        incarnation: process, processGroupId: group, foregroundGroupId: foregroundGroup, argv0: argv0)
}

func foregroundTestIdentity(leaderPid: Int32 = 4100, bootId: String = "foreground-proof-boot") throws -> Data {
    try ZmxSessionIdentity(
        version: 1, bootID: bootId, daemon: foregroundTestProcess(pid: leaderPid - 1),
        terminalLeader: foregroundTestProcess(pid: leaderPid), processGroupID: leaderPid, sessionCreatedAt: 100
    ).encoded()
}
