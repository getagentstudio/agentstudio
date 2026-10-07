import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("CLI latency benchmark harness contracts")
struct CLILatencyBenchmarkScriptTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("both notice families measure the owned-pane cleanup path under the hook-or-notice budget")
    func noticeFamiliesAreMeasured() throws {
        let manifest = try object(Data(contentsOf: projectRoot.appending(path: "scripts/cli-latency-workloads.json")))
        let families = try #require(manifest["families"] as? [[String: Any]])
        for name in ["message", "done"] {
            let family = try #require(
                families.first { $0["name"] as? String == name }, "missing notice family: \(name)")
            #expect(family["budgetClass"] as? String == "hookOrNotice")
            #expect(family["fixtureRequirement"] as? String == "ownedPane")
            let arguments = try #require(family["argv"] as? [String])
            let toolingMethod = name == "message" ? "session.message" : "session.report"
            #expect(arguments.first == name || arguments.first == toolingMethod)
        }
    }

    @Test("nearest-rank p95 distinguishes failure and incomplete measurement without elapsed-time assertions")
    func reportMathPinsVerdicts() async throws {
        let script = #"""
            use CLILatencyReport;
            use JSON::PP;
            my @samples = map { {'cli.call_total_ms' => $_, outcome => 'passed'} } 1..50;
            my $passed = CLILatencyReport::summarize_family('hook', 'hookOrNotice', \@samples);
            $samples[0]{outcome} = 'failed';
            my $failed = CLILatencyReport::summarize_family('hook', 'hookOrNotice', \@samples);
            pop @samples;
            my $partial = CLILatencyReport::summarize_family('hook', 'hookOrNotice', \@samples);
            my @slow = map { {'cli.call_total_ms' => 151, outcome => 'passed'} } 1..50;
            my $over = CLILatencyReport::summarize_family('hook', 'hookOrNotice', \@slow);
            print JSON::PP->new->encode({passed=>$passed, failed=>$failed, partial=>$partial, over=>$over});
            """#
        let output = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-I", projectRoot.appendingPathComponent("scripts").path, "-e", script],
            environment: ProcessInfo.processInfo.environment)
        #expect(output.terminationStatus == 0)
        let fields = try object(output.standardOutput)
        let passed = try #require(fields["passed"] as? [String: Any])
        let failed = try #require(fields["failed"] as? [String: Any])
        let partial = try #require(fields["partial"] as? [String: Any])
        let over = try #require(fields["over"] as? [String: Any])
        #expect(passed["p95Ms"] as? Int == 48)
        #expect(passed["verdict"] as? String == "PASS")
        #expect(failed["verdict"] as? String == "FAIL")
        #expect(failed["failedCalls"] as? Int == 1)
        #expect(partial["verdict"] as? String == "NOT MEASURED")
        #expect(over["verdict"] as? String == "FAIL")
    }

    @Test("a fixture with broader file permissions is refused before any CLI process")
    func refusesNonPrivateFixture() async throws {
        let fixture = try BenchmarkScriptFixture()
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.fixtureURL.path)
        let output = try await runHarness(fixture)
        #expect(output.terminationStatus != 0)
        let diagnostic = try #require(String(data: output.standardError, encoding: .utf8))
        #expect(diagnostic.contains("mode 0600"))
        #expect(!FileManager.default.fileExists(atPath: fixture.recordsURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.outputURL.path))
    }

    @Test("all families retain 50 full-process samples and cleanup, with credentials excluded from reports")
    func benchmarkRecordsEveryFamilyAndRedacts() async throws {
        let fixture = try BenchmarkScriptFixture()
        defer { fixture.cleanup() }
        let output = try await runHarness(fixture)
        let report = try object(Data(contentsOf: fixture.outputURL.appendingPathComponent("report.json")))
        let families = try #require(report["families"] as? [[String: Any]])
        #expect(families.count == 11)
        #expect(families.allSatisfy { $0["sampleCount"] as? Int == 50 })
        #expect(families.allSatisfy { $0["failedCalls"] as? Int == 0 })
        #expect(report["cleanup"] as? String == "closedOwnedPane")
        // Runtime duration is measured, never a correctness deadline. The
        // synthetic report test above owns exact budget-verdict arithmetic.
        let allFamiliesPassed = families.allSatisfy { $0["verdict"] as? String == "PASS" }
        #expect(report["verdict"] as? String == (allFamiliesPassed ? "PASS" : "FAIL"))
        #expect(output.terminationStatus == (allFamiliesPassed ? 0 : 1))
        let unmeasured = try #require(report["notMeasured"] as? [[String: Any]])
        #expect(unmeasured.map { $0["family"] as? String } == ["line", "title", "notify"])
        #expect(unmeasured.allSatisfy { $0["verdict"] as? String == "NOT MEASURED" })
        let samples = try String(
            contentsOf: fixture.outputURL.appendingPathComponent("samples.jsonl"), encoding: .utf8)
        #expect(samples.split(separator: "\n").count == 550)
        let saved = try String(contentsOf: fixture.outputURL.appendingPathComponent("report.json"), encoding: .utf8)
        let standardOutput = try #require(String(data: output.standardOutput, encoding: .utf8))
        for text in [saved, samples, standardOutput] {
            #expect(!text.contains(BenchmarkScriptFixture.fakeToken))
            #expect(!text.contains(BenchmarkScriptFixture.fakeSocket))
            #expect(!text.contains(fixture.paneId.uuidString))
            #expect(!text.contains("session_id"))
        }
        let calls = try String(contentsOf: fixture.recordsURL, encoding: .utf8)
        #expect(calls.contains("hook SessionStart"))
        #expect(calls.contains("hook UserPromptSubmit"))
        #expect(calls.contains("pane.close"))
        #expect(calls.split(separator: "\n").filter { $0 == "notice store=set" }.count == 102)
    }

    @Test("zero-exit fail-open hooks with diagnostics fail measurement and still close the owned pane")
    func hookFailuresCannotPass() async throws {
        let fixture = try BenchmarkScriptFixture(failingHooks: true)
        defer { fixture.cleanup() }
        let output = try await runHarness(fixture)
        #expect(output.terminationStatus == 1)
        let report = try object(Data(contentsOf: fixture.outputURL.appendingPathComponent("report.json")))
        let families = try #require(report["families"] as? [[String: Any]])
        // The hook warmup fails, so it cannot manufacture a p95 from failures
        // or let the remaining families claim a passing measurement.
        let hook = try #require(families.first { $0["family"] as? String == "hook" })
        #expect(hook["verdict"] as? String == "NOT MEASURED")
        #expect(report["failureStage"] as? String == "hook")
        #expect(report["failurePhase"] as? String == "warmup")
        #expect(report["failureClass"] as? String == "diagnosticOutput")
        #expect(report["cleanup"] as? String == "closedOwnedPane")
        #expect(report["verdict"] as? String == "FAIL")
    }

    @Test("command warmup failures report only a closed reason class, never raw diagnostic or argv values")
    func commandFailureClassIsRedacted() async throws {
        let fixture = try BenchmarkScriptFixture(failingCommand: true)
        defer { fixture.cleanup() }
        let output = try await runHarness(fixture)
        #expect(output.terminationStatus == 1)
        let reportURL = fixture.outputURL.appendingPathComponent("report.json")
        let reportData = try Data(contentsOf: reportURL)
        let report = try object(reportData)
        #expect(report["failureStage"] as? String == "command")
        #expect(report["failurePhase"] as? String == "warmup")
        #expect(report["failureClass"] as? String == "argumentsRejected")
        #expect(report["failureExitCode"] as? Int == 1)
        #expect(report["failureSignal"] as? Int == 0)
        #expect(report["cleanup"] as? String == "closedOwnedPane")
        #expect(report["verdict"] as? String == "FAIL")
        let fields = try #require(report["families"] as? [[String: Any]])
        let command = try #require(fields.first { $0["family"] as? String == "command" })
        #expect(command["verdict"] as? String == "NOT MEASURED")
        let saved = try #require(String(data: reportData, encoding: .utf8))
        let samples = try String(
            contentsOf: fixture.outputURL.appendingPathComponent("samples.jsonl"), encoding: .utf8)
        let standardOutput = try #require(String(data: output.standardOutput, encoding: .utf8))
        #expect(standardOutput.contains("failure stage=command phase=warmup class=argumentsRejected"))
        for text in [saved, samples, standardOutput] {
            #expect(!text.contains("PRIVATE-DIAGNOSTIC-SENTINEL"))
            #expect(!text.contains(fixture.paneId.uuidString))
            #expect(!text.contains("scrollToBottom"))
            #expect(!text.contains("--command-id"))
            #expect(!text.contains(BenchmarkScriptFixture.fakeToken))
            #expect(!text.contains(BenchmarkScriptFixture.fakeSocket))
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func runHarness(_ fixture: BenchmarkScriptFixture) async throws -> ExitedProcessOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTSTUDIO_CLI_BENCHMARK_OUTPUT"] = fixture.outputURL.path
        return try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                projectRoot.appendingPathComponent("scripts/benchmark-cli-latency.sh").path, fixture.fixtureURL.path,
            ],
            environment: environment)
    }
}

private struct BenchmarkScriptFixture {
    static let fakeToken = "private-benchmark-test-credential"
    static let fakeSocket = "/private/test-only-cli-latency.sock"
    let root: URL
    let paneId: UUID
    var fixtureURL: URL { root.appendingPathComponent("fixture.json") }
    var recordsURL: URL { root.appendingPathComponent("calls.txt") }
    var outputURL: URL { root.appendingPathComponent("results") }

    init(failingHooks: Bool = false, failingCommand: Bool = false) throws {
        paneId = UUIDv7.generate()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-latency-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cliURL = root.appendingPathComponent("agentstudio")
        let escrowURL = root.appendingPathComponent("escrow.json")
        let runtimeId = UUIDv7.generate().uuidString
        let cli = #"""
            #!/usr/bin/perl
            use strict;
            use warnings;
            use JSON::PP;
            my $method = $ARGV[0] // '';
            open my $calls, '>>', $ENV{BENCHMARK_TEST_RECORDS} or die "fixture records";
            print {$calls} $method eq 'hook' ? "hook $ARGV[2]\n" : "$method\n";
            if ($method eq 'message' || $method eq 'done' || $method eq 'session.message' || $method eq 'session.report') {
                print {$calls} 'notice store=' . ($ENV{AGENTSTUDIO_CLI_STORE} ? 'set':'absent') . "\n";
            }
            close $calls;
            my $json = JSON::PP->new;
            my $pane = $ENV{BENCHMARK_TEST_PANE};
            my $runtime = $ENV{BENCHMARK_TEST_RUNTIME};
            my $state = "$ENV{BENCHMARK_TEST_RECORDS}.state";
            if ($method eq 'hook') {
                if ($ARGV[2] eq 'UserPromptSubmit') { open my $out, '>', $state; print {$out} 'live'; close $out; }
                if ($ARGV[2] eq 'PreToolUse' && $ENV{BENCHMARK_TEST_FAIL_HOOK}) { print STDERR "not delivered\n"; }
                exit 0;
            }
            my $result = {};
            if ($method eq 'help') { print "local help\n"; exit 0; }
            if ($method eq 'system.identify') { $result = {runtimeId=>$runtime, accessMode=>'agentStudioOnly'}; }
            if ($method eq 'auth.status') { $result = {authenticated=>JSON::PP::true, runtimeId=>$runtime, accessMode=>'agentStudioOnly'}; }
            if ($method eq 'pane.snapshot') { $result = {pane=>{id=>$pane}}; }
            if ($method eq 'session.query') { $result = {paneId=>$pane, sourceHealth=>(-e $state ? 'live':'unbound'), state=>'running', origin=>'reported'}; }
            if ($method eq 'terminal.status') { $result = {isReady=>JSON::PP::true, paneId=>$pane}; }
            if ($method eq 'command.execute') {
                if ($ENV{BENCHMARK_TEST_FAIL_COMMAND} || ($ARGV[1] // '') ne '--command-id' || ($ARGV[2] // '') ne 'scrollToBottom') {
                    print STDERR $json->encode({reason=>'invalidParams', expected=>'PRIVATE-DIAGNOSTIC-SENTINEL', commandId=>$pane});
                    exit 1;
                }
                $result = {kind=>'applied'};
            }
            print $json->encode($result);
            """#
        try cli.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cliURL.path)
        try JSONSerialization.data(withJSONObject: [
            "runtimeId": runtimeId, "socketPath": Self.fakeSocket, "token": "private-test-debug-credential",
        ]).write(to: escrowURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: escrowURL.path)
        try JSONSerialization.data(withJSONObject: [
            "paneId": paneId.uuidString, "workspaceWindowId": UUIDv7.generate().uuidString,
            "debugEscrowPath": escrowURL.path,
            "environment": [
                "AGENTSTUDIO_CLI": cliURL.path,
                "AGENTSTUDIO_PANE_TOKEN": Self.fakeToken,
                "AGENTSTUDIO_IPC_SOCKET": Self.fakeSocket,
                "AGENTSTUDIO_CLI_STORE": root.appendingPathComponent("cli.sqlite").path,
                "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
                "BENCHMARK_TEST_RECORDS": recordsURL.path,
                "BENCHMARK_TEST_PANE": paneId.uuidString,
                "BENCHMARK_TEST_RUNTIME": runtimeId,
                "BENCHMARK_TEST_FAIL_HOOK": failingHooks ? "1" : "0",
                "BENCHMARK_TEST_FAIL_COMMAND": failingCommand ? "1" : "0",
            ],
        ]).write(to: fixtureURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixtureURL.path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
