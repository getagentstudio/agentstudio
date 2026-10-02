import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Swift lane invocation receipts")
struct SwiftLaneInvocationReceiptTests {
    @Test(
        "missing receipt support is visible and never changes command status",
        arguments: ["swift-test-invocation-receipts.sh", "swift-test-invocation-receipts.pl"], [0, 7])
    func missingReceiptSupportIsFailOpen(missingHelper: String, status: Int) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let helper = try fixture.copyRunnerSupport(omitting: missingHelper)
        let result = try await fixture.run("/bin/bash -c 'exit \(status)'", helper: helper)

        #expect(result.output.contains("STATUS=\(status)"), Comment(rawValue: result.output))
        #expect(result.record["command_status"] as? Int == status)
        #expect(result.output.contains("invocation_observation=unavailable"))
        #expect(result.output.contains("receipt support could not be loaded"))
        #expect(!result.output.contains("command not found"))
    }

    @Test("every command gets resource fields with honest coverage")
    func commandHasResourceFields() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let result = try await fixture.run("/bin/bash -c 'exit 7'")
        #expect(result.output.contains("STATUS=7"))
        #expect(try #require(result.record["wall_seconds"] as? Double) >= 0)
        #expect(try #require(result.record["user_cpu_seconds"] as? Double) >= 0)
        #expect(try #require(result.record["sys_cpu_seconds"] as? Double) >= 0)
        #expect(try #require(result.record["max_rss_bytes"] as? Int) > 0)
        #expect(result.record["resource_source"] as? String == "bsd_time")
        #expect(result.record["resource_coverage"] as? String == "command_pipeline_reaped_tree")
    }

    @Test("issue records join only the test's outstanding waits at that instant")
    func issueJoinsExactTestAndTime() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let testID = "Fixture.Suite/normal()"
        try fixture.writeEvents([
            testDefinition(testID), testDefinition("Fixture.Suite/other()"),
            event("testStarted", testID, 100), event("testStarted", "Fixture.Suite/other()", 100.5),
            event("issueRecorded", testID, 102), event("testEnded", testID, 103),
            event("testEnded", "Fixture.Suite/other()", 103),
        ])
        try fixture.writeHeld([
            fact("expecting\tfact-1\trefreshClosed\tscope\tsite\tfile:1", testID, 101),
            fact("expecting\tfuture\tlaterClosed\tscope\tsite\tfile:2", testID, 104),
            fact("expecting\tother\totherClosed\tscope\tsite\tfile:3", "Fixture.Suite/other()", 101),
        ])
        let result = try await fixture.runFixtureStreams()
        let issues = try #require(result.record["issue_annotations"] as? [[String: Any]])
        let issue = try #require(issues.first)
        #expect(issues.count == 1)
        #expect(issue["test_id"] as? String == testID)
        #expect(issue["start_to_issue_seconds"] as? Double == 2)
        #expect(issue["concurrently_announced_tests"] as? Int == 2)
        #expect(issue["wait_status"] as? String == "outstanding")
        #expect(issue["attribution"] as? String == "exact_test_and_time")
        let waits = try #require(issue["waits"] as? [[String: Any]])
        #expect(waits.count == 1)
        #expect(waits.first?["id"] as? String == "fact-1")
        #expect(result.output.contains("issue_wait_annotation"))
    }

    @Test("a cancelled first-arrival settles only its own waiter")
    func cancellationEndsObservedWait() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let testID = "Fixture.Suite/cancelled()"
        try fixture.writeEvents([
            testDefinition(testID), event("testStarted", testID, 100), event("issueRecorded", testID, 102),
        ])
        try fixture.writeHeld([
            fact("waiting\tstep-1\tstep\tsite", testID, 101, waiterID: 1),
            fact("wait_settled\tstep-1\t1\tcancelled", testID, 101.5, waiterID: 1),
        ])
        let result = try await fixture.runFixtureStreams()
        let issue = try #require((result.record["issue_annotations"] as? [[String: Any]])?.first)
        #expect(issue["wait_status"] as? String == "none")
        #expect((issue["waits"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("parameterized attribution retains all test-wide candidates")
    func parameterizedWaitsRemainPartial() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let testID = "Fixture.Suite/parameterized()"
        try fixture.writeEvents([
            testDefinition(testID, parameterized: true), event("testStarted", testID, 100),
            event("testCaseStarted", testID, 100.1, caseID: "case-1"),
            event("testCaseStarted", testID, 100.2, caseID: "case-2"),
            event("issueRecorded", testID, 102),
        ])
        try fixture.writeHeld([
            fact("waiting\tstep-1\tone\tsite", testID, 101, waiterID: 1, parameterized: true),
            fact("expecting\tfact-1\tclose\tscope\tsite\tfile:1", testID, 101.1, parameterized: true),
        ])
        let result = try await fixture.runFixtureStreams()
        let issue = try #require((result.record["issue_annotations"] as? [[String: Any]])?.first)
        #expect(issue["attribution"] as? String == "parameterized_test_and_time")
        #expect(issue["running_parameterized_cases"] as? Int == 2)
        #expect((issue["waits"] as? [[String: Any]])?.count == 2)
        #expect(result.output.contains("one of these 2 cases' waits"))
    }

    @Test("later settlement changes only later issue annotations")
    func issueHistoryKeepsClosingBoundary() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let testID = "Fixture.Suite/history()"
        try fixture.writeEvents([
            testDefinition(testID), event("testStarted", testID, 100),
            event("issueRecorded", testID, 102), event("issueRecorded", testID, 104),
        ])
        try fixture.writeHeld([
            fact("expecting\tfact-1\tclose\tscope\tsite\tfile:1", testID, 101),
            fact("settled\tfact-1\tmatched", testID, 103),
        ])
        let result = try await fixture.runFixtureStreams()
        let issues = try #require(result.record["issue_annotations"] as? [[String: Any]])
        #expect(issues.count == 2)
        #expect(issues[0]["wait_status"] as? String == "outstanding")
        #expect(issues[1]["wait_status"] as? String == "none")
    }

    @Test("an arrival closes only its own step and partial final records are ignored")
    func stepArrivalDoesNotCloseOtherWait() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let testID = "Fixture.Suite/steps()"
        try fixture.writeEvents([
            testDefinition(testID), event("testStarted", testID, 100), event("issueRecorded", testID, 102),
        ])
        try fixture.writeHeld([
            fact("waiting\tstep-1\tone\tsite", testID, 101, waiterID: 1),
            fact("waiting\tstep-2\ttwo\tsite", testID, 101.1, waiterID: 2),
            fact("arrived\tstep-1\tone", testID, 101.5),
        ])
        let handle = try FileHandle(forWritingTo: fixture.held)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("wait_settled\tstep-2\t2\tcancelled".utf8))
        try handle.close()
        let result = try await fixture.runFixtureStreams()
        let issue = try #require((result.record["issue_annotations"] as? [[String: Any]])?.first)
        let waits = try #require(issue["waits"] as? [[String: Any]])
        #expect(waits.count == 1)
        #expect(waits.first?["id"] as? String == "step-2")
        #expect(result.record["announced_tests"] as? Int == 1)
        #expect(result.record["started_parameterized_cases"] as? Int == 0)
        #expect(result.record["event_coverage"] as? String == "v0_parameterized_case_subset")
    }

    @Test("an unavailable or legacy-only harness log never claims no outstanding wait")
    func unavailableLogRemainsUnknown() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let testID = "Fixture.Suite/unknown()"
        try fixture.writeEvents([
            testDefinition(testID), event("testStarted", testID, 100), event("issueRecorded", testID, 102),
        ])
        try "waiting\tstep-1\tlegacy\tsite\n".write(to: fixture.held, atomically: true, encoding: .utf8)
        let result = try await fixture.runFixtureStreams()
        let issue = try #require((result.record["issue_annotations"] as? [[String: Any]])?.first)
        #expect(issue["wait_status"] as? String == "unavailable")
    }
}

