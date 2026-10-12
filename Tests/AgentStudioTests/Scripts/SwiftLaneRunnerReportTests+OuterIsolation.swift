import AgentStudioInfrastructure
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

enum OuterStateFixtureLauncher: String, CaseIterable, Sendable {
    case laneScript
    case subprocess
    case command
    case buildSlot

    func run(
        _ command: String, environment: [String: String] = [:], inheritedEnvironment: [String: String]? = nil
    ) async throws -> LaneScriptBashResult {
        switch self {
        case .laneScript:
            return try await runLaneScriptBash(
                command, environment: environment, inheritedEnvironment: inheritedEnvironment)
        case .subprocess:
            let result = try await runProcessToExit(
                executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", command], environment: environment,
                inheritedEnvironment: inheritedEnvironment)
            guard let output = String(bytes: result.standardOutput + result.standardError, encoding: .utf8) else {
                throw OuterStateFixtureLaunchError.invalidOutputEncoding
            }
            return LaneScriptBashResult(exitCode: result.terminationStatus, output: output)
        case .command:
            let result = try await runCommandToExit(
                command: "/bin/bash", arguments: ["-c", command], environment: environment,
                inheritedEnvironment: inheritedEnvironment)
            return LaneScriptBashResult(exitCode: Int32(result.exitCode), output: result.stdout + result.stderr)
        case .buildSlot:
            let fixture = try SwiftBuildSlotFixture(inheritedEnvironment: inheritedEnvironment)
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let result = try await fixture.run(command, environment: environment)
            return LaneScriptBashResult(exitCode: result.exitCode, output: result.output)
        }
    }
}

private enum OuterStateFixtureLaunchError: Error {
    case invalidOutputEncoding
}

extension SwiftLaneRunnerReportTests {
    @Test("fixture cleanup cannot signal or delete outer lane state", arguments: OuterStateFixtureLauncher.allCases)
    private func fixtureCleanupCannotReachOuterLane(launcher: OuterStateFixtureLauncher) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "outer-lane-sentinel-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appending(path: "ready")
        let control = root.appending(path: "control")
        let signal = root.appending(path: "signal")
        let groups = root.appending(path: "groups")
        try FileManager.default.createDirectory(at: groups, withIntermediateDirectories: false)
        let fifoCreation = try await runCommandToExit(
            command: "/usr/bin/mkfifo", arguments: [ready.path, control.path])
        try #require(fifoCreation.exitCode == 0)
        // The sentinel is its own live group. READY and CLOSE are protocol facts;
        // an unexpected signal closes it with 71, so no timeout/poll is needed.
        async let sentinel = runProcessToExit(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-e",
                #"""
                setpgrp(0, 0) or die $!;
                my ($ready, $control, $signal) = @ARGV;
                my $caught = sub { open my $file, '>', $signal or die $!; print {$file} "SIGNAL\n"; close $file; exit 71; };
                $SIG{TERM} = $caught; $SIG{INT} = $caught; $SIG{HUP} = $caught; $SIG{USR1} = $caught;
                open my $release, '+<', $control or die $!;
                open my $announce, '>', $ready or die $!; print {$announce} "$$\n"; close $announce or die $!;
                my $ending = <$release>; die "missing CLOSE" unless defined $ending && $ending eq "CLOSE\n";
                close $release; exit 0;
                """#,
                ready.path,
                control.path,
                signal.path,
            ], environment: swiftTaskFixtureEnvironment())
        let announced = try await runCommandToExit(
            command: "/bin/bash",
            arguments: ["-c", "IFS= read -r sentinel_pid < '\(ready.path)'; printf '%s' \"$sentinel_pid\""])
        let sentinelPID = try #require(Int(announced.stdout))
        let registeredGroup = groups.appending(path: String(sentinelPID))
        try "outer registry entry\n".write(to: registeredGroup, atomically: true, encoding: .utf8)
        let outerFile = root.appending(path: "outer-state")
        let originalState = Data("outer state unchanged\n".utf8)
        try originalState.write(to: outerFile)
        var environment = swiftTaskFixtureEnvironment()
        for name in [
            "LANE_EVENT_STREAM_DIR", "LANE_TIMES_FILE", "LANE_TIMING_PHASE", "LANE_RECEIPT_HEAD_SHA",
            "SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE", "SWIFT_TEST_PEAK_ANNOUNCED_FILE", "SWIFT_TEST_PEAK_RUNNING_FILE",
            "SWIFT_TEST_F2_SIDECAR_LIST", "SWIFT_TEST_FACTS_FILE", "SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH",
            "SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH", "SWIFT_TEST_OUTPUT_RELAY_START_DIRECTORY",
            "SWIFT_TEST_HELPERS_PATH", "AGENTSTUDIO_HELD_STEP_LOG", "SWIFT_BUILD_SLOT_CLAIM_DIRECTORY",
        ] {
            environment[name] = outerFile.path
        }
        environment["SWIFT_TEST_ACTIVE_COMMAND_GROUPS_DIR"] = groups.path
        environment["SWIFT_TEST_ACTIVE_COMMAND_GROUPS_DIR_OWNED"] = "1"
        environment["SWIFT_TEST_ACTIVE_COMMAND_GROUPS_DIR_LANE"] = "1"
        environment["SWIFT_TEST_ACTIVE_ISOLATED_PIDS"] = String(sentinelPID)
        environment["CI"] = "true"
        environment["GITHUB_ACTIONS"] = "true"
        environment["SWIFT_BUILD_DIR"] = ".build-ci"
        let helperPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "scripts/swift-test-helpers.sh").path
        let fixture = try await launcher.run(
            #"""
            set -euo pipefail
            set +m
            source '\#(helperPath)'
            LOG_PREFIX=outer-state-probe
            swift_test_signal_active_command_groups USR1
            swift_test_terminate_active_isolated_suites
            swift_test_cleanup_active_command_groups_directory
            [ "$FIXTURE_CALLER_VALUE" = kept ]
            printf 'FIXTURE_CLOSED\n'
            """#, environment: ["FIXTURE_CALLER_VALUE": "kept"], inheritedEnvironment: environment)
        // O_RDWR prevents opening the writer from blocking if the bad fixture
        // already killed the reader. Awaiting sentinel supplies its closing fact.
        let closing = try await runCommandToExit(
            command: "/bin/bash", arguments: ["-c", "exec 8<>'\(control.path)'; printf 'CLOSE\\n' >&8; exec 8>&-"])
        let outer = try await sentinel
        #expect(fixture.exitCode == 0, Comment(rawValue: fixture.output))
        #expect(closing.exitCode == 0)
        #expect(outer.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: signal.path))
        #expect(FileManager.default.fileExists(atPath: registeredGroup.path))
        #expect(try Data(contentsOf: outerFile) == originalState)
    }

    @Test(
        "fixture shell owns its process group with job control disabled", arguments: OuterStateFixtureLauncher.allCases)
    private func fixtureShellOwnsProcessGroup(launcher: OuterStateFixtureLauncher) async throws {
        let result = try await launcher.run(
            #"""
            set +m
            printf 'PID=%s\n' "$$"
            /usr/bin/perl -e 'printf "PGID=%s\n", getpgrp(0)'
            """#, environment: swiftTaskFixtureEnvironment())
        let fields = Dictionary(
            uniqueKeysWithValues: result.output.split(separator: "\n").compactMap { line -> (String, Int)? in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let value = Int(parts[1]) else { return nil }
                return (String(parts[0]), value)
            })
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(fields["PID"] == fields["PGID"])
        #expect(fields["PGID"] != Int(getpgrp()))
    }
}
