import Testing

@testable import AgentStudioCore

@Suite("Protocol-independent zmx daemon selection")
struct ZmxDaemonSelectionTests {
    private let creator = Self.evidence(pid: 41, parent: 1, group: 40)
    private let daemon = Self.evidence(pid: 42, parent: 41, group: 42)
    private let leader = Self.evidence(pid: 43, parent: 42, group: 43)

    @Test("one listener that is a session leader and parents the terminal is selected")
    func uniqueDaemonIsSelected() throws {
        let actual = try ZmxIncompatibleSessionStop.selectDaemon(
            processes: [creator, daemon, leader], holders: [daemon])
        #expect(actual.pid == 42)
    }

    @Test("retained creator, absent holder, nonleader holder and childless holder all refuse", arguments: 0..<4)
    func unverifiableDaemonRefuses(scenario: Int) {
        let processes: [ZmxIncompatibleSessionStop.ProcessEvidence]
        let holders: [ZmxIncompatibleSessionStop.ProcessEvidence]
        switch scenario {
        case 0:
            processes = [creator, daemon, leader]
            holders = [creator, daemon]
        case 1:
            processes = [creator, daemon, leader]
            holders = []
        case 2:
            let notLeader = Self.evidence(pid: 42, parent: 41, group: 40)
            processes = [creator, notLeader, leader]
            holders = [notLeader]
        default:
            processes = [creator, daemon]
            holders = [daemon]
        }
        #expect(throws: ZmxSessionControlFailure.processUnverifiable) {
            try ZmxIncompatibleSessionStop.selectDaemon(processes: processes, holders: holders)
        }
    }

    private static func evidence(pid: Int32, parent: Int32, group: Int32) -> ZmxIncompatibleSessionStop.ProcessEvidence
    {
        .init(incarnation: .init(pid: pid, startSeconds: 100, startMicroseconds: 0), parentPID: parent, groupPID: group)
    }
}
