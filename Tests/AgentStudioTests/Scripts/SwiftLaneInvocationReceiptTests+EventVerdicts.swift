import AgentStudioTestSupport
import Foundation
import Testing

extension SwiftLaneInvocationReceiptTests {
    @Test(
        "unattributed issues retain their verdict without inventing a test identity",
        arguments: ["failure", "known", "warning"], [0, 7])
    func unattributedIssuesKeepTheirVerdict(issueKind: String, childStatus: Int) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try writeCapturedInvocation(fixture, selecting: "recordsPass()")
        var records = try String(contentsOf: fixture.events, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        records.insert(
            [
                "kind": "event", "version": "6.3.0",
                "payload": [
                    "kind": "issueRecorded",
                    "issue": [
                        "isFailure": issueKind == "failure", "isKnown": issueKind == "known",
                        "severity": issueKind == "warning" ? "warning" : "error",
                    ],
                ],
            ], at: records.count - 1)
        try fixture.writeEvents(records)

        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: childStatus)
        let hasFailure = issueKind == "failure"
        let expectedStatus = hasFailure && childStatus == 0 ? 1 : childStatus
        #expect(result.output.contains("STATUS=\(expectedStatus)"), Comment(rawValue: result.output))
        #expect(result.output.contains("stream=complete"), Comment(rawValue: result.output))
        #expect(result.output.contains("failing_issues=\(hasFailure ? 1 : 0)"), Comment(rawValue: result.output))
        #expect(result.output.contains("failing_issue=unattributed") == hasFailure, Comment(rawValue: result.output))
        #expect(!result.output.contains("failing_test="), Comment(rawValue: result.output))
        #expect(
            result.output.contains("lane-report crashed") == (!hasFailure && childStatus != 0),
            Comment(rawValue: result.output))
    }

    @Test(
        "the wrapper distinguishes captured condition-skipped tests from a filter matching nothing",
        arguments: ["swift test", "swiftpm-testing-helper"], [false, true])
    func wrapperDistinguishesSkippedTestsFromNoMatch(invocationKind: String, matchesSkippedTests: Bool) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let source = try Data(
            contentsOf: URL(
                fileURLWithPath: "Tests/AgentStudioTests/Scripts/Fixtures/xcode27-skipped-tests-v6.3.jsonl"))
        if matchesSkippedTests {
            try source.write(to: fixture.events)
        } else {
            let sourceText = try #require(String(bytes: source, encoding: .utf8))
            let records = try sourceText.split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            try fixture.writeEvents(
                records.filter {
                    let kind = ($0["payload"] as? [String: Any])?["kind"] as? String
                    return kind == "runStarted" || kind == "runEnded"
                })
        }

        let result = try await fixture.runEventFixture(as: invocationKind, expectedRuns: 1, exitStatus: 0)

        #expect(result.output.contains("STATUS=\(matchesSkippedTests ? 0 : 1)"), Comment(rawValue: result.output))
        #expect(result.output.contains("stream=complete"), Comment(rawValue: result.output))
        #expect(result.output.contains("tests_run=0"), Comment(rawValue: result.output))
        #expect(
            result.output.contains("tests_skipped=\(matchesSkippedTests ? 2 : 0)"), Comment(rawValue: result.output))
        #expect(
            result.output.contains("reason=no_matching_tests") == !matchesSkippedTests, Comment(rawValue: result.output)
        )
        #expect(!result.output.contains("crashed"), Comment(rawValue: result.output))
    }

    @Test("skipping only a suite container does not count as matching a test")
    func skippedSuiteContainerDoesNotMatchTest() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            ["kind": "test", "payload": ["id": "Fixture.EmptySuite", "kind": "suite"]],
            ["kind": "event", "payload": ["kind": "runStarted"]],
            ["kind": "event", "payload": ["kind": "testSkipped", "testID": "Fixture.EmptySuite"]],
            ["kind": "event", "payload": ["kind": "runEnded"]],
        ])

        let result = try await fixture.runEventFixture(as: "swiftpm-testing-helper", expectedRuns: 1, exitStatus: 0)

        #expect(result.output.contains("STATUS=1"), Comment(rawValue: result.output))
        #expect(result.output.contains("tests_skipped=0"), Comment(rawValue: result.output))
        #expect(result.output.contains("reason=no_matching_tests"), Comment(rawValue: result.output))
    }

    @Test("a skipped event without a known test identity fails closed", arguments: [false, true])
    func unclassifiedSkippedEventFailsClosed(hasIdentity: Bool) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        var skippedEvent: [String: Any] = ["kind": "testSkipped"]
        if hasIdentity { skippedEvent["testID"] = "Fixture.Unknown/test()" }
        try fixture.writeEvents([
            ["kind": "event", "payload": ["kind": "runStarted"]],
            ["kind": "event", "payload": skippedEvent],
            ["kind": "event", "payload": ["kind": "runEnded"]],
        ])

        let result = try await fixture.runEventFixture(as: "swiftpm-testing-helper", expectedRuns: 1, exitStatus: 0)

        #expect(result.output.contains("STATUS=1"), Comment(rawValue: result.output))
        #expect(result.output.contains("stream=unreadable"), Comment(rawValue: result.output))
        #expect(result.output.contains("reason=event_stream_incomplete"), Comment(rawValue: result.output))
    }

    @Test(
        "captured known issues and warnings independently pass through the wrapper",
        arguments: ["recordsKnownIssue()", "recordsWarning()"])
    func capturedNonFailingIssuesPass(testName: String) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try writeCapturedInvocation(fixture, selecting: testName)
        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: 0)
        #expect(result.output.contains("STATUS=0"), Comment(rawValue: result.output))
        #expect(result.output.contains("stream=complete"), Comment(rawValue: result.output))
        #expect(!result.output.contains("failing_test="), Comment(rawValue: result.output))
    }

    @Test(
        "invalid event records fail closed while surviving issues stay named",
        arguments: ["invalid-json\n", "{}\n", "{\"kind\":\"event\",\"payload\":{}}\n", "\u{00ff}\n"])
    func unreadableStreamKeepsFailureNames(invalidRecord: String) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try writeCapturedInvocation(fixture, selecting: "recordsFailure()")
        let handle = try FileHandle(forWritingTo: fixture.events)
        try handle.seekToEnd()
        try handle.write(contentsOf: invalidRecord == "\u{00ff}\n" ? Data([0xff, 0x0a]) : Data(invalidRecord.utf8))
        try handle.close()
        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: 0)
        #expect(result.output.contains("STATUS=1"), Comment(rawValue: result.output))
        #expect(result.output.contains("stream=unreadable"), Comment(rawValue: result.output))
        #expect(
            result.output.contains(
                "failing_test=AgentStudioTests.Xcode27EventStreamEvidenceScratchTests/recordsFailure()"),
            Comment(rawValue: result.output))
    }

    @Test("invalid console bytes preserve a pass derived from a valid captured event stream")
    func invalidConsoleBytesDoNotOverridePassingEventFacts() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try writeCapturedInvocation(fixture, selecting: "recordsPass()")
        let result = try await fixture.run(
            #"""
            /bin/bash -c 'printf "PASS_CONSOLE_BEFORE\n"; printf "\377"; cp "$1" "${@: -1}"; printf "PASS_CONSOLE_AFTER\n"' fixture '\#(fixture.events.path)' swiftpm-testing-helper
            """#)
        #expect(result.output.contains("STATUS=0"), Comment(rawValue: result.output))
        #expect(result.output.contains("stream=complete"), Comment(rawValue: result.output))
        #expect(result.output.contains("PASS_CONSOLE_BEFORE"), Comment(rawValue: result.output))
        #expect(result.output.contains("PASS_CONSOLE_AFTER"), Comment(rawValue: result.output))
        #expect(!result.output.contains("failing_test="), Comment(rawValue: result.output))
    }

    @Test("zero matches and unmatched run endings cannot pass or be called a crash", arguments: [false, true])
    func invalidRunCannotPass(unmatchedEnd: Bool) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            ["kind": "event", "payload": ["kind": unmatchedEnd ? "runEnded" : "runStarted"]],
            ["kind": "event", "payload": ["kind": unmatchedEnd ? "runStarted" : "runEnded"]],
        ])
        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: 0)
        #expect(result.output.contains("STATUS=1"), Comment(rawValue: result.output))
        #expect(
            result.output.contains(unmatchedEnd ? "reason=event_stream_incomplete" : "reason=no_matching_tests"),
            Comment(rawValue: result.output))
        #expect(!result.output.contains("crashed"), Comment(rawValue: result.output))
    }

    @Test("an early issue survives a large stream and retains exactly one failing-test line")
    func earlyFailureSurvivesLargeStream() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try writeCapturedInvocation(fixture, selecting: "recordsFailure()", repeatIssue: true, extraRecords: 20_000)
        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: 0)
        #expect(result.output.contains("STATUS=1"), Comment(rawValue: result.output))
        #expect(
            result.output.components(separatedBy: "lane-report failing_test=").count - 1 == 1,
            Comment(rawValue: result.output))
        let facts = try await runCommandToExit(
            command: "/usr/bin/perl",
            arguments: ["scripts/swift-test-invocation-receipts.pl", "facts", fixture.events.path, "1"])
        #expect(facts.stdout.contains("peak_announced_tests=1"))
    }

    @Test("real 6.3 case records without case IDs contribute to concurrency peaks")
    func parameterizedCasesWithoutIDsHavePeaks() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            ["kind": "event", "payload": ["kind": "runStarted"]],
            ["kind": "test", "payload": ["id": "Fixture.Suite/cases()", "kind": "function", "isParameterized": true]],
            ["kind": "event", "payload": ["kind": "testStarted", "testID": "Fixture.Suite/cases()"]],
            ["kind": "event", "payload": ["kind": "testCaseStarted", "testID": "Fixture.Suite/cases()"]],
            ["kind": "event", "payload": ["kind": "testCaseStarted", "testID": "Fixture.Suite/cases()"]],
            ["kind": "event", "payload": ["kind": "testCaseEnded", "testID": "Fixture.Suite/cases()"]],
            ["kind": "event", "payload": ["kind": "testCaseEnded", "testID": "Fixture.Suite/cases()"]],
            ["kind": "event", "payload": ["kind": "testEnded", "testID": "Fixture.Suite/cases()"]],
            ["kind": "event", "payload": ["kind": "runEnded"]],
        ])
        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: 0)
        #expect(result.output.contains("STATUS=0"), Comment(rawValue: result.output))
        let facts = try await runCommandToExit(
            command: "/usr/bin/perl",
            arguments: ["scripts/swift-test-invocation-receipts.pl", "facts", fixture.events.path, "1"])
        #expect(facts.stdout.contains("peak_announced_tests=1"), Comment(rawValue: facts.stdout))
        #expect(facts.stdout.contains("peak_running_parameterized_cases=2"), Comment(rawValue: facts.stdout))
    }

    @Test("a crash after an issue preserves the original status and recorded failure")
    func crashAfterIssueKeepsBothFacts() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try writeCapturedInvocation(fixture, selecting: "recordsFailure()", closingRun: false)
        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: 139)
        #expect(result.output.contains("STATUS=139"), Comment(rawValue: result.output))
        #expect(result.output.contains("stream=truncated"), Comment(rawValue: result.output))
        #expect(
            result.output.contains(
                "failing_test=AgentStudioTests.Xcode27EventStreamEvidenceScratchTests/recordsFailure()"),
            Comment(rawValue: result.output))
        #expect(!result.output.contains("lane-report crashed"), Comment(rawValue: result.output))
    }

    @Test("a parked invocation preserves its stream before reporting a failing issue on timeout")
    func hangAfterIssueKeepsFailureEvidence() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try writeCapturedInvocation(fixture, selecting: "recordsFailure()", closingRun: false)
        let armedPath = fixture.root.appending(path: "armed").path
        let releasePath = fixture.root.appending(path: "release.fifo").path
        let result = try await fixture.run(
            "/bin/bash -c 'cp \"$1\" \"${@: -1}\"; : > \"$2\"; read line < \"$3\"' fixture '\(fixture.events.path)' '\(armedPath)' '\(releasePath)' swiftpm-testing-helper",
            eventStream: true,
            setup:
                "mkfifo '\(releasePath)'; LANE_WATCHDOG_ARM_PATH='\(armedPath)'; swift_test_watchdog_timeout_status() { return 1; }; "
        )
        #expect(result.output.contains("STATUS=124"), Comment(rawValue: result.output))
        #expect(
            result.output.contains(
                "failing_test=AgentStudioTests.Xcode27EventStreamEvidenceScratchTests/recordsFailure()"),
            Comment(rawValue: result.output))
        #expect(result.output.contains("stream=truncated"), Comment(rawValue: result.output))
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.root.appending(path: "evidence"), includingPropertiesForKeys: nil)
        let retained = try #require(files.first { $0.path.hasSuffix(".events.jsonl") })
        #expect(try Data(contentsOf: retained) == Data(contentsOf: fixture.events))
    }

    @Test(
        "missing facts readers fail closed only for real event invocations",
        arguments: ["swift-test-invocation-receipts.sh", "swift-test-invocation-receipts.pl"], [0, 7])
    func unavailableReaderCannotPass(missingReader: String, status: Int) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let helper = try fixture.copyRunnerSupport(omitting: missingReader)
        let result = try await fixture.run(
            "/bin/bash -c 'exit \(status)' swiftpm-testing-helper", eventStream: true, helper: helper)
        #expect(result.output.contains("STATUS=\(status == 0 ? 1 : status)"), Comment(rawValue: result.output))
        #expect(result.output.contains("reason=facts_reader_unavailable"), Comment(rawValue: result.output))
    }
}

func writeCapturedInvocation(
    _ fixture: InvocationReceiptFixture, selecting testName: String, closingRun: Bool = true,
    repeatIssue: Bool = false, extraRecords: Int = 0
) throws {
    let source = try String(
        contentsOfFile: "Tests/AgentStudioTests/Scripts/Fixtures/xcode27-event-stream-v6.3.jsonl", encoding: .utf8)
    let rows = try source.split(separator: "\n").map { line -> [String: Any] in
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    let runStart = try #require(rows.first { ($0["payload"] as? [String: Any])?["kind"] as? String == "runStarted" })
    let runEnd = try #require(rows.first { ($0["payload"] as? [String: Any])?["kind"] as? String == "runEnded" })
    let selected = rows.filter {
        let payload = $0["payload"] as? [String: Any]
        return (payload?["testID"] as? String ?? payload?["id"] as? String ?? "").contains(testName)
    }
    var records = [runStart] + selected
    if repeatIssue,
        let issue = selected.first(where: { ($0["payload"] as? [String: Any])?["kind"] as? String == "issueRecorded" })
    {
        records.append(issue)
    }
    records.append(
        contentsOf: Array(repeating: ["kind": "event", "payload": ["kind": "planStepStarted"]], count: extraRecords))
    if closingRun { records.append(runEnd) }
    try fixture.writeEvents(records)
}