@Suite("Swift lane resource table")
struct SwiftLaneResourceTableTests {
    @Test("the lane table includes only its own invocations and preserves unknown fields")
    func tableExcludesHistoricalSidecars() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let old = fixture.root.appending(path: "historical.timing.json")
        let current = fixture.root.appending(path: "current.timing.json")
        try JSONSerialization.data(withJSONObject: ["label": "stale", "wall_seconds": 999]).write(to: old)
        try JSONSerialization.data(withJSONObject: [
            "label": "current", "wall_seconds": 1.5, "resource_coverage": "unavailable",
        ]).write(to: current)
        let result = try await runCommandToExit(
            command: "/bin/bash",
            arguments: [
                "-c",
                "LOG_PREFIX=table; source scripts/swift-test-helpers.sh; "
                    + "swift_test_f2_begin_lane_accounting; swift_test_f2_attach_receipt '\(current.path)'; "
                    + "rm -f '\(current.path)'; swift_test_f2_report_resource_table",
            ])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("invocation_resource_row current|1.5|unavailable"))
        #expect(!result.stdout.contains("stale"))
    }

    @Test("commands do not inherit the outer lane's private resource registry")
    func commandCannotPolluteOuterRegistry() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let list = fixture.root.appending(path: "outer-list")
        let result = try await fixture.run(
            "/bin/bash -c 'if [ -n \"${SWIFT_TEST_F2_SIDECAR_LIST:-}\" ]; then exit 7; fi'",
            setup: "export SWIFT_TEST_F2_SIDECAR_LIST='\(list.path)'; ")
        #expect(result.output.contains("STATUS=0"))
        let rows = try String(contentsOf: list, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 1)
    }

}

