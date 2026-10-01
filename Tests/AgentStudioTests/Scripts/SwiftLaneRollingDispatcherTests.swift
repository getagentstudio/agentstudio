import Foundation
import Testing

@Suite("Swift lane rolling isolated dispatcher")
struct SwiftLaneRollingDispatcherTests {
    @Test("a wrapper exit without a completion is terminal and the next suite runs", arguments: ["kill", "errexit"])
    func wrapperExitCompletesDispatcher(failureMode: String) async throws {
        for bashInterpreter in ["/bin/bash", "/usr/bin/env bash"] {
            let result = try await runLaneScriptBash(
                SwiftLaneWrapperExitFixtures.wrapperExitCommand(
                    bashInterpreter: bashInterpreter, failureMode: failureMode
                )
            )
            #expect(result.exitCode == 0, Comment(rawValue: result.output))
            #expect(result.output.contains("COMPLETED After"))
            #expect(result.output.contains("reason=wrapper_exited_without_completion"))
            #expect(result.output.contains("WRAPPER_EXIT_DRAINED mode=\(failureMode)"))
        }
    }

    @Test("two wrappers killed together both report and refill their slots")
    func simultaneousWrapperExitsRefillBothSlots() async throws {
        for bashInterpreter in ["/bin/bash", "/usr/bin/env bash"] {
            let result = try await runLaneScriptBash(
                SwiftLaneWrapperExitFixtures.wrapperExitCommand(
                    bashInterpreter: bashInterpreter, failureMode: "coalesced"
                )
            )
            #expect(result.exitCode == 0, Comment(rawValue: result.output))
            #expect(result.output.contains("COMPLETED AfterOne"))
            #expect(result.output.contains("COMPLETED AfterTwo"))
            #expect(result.output.contains("WRAPPER_EXIT_DRAINED mode=coalesced"))
        }
    }

    @Test("a wrapper killed after worker launch is red and its worker is gone at lane return")
    func wrapperKilledAfterWorkerLaunchReapsWorker() async throws {
        for bashInterpreter in ["/bin/bash", "/usr/bin/env bash"] {
            let result = try await runLaneScriptBash(
                SwiftLaneWrapperExitFixtures.wrapperExitCommand(
                    bashInterpreter: bashInterpreter, failureMode: "after-worker"
                )
            )

            #expect(result.exitCode == 0, Comment(rawValue: result.output))
            #expect(result.output.contains("COMPLETED After"))
            #expect(result.output.contains("reason=wrapper_exited_without_completion"))
            #expect(result.output.contains("WRAPPER_WORKER_REAPED"))
        }
    }

