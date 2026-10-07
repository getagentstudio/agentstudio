import Foundation
import Testing

@testable import AgentStudioCore

/// Table-driven proof for `ZmxSessionInventoryParser` against the zmx source
/// mapping (`vendor/zmx/src/util.zig:942-990`, confirmed 2026-09-30), not
/// against the parser's own assumptions (Program Design item 1; plan S1).
@Suite
struct ZmxSessionInventoryParserTests {
    private struct ParserCase: Sendable, CustomTestStringConvertible {
        let name: String
        let stdout: String
        let expected: ZmxSessionInventory

        var testDescription: String { name }
    }

    private static let aliveID = ZmxSessionID(restoring: "0198f000-aaaa-7000-8000-000000000001")!
    private static let secondAliveID = ZmxSessionID(restoring: "0198f000-aaaa-7000-8000-000000000002")!
    private static let refusedID = ZmxSessionID(restoring: "0198f000-bbbb-7000-8000-000000000003")!
    private static let unresponsiveTimeoutID = ZmxSessionID(restoring: "0198f000-cccc-7000-8000-000000000004")!
    private static let unresponsiveUnexpectedID = ZmxSessionID(restoring: "0198f000-cccc-7000-8000-000000000005")!

    private static let cases: [ParserCase] = [
        ParserCase(
            name: "empty stdout is a complete, empty inventory",
            stdout: "",
            expected: .complete([:])
        ),
        ParserCase(
            name: "name/pid/clients/created/cwd/cmd maps to alive, keyed by wrapper pid",
            stdout: "name=\(aliveID.rawValue)\tpid=1234\tclients=1\tcreated=1727\tcwd=/tmp/p\tcmd=zsh\n",
            expected: .complete([aliveID: .alive(wrapperPid: 1234)])
        ),
        ParserCase(
            name: "alive line with only the four required fields still parses",
            stdout: "name=\(aliveID.rawValue)\tpid=1\tclients=0\tcreated=1\n",
            expected: .complete([aliveID: .alive(wrapperPid: 1)])
        ),
        ParserCase(
            name: "status=cleaning up (ConnectionRefused) maps to refused",
            stdout: "name=\(refusedID.rawValue)\terr=ConnectionRefused\tstatus=cleaning up\n",
            expected: .complete([refusedID: .refused])
        ),
        ParserCase(
            name: "status=unreachable from a Timeout maps to unresponsive",
            stdout: "name=\(unresponsiveTimeoutID.rawValue)\terr=Timeout\tstatus=unreachable\n",
            expected: .complete([unresponsiveTimeoutID: .unresponsive])
        ),
        ParserCase(
            name: "status=unreachable from any other unexpected error also maps to unresponsive",
            stdout: "name=\(unresponsiveUnexpectedID.rawValue)\terr=Unexpected\tstatus=unreachable\n",
            expected: .complete([unresponsiveUnexpectedID: .unresponsive])
        ),
        ParserCase(
            name: "an absent name is simply absent from a complete inventory, not a case of its own",
            stdout: "name=\(aliveID.rawValue)\tpid=1\tclients=0\tcreated=1\n",
            expected: .complete([aliveID: .alive(wrapperPid: 1)])
        ),
        ParserCase(
            name: "multiple sessions in one listing are all classified independently",
            stdout: """
                name=\(aliveID.rawValue)\tpid=100\tclients=1\tcreated=1
                name=\(refusedID.rawValue)\terr=ConnectionRefused\tstatus=cleaning up
                name=\(secondAliveID.rawValue)\tpid=200\tclients=2\tcreated=2\tcwd=/tmp
                """,
            expected: .complete([
                aliveID: .alive(wrapperPid: 100),
                refusedID: .refused,
                secondAliveID: .alive(wrapperPid: 200),
            ])
        ),
        ParserCase(
            name: "a leading current-session arrow marker is stripped, not treated as garbled",
            stdout: "→ name=\(aliveID.rawValue)\tpid=1\tclients=0\tcreated=1\n",
            expected: .complete([aliveID: .alive(wrapperPid: 1)])
        ),
        ParserCase(
            name: "a leading two-space non-current-session marker is stripped the same way",
            stdout: "  name=\(aliveID.rawValue)\tpid=1\tclients=0\tcreated=1\n",
            expected: .complete([aliveID: .alive(wrapperPid: 1)])
        ),
        ParserCase(
            name: "garbled output (no recognizable name= line) makes the whole inventory unavailable",
            stdout: "this is not a zmx list line at all\n",
            expected: .unavailable(.unparsable)
        ),
        ParserCase(
            name: "an unrecognized status value is never guessed at; the whole inventory is unparsable",
            stdout: "name=\(refusedID.rawValue)\terr=SomethingNew\tstatus=exploding\n",
            expected: .unavailable(.unparsable)
        ),
        ParserCase(
            name: "one unparsable line makes the whole inventory unavailable, even alongside good lines",
            stdout: """
                name=\(aliveID.rawValue)\tpid=100\tclients=1\tcreated=1
                garbage
                """,
            expected: .unavailable(.unparsable)
        ),
        ParserCase(
            name: "an alive line missing a required field (pid) is unparsable, not silently dropped",
            stdout: "name=\(aliveID.rawValue)\tclients=1\tcreated=1\n",
            expected: .unavailable(.unparsable)
        ),
    ]

    @Test(arguments: cases)
    private func parsesAccordingToTheZmxSourceMapping(_ testCase: ParserCase) {
        // Arrange — testCase.stdout is the exact wire shape zmx's writeSessionLine
        // produces (vendor/zmx/src/util.zig:942-990).

        // Act
        let inventory = ZmxSessionInventoryParser.parse(stdout: testCase.stdout)

        // Assert
        #expect(inventory == testCase.expected, "\(testCase.name)")
    }

    @Test
    private func nonZeroExitAndTimeoutAreNeverTheParsersToDecide() {
        // Arrange — the parser only ever sees stdout text from a run the
        // caller (ZmxSessionInventoryProbe, S2) already knows succeeded.
        // `.timedOut` and `.exitedNonZero` are process-execution outcomes
        // the probe produces directly, never derived from stdout content, so
        // there is nothing for this parser to prove about them beyond: it
        // never produces those two cases itself.
        let stdout = "name=\(Self.aliveID.rawValue)\tpid=1\tclients=0\tcreated=1\n"

        // Act
        let inventory = ZmxSessionInventoryParser.parse(stdout: stdout)

        // Assert
        guard case .unavailable(let failure) = inventory else { return }
        #expect(failure == .unparsable, "the parser's own failure vocabulary is limited to .unparsable")
    }
}