@Suite("Swift lane resource wrapper")
struct SwiftLaneResourceWrapperTests {
    @Test("the timed process group preserves real command exit and signal statuses", arguments: [0, 7, 124, 139, 143])
    func preservesStatuses(status: Int) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let timer = try fixture.makeTimer()
        let command: String
        switch status {
        case 139: command = "/bin/bash -c 'ulimit -c 0; kill -SEGV $$'"
        case 143: command = "/bin/bash -c 'kill -TERM $$'"
        default: command = "/bin/bash -c 'exit \(status)'"
        }
        let result = try await fixture.run(command, setup: "SWIFT_TEST_RESOURCE_TIMER='\(timer.path)'; ")
        #expect(result.output.contains("STATUS=\(status)"))
        #expect(result.record["command_status"] as? Int == status)
        #expect(result.record["resource_source"] as? String == "bsd_time")
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "timer.pid").path))
    }

    @Test("missing resource tools leave the command verdict unchanged and measurements unavailable")
    func absentTimerIsFailOpen() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let result = try await fixture.run(
            "/bin/bash -c 'exit 7'", setup: "SWIFT_TEST_RESOURCE_TIMER='\(fixture.root.path)/missing'; ")
        #expect(result.output.contains("STATUS=7"))
        #expect(result.record["resource_source"] is NSNull)
        #expect(result.record["user_cpu_seconds"] is NSNull)
        #expect(result.record["max_rss_bytes"] is NSNull)
        #expect(result.record["resource_coverage"] as? String == "unavailable")
    }

    @Test("the timer belongs to the reaped group and never survives its timeout")
    func timeoutReapsTimer() async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let timer = try fixture.makeTimer()
        let release = fixture.root.appending(path: "release.fifo")
        let arm = fixture.root.appending(path: "armed")
        let result = try await fixture.run(
            "/usr/bin/perl -e '\u{0024}SIG{TERM}=q{IGNORE}; open(my \u{0024}armed,q{>},shift) or die \u{0024}!; "
                + "close(\u{0024}armed); print qq{PARKED\\n}; open(my \u{0024}release,q{<},shift) or die \u{0024}!; <\u{0024}release>;' "
                + "'\(arm.path)' '\(release.path)'",
            setup: "SWIFT_TEST_RESOURCE_TIMER='\(timer.path)'; LANE_WATCHDOG_ARM_PATH='\(arm.path)'; "
                + "mkfifo '\(release.path)'; swift_test_watchdog_timeout_status() { return 1; }; ")
        #expect(result.output.contains("STATUS=124"))
        #expect(result.record["timed_out"] as? Bool == true)
        let timerPID = try String(contentsOf: fixture.root.appending(path: "timer.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = try await runCommandToExit(
            command: "/usr/bin/perl", arguments: ["-e", "exit(kill(0,shift) ? 7 : 0)", timerPID])
        #expect(probe.exitCode == 0)
        #expect(result.record["resource_coverage"] as? String == "unavailable_after_reap")
    }
}

