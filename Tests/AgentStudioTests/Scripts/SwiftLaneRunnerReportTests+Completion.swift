import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

// Controls the race between the watchdog's liveness sample and its timeout
// decision. EOF is delivered through the real filter/relay while the child is
// parked; the next watchdog sample happens only after the tracked leader exits.
private let childExitDuringWatchdogSampleFixture = #"""
    #!/bin/bash
    set -euo pipefail
    source scripts/swift-test-helpers.sh
    fixture_directory='__FIXTURE_DIRECTORY__'
    export TQ14_EXPECTED_STATUS=__EXIT_STATUS__
    mkdir -p "$fixture_directory/build" "$fixture_directory/events"
    LOG_PREFIX=completion-order
    BUILD_PATH="$fixture_directory/build"
    LANE_EVENT_STREAM_DIR="$fixture_directory/events"
    export LOG_PREFIX BUILD_PATH LANE_EVENT_STREAM_DIR
    mkfifo "$fixture_directory/filtered" "$fixture_directory/release"
    export TQ14_RELEASE_FIFO="$fixture_directory/release" TQ14_FILTERED_FIFO="$fixture_directory/filtered"
    # The command closes stdout before parking, so real filtering observes EOF
    # (including the partial tail) while the tracked supervisor stays alive.
    tq14_filter() {
      /bin/bash scripts/filter-known-linker-warnings.sh
      printf 'FILTER_EOF\n' >"$TQ14_FILTERED_FIFO"
    }
    export -f tq14_filter
    _xcb_pipe_cmd() { echo tq14_filter; }
    # Keep the actual launcher/process group; wait only for the filter's EOF fact.
    eval "$(declare -f swift_test_f2_launch_command_group | sed '1s/swift_test_f2_launch_command_group/tq14_launch_command_group/')"
    swift_test_f2_launch_command_group() {
      tq14_launch_command_group "$@"
      local filtered_state
      IFS= read -r filtered_state <"$TQ14_FILTERED_FIFO"
      [ "$filtered_state" = FILTER_EOF ]
    }
    # These are controlled scheduling/clock inputs, not timed waits. First sample
    # establishes output progress. Second sample runs only after the real group exits.
    watchdog_sample=progress
    watchdog_epoch=0
    date() {
      if [ "${1:-}" = +%s ]; then printf '%s\n' "$watchdog_epoch"; else /bin/date "$@"; fi
    }
    sleep() {
      if [ "$watchdog_sample" = progress ]; then
        watchdog_sample=exit
      elif [ "$watchdog_sample" = exit ]; then
        watchdog_sample=closed
        printf 'EXIT_NOW\n' >"$TQ14_RELEASE_FIFO"
        local exited_status=0
        wait "$command_pid" || exited_status=$?
        printf 'LEADER_EXIT_OBSERVED=%s\n' "$exited_status" >&2
        [ "$exited_status" -eq "$TQ14_EXPECTED_STATUS" ]
        watchdog_epoch=20
      else
        printf 'UNEXPECTED_WATCHDOG_SAMPLE\n' >&2
        exit 94
      fi
    }
    status=0
    run_swift_with_timeout 'leader exits during watchdog sample' 20 /usr/bin/perl -e '
      binmode STDOUT;
      print "TESTS_PASSED\n", "partial tail";
      close STDOUT or die $!;
      close STDERR or die $!;
      open my $release, "<", $ENV{TQ14_RELEASE_FIFO} or die $!;
      <$release>;
      close $release;
      exit $ENV{TQ14_EXPECTED_STATUS};
    ' || status=$?
    printf 'FAIL_CHILD_STATUS=%s\n' "$status"
    [ "$status" -eq "$TQ14_EXPECTED_STATUS" ]
    """#

// A command that exits at once, run while the runner's own drain outlasts the
// inner bound (see laneRunnerStarvedDrainHook).
private let exitedCommandUnderStarvedRunnerFixture = #"""
    set -euo pipefail
    source scripts/swift-test-helpers.sh
    fixture_directory='__FIXTURE_DIRECTORY__'
    mkdir -p "$fixture_directory/build" "$fixture_directory/events"
    LOG_PREFIX=starved-runner
    BUILD_PATH="$fixture_directory/build"
    export LANE_EVENT_STREAM_DIR="$fixture_directory/events"
    swift_test_begin_active_command_groups
    trap swift_test_cleanup_active_command_groups_directory EXIT
    __STARVED_DRAIN_HOOK__
    status=0
    run_swift_with_timeout 'exited command' 20 /bin/bash -c 'exit 0' || status=$?
    printf 'EXITED_COMMAND_STATUS=%s\n' "$status"
    """#

extension SwiftLaneRunnerReportTests {
    @Test(
        "child completion wins over an expired watchdog sample after output EOF",
        arguments: [0, 7]
    )
    func childExitDuringWatchdogSamplePreservesStatus(exitStatus: Int) async throws {
        let fixtureDirectory = NSTemporaryDirectory() + "agentstudio-watchdog-child-exit-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }
        let command =
            childExitDuringWatchdogSampleFixture
            .replacingOccurrences(of: "__FIXTURE_DIRECTORY__", with: fixtureDirectory)
            .replacingOccurrences(of: "__EXIT_STATUS__", with: String(exitStatus))

        let result = try await runLaneScriptBash(command, innerWatchdog: .armed)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("LEADER_EXIT_OBSERVED=\(exitStatus)"))
        #expect(result.output.contains("FAIL_CHILD_STATUS=\(exitStatus)"))
        #expect(!result.output.contains("ERROR: no output progress"))
        #expect(!result.output.contains("timeout_reap="))
    }

    @Test(
        "an exited command keeps its status under a starved runner unless its fixture arms the watchdog",
        arguments: [LaneFixtureInnerWatchdog.unarmed, .armed]
    )
    func exitedCommandUnderStarvedRunner(innerWatchdog: LaneFixtureInnerWatchdog) async throws {
        let fixtureDirectory = NSTemporaryDirectory() + "agentstudio-starved-runner-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }
        let command =
            exitedCommandUnderStarvedRunnerFixture
            .replacingOccurrences(of: "__FIXTURE_DIRECTORY__", with: fixtureDirectory)
            .replacingOccurrences(
                of: "__STARVED_DRAIN_HOOK__", with: laneRunnerStarvedDrainHook(fifoDirectory: fixtureDirectory))

        let result = try await runLaneScriptBash(command, innerWatchdog: innerWatchdog)

        let lines = laneOutputLines(result.output)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        switch innerWatchdog {
        case .unarmed, .armedByFixture:
            // The command exits without printing the arm line, so neither arms the watchdog.
            #expect(lines.contains("EXITED_COMMAND_STATUS=0"), Comment(rawValue: result.output))
            #expect(!result.output.contains("ERROR: no output progress"), Comment(rawValue: result.output))
        case .armed:
            #expect(lines.contains("EXITED_COMMAND_STATUS=124"), Comment(rawValue: result.output))
            #expect(
                result.output.contains("ERROR: no output progress from 'exited command' for 20s"),
                Comment(rawValue: result.output))
        }
    }
}
