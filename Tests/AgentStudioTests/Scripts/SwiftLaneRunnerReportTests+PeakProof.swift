import AgentStudioTestSupport
import Foundation
import Testing

extension SwiftLaneRunnerReportTests {
    @Test("announced concurrency excludes ended functions before later starts")
    func announcedPeakDropsEndedTestsBeforeLaterStarts() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let identifiers = ["Fixture.Peak/a()", "Fixture.Peak/b()", "Fixture.Peak/c()"]
        var records: [[String: Any]] = [["kind": "event", "payload": ["kind": "runStarted"]]]
        records.append(
            contentsOf: identifiers.map {
                ["kind": "test", "payload": ["id": $0, "kind": "function", "isParameterized": false]]
            })
        for (kind, index) in [
            ("testStarted", 0), ("testStarted", 1), ("testEnded", 0),
            ("testStarted", 2), ("testEnded", 1), ("testEnded", 2),
        ] {
            records.append(["kind": "event", "payload": ["kind": kind, "testID": identifiers[index]]])
        }
        records.append(["kind": "event", "payload": ["kind": "runEnded"]])
        try fixture.writeEvents(records)

        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: 0)
        let facts = try await runCommandToExit(
            command: "/usr/bin/perl",
            arguments: ["scripts/swift-test-invocation-receipts.pl", "facts", fixture.events.path, "1"])

        #expect(result.output.contains("STATUS=0"), Comment(rawValue: result.output))
        #expect(facts.exitCode == 0, Comment(rawValue: facts.stderr))
        #expect(facts.stdout.contains("tests_run=3"), Comment(rawValue: facts.stdout))
        #expect(facts.stdout.contains("peak_announced_tests=2"), Comment(rawValue: facts.stdout))
    }
}