private struct InvocationReceiptFixture {
    let root: URL
    var events: URL { root.appending(path: "fixture.events") }
    var held: URL { root.appending(path: "fixture.held") }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "f2-invocation-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeTimer() throws -> URL {
        let timer = root.appending(path: "timer")
        try
            "#!/bin/bash\nprintf '%s\\n' \u{0024}\u{0024} > '\(root.path)/timer.pid'\nexec /usr/bin/time \"\u{0024}@\"\n"
            .write(to: timer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: timer.path)
        return timer
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func copyRunnerSupport(omitting missingHelper: String) throws -> URL {
        let scripts = root.appending(path: "scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in [
            "swift-test-helpers.sh", "xcb-helpers.sh", "swift-package-sandbox.sh",
            "filter-known-linker-warnings.sh", "swift-compilation-policy.sh",
            "swift-test-output-relay.pl",
            "swift-test-invocation-receipts.sh", "swift-test-invocation-receipts.pl",
        ] where name != missingHelper {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "scripts/\(name)"), to: scripts.appending(path: name))
        }
        return scripts.appending(path: "swift-test-helpers.sh")
    }

    func writeEvents(_ records: [[String: Any]]) throws {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(Data("\n".utf8))
        }
        try data.write(to: events)
    }

    func writeHeld(_ records: [String]) throws {
        try (records.joined(separator: "\n") + "\n").write(to: held, atomically: true, encoding: .utf8)
    }

    func runFixtureStreams() async throws -> (output: String, record: [String: Any]) {
        // The same append/flush boundaries as a real test process; the synthetic
        // stream uses its own CLOCK_UPTIME_RAW fixture epoch, no real-time wait.
        try await run(
            "/bin/bash -c 'cp \"$1\" \"${@: -1}\"; cp \"$2\" \"$AGENTSTUDIO_HELD_STEP_LOG\"' fixture "
                + "'\(events.path)' '\(held.path)'", eventStream: true)
    }

    func run(_ command: String, eventStream: Bool = false, setup: String = "", helper: URL? = nil) async throws -> (
        output: String, record: [String: Any]
    ) {
        let result = try await runCommandToExit(
            command: "/bin/bash",
            arguments: [
                "-c",
                "LOG_PREFIX=f2; export LANE_EVENT_STREAM_DIR='\(root.path)/evidence'; "
                    + (helper == nil
                        ? ""
                        : "unset SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH; ")
                    + "source '\(helper?.path ?? "scripts/swift-test-helpers.sh")'; "
                    + (eventStream ? "swift_test_command_accepts_event_stream() { return 0; }; " : "")
                    + setup
                    + "set +e; run_swift_with_timeout fixture 60 \(command) || status=$?; echo STATUS=${status:-0}",
            ])
        #expect(result.exitCode == 0)
        let evidence = root.appending(path: "evidence")
        let files = try FileManager.default.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil)
        let path = try #require(files.first { $0.lastPathComponent.hasSuffix(".timing.json") })
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        return (result.stdout + result.stderr, record)
    }
}

private func testDefinition(_ identifier: String, parameterized: Bool = false) -> [String: Any] {
    ["kind": "test", "payload": ["id": identifier, "kind": "function", "isParameterized": parameterized]]
}

private func event(_ kind: String, _ identifier: String, _ instant: Double, caseID: String? = nil) -> [String: Any] {
    var payload: [String: Any] = ["kind": kind, "testID": identifier, "instant": ["absolute": instant]]
    if let caseID { payload["_testCase"] = ["id": caseID] }
    return ["kind": "event", "payload": payload]
}

private func fact(
    _ payload: String, _ identifier: String, _ instant: Double, waiterID: Int? = nil, parameterized: Bool = false
) throws -> String {
    let metadata: [String: Any] = [
        "clockDomain": "CLOCK_UPTIME_RAW", "seconds": Int(instant),
        "nanoseconds": Int((instant - Double(Int(instant))) * 1_000_000_000),
        "testID": identifier, "caseID": NSNull(), "parameterized": parameterized,
        "waiterID": waiterID.map { $0 as Any } ?? NSNull(),
    ]
    let json = try JSONSerialization.data(withJSONObject: metadata)
    return payload + "\t" + (try #require(String(bytes: json, encoding: .utf8)))
}