    @Test("a killed worker reports KILL, finishes the lane, and leaves no children")
    func killedWorkerCompletesDispatcher() async throws {
        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=killed-worker-probe
            fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/killed-worker-probe.XXXXXX")"
            trap 'rm -f "$fixture_dir"/*; rmdir "$fixture_dir"' EXIT
            SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE="$fixture_dir/failures"
            swift_test_isolated_process_concurrency() { echo 1; }
            run_selected_isolated_suite() {
              if [ "$2" = Killed ]; then
                /bin/sh -c 'printf "%s\n" "$PPID"' >"$fixture_dir/worker-pid"
                read -r worker_pid <"$fixture_dir/worker-pid"
                kill -KILL "$worker_pid"
              fi
              printf 'COMPLETED %s\n' "$2"
            }
            status=0
            dispatch_isolated_suites fast Killed After || status=$?
            [ "$status" -eq 1 ] || exit 41
            [ "$(swift_test_failed_isolated_suite_count)" -eq 1 ] || exit 42
            grep -q $'Killed\t137\tKILL' "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
            [ -z "$(jobs -pr)" ] || exit 43
            printf 'KILLED_WORKER_DRAINED\n'
            """#
        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("COMPLETED After"))
        #expect(result.output.contains("KILLED_WORKER_DRAINED"))
    }

    @Test("WebKit coverage uses SwiftPM so the coverage flag reaches the test command")
    func webkitCoverageForwardsFlag() async throws {
        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=coverage-probe
            EXTRA_SWIFT_TEST_ARGS=--enable-code-coverage
            BUILD_PATH=.build-coverage-probe
            TIMEOUT_SECONDS=60
            swift_package_sandbox_arguments() { :; }
            swift_testing_bundle_path() { printf '/fixture/TestBundle.xctest\n'; }
            swift_testing_helper_path() { printf '/fixture/swiftpm-testing-helper\n'; }
            swift_testing_framework_path() { printf '/fixture/frameworks\n'; }
            run_swift_with_timeout() { printf 'ARG:%s\n' "$@"; }
            run_webkit_suite WebKitSerializedTests/Fixture
            """#
        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("ARG:swift\nARG:test\nARG:--enable-code-coverage"))
        #expect(result.output.contains("ARG:--filter\nARG:WebKitSerializedTests/Fixture"))
    }

    @Test("dispatcher state is private to a lane-owned temporary directory")
    func dispatcherStateUsesLaneOwnedDirectory() async throws {
        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=dispatch-state-probe
            LANE_EVENT_STREAM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-state-probe.XXXXXX")"
            trap 'rmdir "$LANE_EVENT_STREAM_DIR"' EXIT
            swift_test_isolated_process_concurrency() { echo 1; }
            run_selected_isolated_suite() {
              case "$dispatch_dir" in
                "$LANE_EVENT_STREAM_DIR"/agentstudio-isolated-dispatch.*) ;;
                *) return 44;;
              esac
              [ -p "$dispatch_dir/completions" ] || return 45
              [ "$(stat -f %Lp "$dispatch_dir")" = 700 ] || return 46
            }
            dispatch_isolated_suites fast Fixture
            [ -z "$(find "$LANE_EVENT_STREAM_DIR" -mindepth 1 -print)" ] || exit 47
            printf 'PRIVATE_DISPATCH_STATE_OK\n'
            """#
        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("PRIVATE_DISPATCH_STATE_OK"))
    }

    @Test("a completed slot refills before the slow child finishes and every failure is tallied")
    func completionRefillsSlotAndTalliesFailures() async throws {
        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=rolling-probe
            fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/rolling-probe.XXXXXX")"
            trap 'rm -f "$fixture_dir"/*; rmdir "$fixture_dir"' EXIT
            mkfifo "$fixture_dir/events"
            for suite in A B C D; do mkfifo "$fixture_dir/release-$suite"; done
            exec 8<>"$fixture_dir/events"
            SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE="$fixture_dir/failures"
            swift_test_isolated_process_concurrency() { echo 2; }
            run_selected_isolated_suite() {
              printf 'START %s\n' "$2" >&8
              read -r release <"$fixture_dir/release-$2"
              printf 'END %s\n' "$2" >&8
              case "$2" in B) return 7;; C) return 124;; esac
              return 0
            }
            dispatch_isolated_suites fast A B C D & dispatcher_pid=$!
            active=0
            read -r -u 8 first_start
            read -r -u 8 second_start
            case "$first_start|$second_start" in
              'START A|START B'|'START B|START A') active=2;;
              *) exit 20;;
            esac
            printf 'release\n' >"$fixture_dir/release-B"
            read -r -u 8 event; [ "$event" = 'END B' ] || exit 21
            active=$((active - 1))
            read -r -u 8 event; [ "$event" = 'START C' ] || exit 22
            active=$((active + 1))
            [ "$active" -eq 2 ] || exit 23
            printf 'ROLLING_BEFORE_A_END\n'
            printf 'release\n' >"$fixture_dir/release-C"
            read -r -u 8 event; [ "$event" = 'END C' ] || exit 24
            active=$((active - 1))
            read -r -u 8 event; [ "$event" = 'START D' ] || exit 25
            active=$((active + 1))
            printf 'release\n' >"$fixture_dir/release-A"
            printf 'release\n' >"$fixture_dir/release-D"
            for remaining in 1 2; do
              read -r -u 8 event
              case "$event" in 'END A'|'END D') active=$((active - 1));; *) exit 26;; esac
            done
            dispatcher_status=0
            wait "$dispatcher_pid" || dispatcher_status=$?
            [ "$active" -eq 0 ] || exit 27
            [ "$dispatcher_status" -eq 1 ] || exit 28
            [ "$(swift_test_failed_isolated_suite_count)" -eq 2 ] || exit 29
            grep -q $'B\t7\tnone' "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
            grep -q $'C\t124\tnone' "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
            printf 'CAP_OK failures=2 status=%s\n' "$dispatcher_status"
            """#
        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("ROLLING_BEFORE_A_END"))
        #expect(result.output.contains("CAP_OK failures=2 status=1"))
    }

    @Test("WebKit uses one shared-dispatcher slot and tallies every failure")
    func webkitUsesDispatcherAndContinuesAfterFailure() async throws {
        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=webkit-probe
            SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE="$(mktemp "${TMPDIR:-/tmp}/webkit-probe.XXXXXX")"
            trap 'rm -f "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"' EXIT
            : >"$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
            swift_test_isolated_process_concurrency() { echo 2; }
            webkit_suite_filters() { printf 'WebKitSerializedTests/One\nWebKitSerializedTests/Two\nWebKitSerializedTests/Three\n'; }
            run_webkit_suite() {
              printf 'WEBKIT_FILTER %s\n' "$1"
              case "$1" in
                WebKitSerializedTests/Two|WebKitSerializedTests/Three)
                  swift_test_record_failed_isolated_suite "$1" 1 SEGV
                  return 1
                  ;;
              esac
              return 0
            }
            status=0
            run_webkit_suites || status=$?
            [ "$status" -eq 1 ] || exit 30
            [ "$(swift_test_failed_isolated_suite_count)" -eq 2 ] || exit 31
            grep -q $'WebKitSerializedTests/Two\t1\tSEGV' "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
            grep -q $'WebKitSerializedTests/Three\t1\tSEGV' "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
            printf 'WEBKIT_TALLY_OK failures=2 status=%s\n' "$status"
            """#
        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("WebKit process-global concurrency: 1"))
        #expect(result.output.contains("WEBKIT_FILTER WebKitSerializedTests/One"))
        #expect(result.output.contains("WEBKIT_FILTER WebKitSerializedTests/Two"))
        #expect(result.output.contains("WEBKIT_FILTER WebKitSerializedTests/Three"))
        #expect(result.output.contains("WEBKIT_TALLY_OK failures=2 status=1"))
    }

    @Test("a signalled child is reaped and recorded with its signal")
    func signalledChildIsReapedAndRecorded() async throws {
        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=signal-probe
            SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE="$(mktemp "${TMPDIR:-/tmp}/signal-probe.XXXXXX")"
            trap 'rm -f "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"' EXIT
            swift_test_isolated_process_concurrency() { echo 2; }
            run_selected_isolated_suite() {
              if [ "$2" = Killed ]; then
                /bin/sh -c 'kill -TERM "$$"'
                return $?
              fi
              return 0
            }
            status=0
            dispatch_isolated_suites fast Killed After || status=$?
            [ "$status" -eq 1 ] || exit 31
            [ "$(swift_test_failed_isolated_suite_count)" -eq 1 ] || exit 32
            grep -q $'Killed\t143\tTERM' "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
            [ -z "$(jobs -pr)" ] || exit 33
            printf 'SIGNAL_REAP_OK\n'
            """#
        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("SIGNAL_REAP_OK"))
    }
}
