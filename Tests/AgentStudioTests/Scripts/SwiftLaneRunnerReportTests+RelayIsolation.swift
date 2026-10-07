import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

private let invalidChildBytesLaneFixture = #"""
    set -euo pipefail
    source scripts/swift-test-helpers.sh
    LOG_PREFIX=utf8-probe
    fixture_directory='__PROBE_DIRECTORY__'
    BUILD_PATH="$fixture_directory/build"
    unset SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH
    mkdir -p "$fixture_directory/events"
    export LANE_EVENT_STREAM_DIR="$fixture_directory/events"
    swift_test_begin_active_command_groups
    trap swift_test_cleanup_active_command_groups_directory EXIT

    passed_status=0
    run_swift_with_timeout 'passing invalid-byte probe' 20 /usr/bin/perl -e \
      'binmode STDOUT; print "PASS_CHILD_BEFORE\n"; print "\xff"; print "PASS_CHILD_AFTER\n"' -- \
      || passed_status=$?
    [ "$passed_status" -eq 0 ] || exit 41
    printf 'PASS_CHILD_STATUS=%s\n' "$passed_status"

    failed_status=0
    run_swift_with_timeout 'failed invalid-byte probe' 20 /usr/bin/perl -e \
      'binmode STDOUT; print "TESTS_PASSED\n"; print "\xff"; exit 7' -- \
      || failed_status=$?
    [ "$failed_status" -eq 7 ] || exit 42
    printf 'FAIL_CHILD_STATUS=%s\n' "$failed_status"

    """#

// Only the watchdog's clock/scheduling and command-diagnostic channel are
// controlled. The real stream relay retains the fixture's own lock. The driver
// releases the enclosing writer after reading the actual timeout error (red) or
// completed probe (green), so output ordering does not depend on machine speed.
private let sharedRelayLockSchedulingFixture = #"""
    # Observe the real fixture's lock while a second writer owns the enclosing lane's.
    eval "$(declare -f run_swift_with_timeout | sed '1s/run_swift_with_timeout/tq14_original_run/')"
    eval "$(declare -f swift_test_output_relay_begin_command | sed '1s/swift_test_output_relay_begin_command/tq14_original_begin/')"
    eval "$(declare -f print_timeout_process_diagnostics | sed '1s/print_timeout_process_diagnostics/tq14_original_diagnostics/')"
    # Keep diagnostic output off the held lock so the observer can release its owner
    # AFTER seeing the actual timeout error. The stream relay uses its unchanged lock.
    swift_test_output_relay_begin_command() {
      swift_test_output_relay_prepare_paths || return $?
      local stream_lock="$SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH"
      SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH="$TQ14_ROOT/diagnostics.lock"
      tq14_original_begin
      SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH="$stream_lock"
      export SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH
    }
    tq14_observed_filter() {
      /bin/bash "$TQ14_FILTER_SCRIPT"
      printf 'FILTER_EOF\n' >"$TQ14_ROOT/filtered"
    }
    export -f tq14_observed_filter
    _xcb_pipe_cmd() { echo tq14_observed_filter; }
    run_swift_with_timeout() {
      local watchdog_sample=progress watchdog_epoch=0 holder_pid="" status=0
      if [ "$1" = 'failed invalid-byte probe' ]; then
        /usr/bin/perl -MFcntl=:flock -e '
          my ($lock_path, $ready_path, $release_path, $released_path) = @ARGV;
          open my $lock, ">>", $lock_path or die $!;
          flock($lock, LOCK_EX) or die $!;
          open my $ready, ">", $ready_path or die $!;
          print {$ready} "LOCK_HELD\n"; close $ready;
          open my $release, "<", $release_path or die $!;
          <$release>; close $release;
          close $lock;
          open my $released, ">", $released_path or die $!;
          print {$released} "LOCK_RELEASED\n"; close $released;
        ' "$TQ14_ROOT/live/.build-agent-1/.swift-test-output.lock" \
          "$TQ14_ROOT/locked" "$TQ14_ROOT/release" "$TQ14_ROOT/released" &
        holder_pid=$!
        IFS= read -r lock_state <"$TQ14_ROOT/locked"
        [ "$lock_state" = LOCK_HELD ] || return 91
        printf 'ENCLOSING_LOCK_HELD\n' >&2
      fi
      tq14_original_run "$@" || status=$?
      if [ -n "$holder_pid" ]; then
        printf 'PROBE_CLOSED=%s\n' "$status"
        if [ "$status" -eq 7 ]; then
          IFS= read -r lock_state <"$TQ14_ROOT/released"
          [ "$lock_state" = LOCK_RELEASED ] || return 92
        fi
        wait "$holder_pid"
      fi
      return "$status"
    }
    date() {
      if [ "${1:-}" = +%s ]; then printf '%s\n' "$watchdog_epoch"; else /bin/date "$@"; fi
    }
    sleep() {
      case "$watchdog_sample" in
        progress)
          watchdog_sample=expiry
          IFS= read -r filtered_state <"$TQ14_ROOT/filtered"
          [ "$filtered_state" = FILTER_EOF ] || return 93
          if [ -n "$holder_pid" ] && \
            [ "$SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH" = "$TQ14_ROOT/live/.build-agent-1/.swift-test-output.lock" ]; then
            /usr/bin/perl -MFcntl=:flock -e '
              open my $lock, ">>", shift or die $!;
              exit(flock($lock, LOCK_EX | LOCK_NB) ? 1 : 0);
            ' "$SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH"
            printf 'PROBE_LOCK_SHARED=yes\n' >&2
          else
            local leader_status=0
            wait "$command_pid" || leader_status=$?
            printf 'PROBE_LOCK_SHARED=no LEADER_EXIT=%s\n' "$leader_status" >&2
          fi
          ;;
        expiry)
          watchdog_sample=closed
          watchdog_epoch=20
          ;;
        *) printf 'UNEXPECTED_WATCHDOG_SAMPLE\n' >&2; return 94 ;;
      esac
    }
    print_timeout_process_diagnostics() {
      local released_state leader_status=0
      IFS= read -r released_state <"$TQ14_ROOT/released"
      [ "$released_state" = LOCK_RELEASED ] || return 95
      wait "$command_pid" || leader_status=$?
      printf 'LEADER_EXIT_BEFORE_DIAGNOSTICS=%s\n' "$leader_status" >&2
      tq14_original_diagnostics "$@"
    }
    """#

private let sharedRelayLockDriverFixture = #"""
    #!/bin/bash
    set -euo pipefail
    export TQ14_ROOT='__ROOT__' TQ14_FILTER_SCRIPT='__FILTER__'
    mkdir -p "$TQ14_ROOT/live/.build-agent-1"
    # Reproduce the exported relay cache inherited by real nested Swift tests.
    export SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH="$TQ14_ROOT/live/.build-agent-1/.swift-test-output.lock"
    export SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH='__RELAY_SCRIPT__'
    cat >"$TQ14_ROOT/worker.sh" <<'PROBE_COMMAND'
    __PROBE_COMMAND__
    PROBE_COMMAND
    mkfifo "$TQ14_ROOT/locked" "$TQ14_ROOT/release" "$TQ14_ROOT/released" "$TQ14_ROOT/filtered"
    ( cd "$TQ14_ROOT/live"; /bin/bash "$TQ14_ROOT/worker.sh" ) 2>&1 | /usr/bin/perl -e '
      $| = 1;
      my $released = 0;
      while (my $line = <STDIN>) {
        print $line;
        if (!$released && ($line =~ /ERROR: no output progress/ || $line =~ /^PROBE_CLOSED=/)) {
          open my $release, ">", "$ENV{TQ14_ROOT}/release" or die $!;
          print {$release} "RELEASE
    "; close $release;
          $released = 1;
        }
      }
    '
    """#

extension SwiftLaneRunnerReportTests {
    @Test("invalid child bytes do not break a passing lane or its failure diagnostics")
    func invalidChildBytesDoNotBreakLaneOutput() async throws {
        let fixtureDirectory = NSTemporaryDirectory() + "agentstudio-invalid-lane-output-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }
        let command =
            invalidChildBytesLaneFixture
            .replacingOccurrences(of: "__PROBE_DIRECTORY__", with: fixtureDirectory)

        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("PASS_CHILD_BEFORE"))
        #expect(result.output.contains("PASS_CHILD_AFTER"))
        #expect(result.output.contains("PASS_CHILD_STATUS=0"))
        #expect(result.output.contains("TESTS_PASSED"))
        #expect(result.output.contains("FAIL_CHILD_STATUS=7"))
    }

    @Test("an invalid-byte script probe completes while the enclosing lane output lock is held")
    func invalidByteProbeDoesNotShareEnclosingLaneOutputLock() async throws {
        let fixtureDirectory = NSTemporaryDirectory() + "agentstudio-relay-lock-isolation-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }
        let repositoryRoot = FileManager.default.currentDirectoryPath
        let probeCommand =
            invalidChildBytesLaneFixture
            .replacingOccurrences(of: "__PROBE_DIRECTORY__", with: fixtureDirectory + "/probe")
            .replacingOccurrences(
                of: "source scripts/swift-test-helpers.sh",
                with: "source '\(repositoryRoot)/scripts/swift-test-helpers.sh'"
            )
            .replacingOccurrences(of: "passed_status=0", with: sharedRelayLockSchedulingFixture + "\npassed_status=0")
        let command =
            sharedRelayLockDriverFixture
            .replacingOccurrences(of: "__ROOT__", with: fixtureDirectory)
            .replacingOccurrences(of: "__FILTER__", with: repositoryRoot + "/scripts/filter-known-linker-warnings.sh")
            .replacingOccurrences(of: "__RELAY_SCRIPT__", with: repositoryRoot + "/scripts/swift-test-output-relay.pl")
            .replacingOccurrences(of: "__PROBE_COMMAND__", with: probeCommand)

        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("ENCLOSING_LOCK_HELD"))
        #expect(result.output.contains("PROBE_LOCK_SHARED=no LEADER_EXIT=7"))
        #expect(result.output.contains("FAIL_CHILD_STATUS=7"))
        #expect(!result.output.contains("PROBE_LOCK_SHARED=yes"))
        #expect(!result.output.contains("ERROR: no output progress"))
    }
}
