import AgentStudioInfrastructure
import Foundation
import Testing

private enum WebKitConsoleLockScenario: String, CaseIterable, Sendable {
    case locked, unlocked, missingProperty, commandFailed, conflictingSessions

    var expectedState: String {
        switch self {
        case .locked: "Yes"
        case .unlocked: "No"
        case .missingProperty, .commandFailed, .conflictingSessions: "unavailable"
        }
    }
}

// This fixture replaces only the host diagnostic command; it executes the real
// report helper with the same Bash 3.2 entry point as the lane.
private let webKitConsoleLockReportingProbe = #"""
    set -euo pipefail
    source scripts/swift-test-helpers.sh
    LOG_PREFIX=go26-fixture
    ioreg() {
      [ "$*" = '-n Root -d1' ] || { echo INVALID_IOREG_ARGUMENTS >&2; return 91; }
      case "$GO26_CONSOLE_SCENARIO" in
        locked) printf '%s\n' '"IOConsoleUsers" = ({"IOConsoleLocked"=Yes,"UserIsActive"=0})' ;;
        unlocked) printf '%s\n' '"IOConsoleLocked" = No' ;;
        missingProperty) printf '%s\n' '"OtherRootProperty" = Yes' ;;
        commandFailed) printf '%s\n' '"IOConsoleLocked" = Yes'; return 7 ;;
        conflictingSessions) printf '%s\n' '"IOConsoleUsers" = ({"IOConsoleLocked"=Yes},{"IOConsoleLocked"=No})' ;;
      esac
    }
    swift_test_report_webkit_console_lock 'WebKitSerializedTests/FixtureSuite' start
    report_failed_command() {
      local command_status=0
      /bin/bash -c 'exit 37' || command_status=$?
      swift_test_report_webkit_console_lock 'requested swift test args: --filter WebKitSerializedTests/FixtureSuite' timeout
      return "$command_status"
    }
    observed_status=0
    report_failed_command || observed_status=$?
    printf 'COMMAND_STATUS=%s\n' "$observed_status"
    [ "$observed_status" -eq 37 ]
    swift_test_report_webkit_console_lock 'native-concurrent fast non-WebKit suites' start
    """#

// The real wrapper owns launch, timeout disposition, output and reaping. A FIFO
// announces the held child; only the watchdog's time input is advanced. The
// diagnostic changes from unlocked to locked while that child remains held.
private let webKitConsoleLockTimeoutProbe = #"""
    set -euo pipefail
    source scripts/swift-test-helpers.sh
    fixture_directory='__FIXTURE_DIRECTORY__'
    mkdir -p "$fixture_directory/build" "$fixture_directory/events"
    LOG_PREFIX=go26-timeout
    BUILD_PATH="$fixture_directory/build"
    LANE_EVENT_STREAM_DIR="$fixture_directory/events"
    export LOG_PREFIX BUILD_PATH LANE_EVENT_STREAM_DIR
    mkfifo "$fixture_directory/held" "$fixture_directory/release"
    exec 81<>"$fixture_directory/held" 82<>"$fixture_directory/release"
    export GO26_HELD_FIFO="$fixture_directory/held" GO26_RELEASE_FIFO="$fixture_directory/release"
    swift_test_begin_active_command_groups
    trap 'exec 81>&- 82>&-; swift_test_cleanup_active_command_groups_directory' EXIT
    _xcb_pipe_cmd() { echo cat; }
    console_state=No
    ioreg() { printf '"IOConsoleLocked" = %s\n' "$console_state"; }
    watchdog_epoch=0
    date() {
      if [ "${1:-}" = +%s ]; then printf '%s\n' "$watchdog_epoch"; else /bin/date "$@"; fi
    }
    sleep() {
      local held_fact
      IFS= read -r held_fact <&81
      [ "$held_fact" = CHILD_HELD ]
      console_state=Yes
      watchdog_epoch=600
    }
    # Process diagnostics are outside this claim; never sample the owner's apps.
    print_timeout_process_diagnostics() { printf 'FIXTURE_DIAGNOSTICS\n'; }
    # End the deliberately held dependency and join the real process. The test
    # replaces the runner's grace-period sampling with this exact closing fact.
    swift_test_wait_for_command_group_exit() {
      printf 'RELEASE\n' >&82
      local child_status=0
      wait "$1" || child_status=$?
      printf 'CHILD_REAPED=%s\n' "$child_status"
      [ "$child_status" -eq 0 ]
    }
    status=0
    run_swift_with_timeout 'WebKitSerializedTests/ConsoleLockFixture' 600 /usr/bin/perl -e '
      $SIG{INT} = "IGNORE";
      open my $held, ">", $ENV{GO26_HELD_FIFO} or die $!;
      print {$held} "CHILD_HELD\n";
      close $held or die $!;
      open my $release, "<", $ENV{GO26_RELEASE_FIFO} or die $!;
      my $ending = <$release>;
      die "unexpected closing fact" unless $ending eq "RELEASE\n";
      close $release or die $!;
      exit 0;
    ' || status=$?
    printf 'COMMAND_STATUS=%s\n' "$status"
    [ "$status" -eq 124 ]
    """#

extension SwiftLaneRunnerReportTests {
    @Test("WebKit console-lock reports keep the command verdict", arguments: WebKitConsoleLockScenario.allCases)
    private func webKitConsoleLockReportsKeepCommandVerdict(scenario: WebKitConsoleLockScenario) async throws {
        var environment = swiftTaskFixtureEnvironment()
        environment["GO26_CONSOLE_SCENARIO"] = scenario.rawValue
        let result = try await runLaneScriptBash(webKitConsoleLockReportingProbe, environment: environment)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(
            result.output.contains(
                "[go26-fixture] lane-report console_locked=\(scenario.expectedState) phase=start label=WebKitSerializedTests/FixtureSuite"
            ))
        #expect(
            result.output.contains(
                "[go26-fixture] lane-report console_locked=\(scenario.expectedState) phase=timeout label=requested swift test args: --filter WebKitSerializedTests/FixtureSuite"
            ))
        #expect(result.output.contains("COMMAND_STATUS=37"))
        #expect(!result.output.contains("INVALID_IOREG_ARGUMENTS"))
        #expect(!result.output.contains("label=native-concurrent fast non-WebKit suites"))
        #expect(result.output.components(separatedBy: "lane-report console_locked=").count - 1 == 2)
    }

    @Test("WebKit console-lock reporting is wired before launch and at timeout")
    func webKitConsoleLockReportingIsWiredBeforeLaunchAndAtTimeout() throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let startCall = try #require(
            helperScript.range(of: "swift_test_report_webkit_console_lock \"$label\" start"))
        let launchCall = try #require(helperScript.range(of: "if ! swift_test_f2_launch_command_group"))
        let timeoutBranch = try #require(helperScript.range(of: "if [ \"$timed_out\" -eq 1 ]; then"))
        let timeoutCall = try #require(
            helperScript.range(of: "swift_test_report_webkit_console_lock \"$label\" timeout"))
        let timeoutReturn = try #require(
            helperScript.range(of: "return 124", range: timeoutBranch.lowerBound..<helperScript.endIndex))
        #expect(startCall.lowerBound < launchCall.lowerBound)
        #expect(timeoutBranch.lowerBound < timeoutCall.lowerBound)
        #expect(timeoutCall.lowerBound < timeoutReturn.lowerBound)
    }

    @Test("WebKit timeout reports a console lock that changed after launch without changing exit 124")
    func webKitTimeoutReportsConsoleLockChangeWithoutChangingVerdict() async throws {
        let fixtureDirectory = NSTemporaryDirectory() + "agentstudio-console-lock-timeout-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }
        let command = webKitConsoleLockTimeoutProbe.replacingOccurrences(
            of: "__FIXTURE_DIRECTORY__", with: fixtureDirectory)
        let result = try await runLaneScriptBash(command, innerWatchdog: .armed)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(
            result.output.contains(
                "lane-report console_locked=No phase=start label=WebKitSerializedTests/ConsoleLockFixture"))
        #expect(
            result.output.contains(
                "lane-report console_locked=Yes phase=timeout label=WebKitSerializedTests/ConsoleLockFixture"))
        #expect(result.output.contains("CHILD_REAPED=0"))
        #expect(result.output.contains("COMMAND_STATUS=124"))
    }
}
