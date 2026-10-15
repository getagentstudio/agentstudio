import AgentStudioInfrastructure
import Foundation
import Testing

@Suite("Swift lane preparation failures")
struct SwiftLanePreparationFailureTests {
    @Test(
        "conditional isolated phase aborts failed preparation", arguments: ["mkdir", "mktemp", "mkfifo", "descriptor"])
    func conditionalIsolatedPhaseAbortsPreparation(step: String) async throws {
        for lane in ["fast", "large"] {
            let fixtureDirectory = try createFixtureDirectory()
            defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }
            let result = try await runFixture(
                """
                set -euo pipefail
                source scripts/swift-test-helpers.sh
                LOG_PREFIX=preparation-probe
                LANE_EVENT_STREAM_DIR='\(fixtureDirectory)'
                swift_test_isolated_process_concurrency() { echo 1; }
                swift_test_suite_lane_inventory() { echo FixtureInventory; }
                large_process_global_suite_filters() { echo FixtureSuite; }
                swift_test_lane_suite_types_match_inventory() { :; }
                run_selected_isolated_suite() { echo STARTED >>'\(fixtureDirectory)/started'; }
                mkdir() {
                  if [ '\(step)' = mkdir ]; then return 47; fi
                  command mkdir "$@"
                }
                mktemp() {
                  if [ '\(step)' = mktemp ]; then echo '\(fixtureDirectory)'; return 47; fi
                  command mktemp "$@"
                }
                mkfifo() {
                  if [ '\(step)' = mkfifo ]; then return 47; fi
                  command mkfifo "$@"
                }
                \(step == "descriptor" ? "exec() { return 47; }" : "")
                phase_status=0
                \(lane == "fast" ? "run_aggregate_serial_non_webkit_swift_tests FixtureSuite" : "run_large_process_global_swift_tests") || phase_status=$?
                exit "$phase_status"
                """
            )
            #expect(result.exitCode == 47, Comment(rawValue: result.output))
            #expect(!FileManager.default.fileExists(atPath: fixtureDirectory + "/started"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory).isEmpty)
        }
    }

    @Test("later missing bundle retains the first suite failure", arguments: [0, 7])
    func laterMissingBundleRetainsFirstFailure(firstStatus: Int) async throws {
        let result = try await runFixture(
            """
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=bundle-probe TIMEOUT_SECONDS=600
            swift_testing_helper_path() { echo FixtureHelper; }
            swift_testing_framework_path() { echo FixtureFramework; }
            swift_testing_helper_environment() { SWIFT_TEST_HELPER_ENVIRONMENT=(FIXTURE_VALUE=stub); }
            swift_test_suite_lane_inventory() { echo FixtureInventory; }
            swift_test_lane_suite_types() { printf 'FirstSuite\\nMissingBundleSuite\\n'; }
            swift_test_lane_suite_types_match_inventory() { :; }
            swift_test_bundle_for_suite() {
              if [ "$1" = MissingBundleSuite ]; then return 53; fi
              echo FixtureBundle
            }
            swift_test_parallelization_env_word() { :; }
            run_swift_with_timeout() { echo "STARTED:$LANE_TIMING_FILTER"; return \(firstStatus); }
            phase_status=0
            run_fast_serial_process_swift_tests || phase_status=$?
            exit "$phase_status"
            """
        )
        #expect(result.exitCode == Int32(firstStatus == 0 ? 53 : firstStatus), Comment(rawValue: result.output))
        #expect(result.output.contains("STARTED:FirstSuite"))
        #expect(!result.output.contains("STARTED:MissingBundleSuite"))
    }

    @Test(
        "conditional timeout runner aborts required setup before launch",
        arguments: [
            "start-clock", "formatter", "output-file", "evidence-stem", "evidence-clock", "expected-runs",
            "event-file", "event-directory", "held-log",
            "probe-sleep", "probe-clock", "probe-output", "state-read",
        ])
    func conditionalTimeoutRunnerAbortsSetup(step: String) async throws {
        let fixtureDirectory = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }
        if step == "held-log" {
            try FileManager.default.createDirectory(
                atPath: fixtureDirectory + "/evidence.held-steps.log", withIntermediateDirectories: false
            )
        }
        let result = try await runFixture(
            """
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=setup-probe
            TMPDIR='\(fixtureDirectory)'
            LANE_EVENT_STREAM_DIR='\(fixtureDirectory)'
            swift_test_output_relay_begin_command() { :; }
            swift_test_output_relay_finish_command() { :; }
            FIXTURE_COMMAND_OBSERVATION=running
            FIXTURE_PROBE_OBSERVED=0
            date() {
              if [ '\(step)' = start-clock ] || { [ '\(step)' = probe-clock ] && [ "$FIXTURE_PROBE_OBSERVED" = 1 ]; }; then return 53; fi
              if [ '\(step)' = evidence-clock ] && [ "$1" = +%Y%m%dT%H%M%S ]; then return 53; fi
              command date "$@"
            }
            _xcb_pipe_cmd() { if [ '\(step)' = formatter ]; then return 53; fi; echo cat; }
            \(step == "evidence-clock" ? "" : """
            lane_evidence_stem() {
              echo '\(fixtureDirectory)/evidence'
              if [ '\(step)' = evidence-stem ]; then return 53; fi
            }
            """)
            swift_test_invocation_expected_runs() { if [ '\(step)' = expected-runs ]; then return 53; fi; echo 1; }
            mktemp() {
              case "$*" in
                *swift-test-output*) if [ '\(step)' = output-file ]; then return 53; fi ;;
                *swift-test-events*) if [ '\(step)' = event-file ]; then return 53; fi ;;
              esac
              command mktemp "$@"
            }
            mkdir() {
              if [ '\(step)' = event-directory ] && [ -n "$event_stream_file" ]; then return 53; fi
              command mkdir "$@"
            }
            swift_test_f2_launch_command_group() {
              echo STARTED >'\(fixtureDirectory)/started'
              (exit 0) & SWIFT_TEST_STARTED_COMMAND_GROUP_PID=$!
            }
            swift_test_process_id_has_survivors() {
              case '\(step)' in
                probe-*|state-read)
                  if [ "$FIXTURE_COMMAND_OBSERVATION" = running ]; then
                    FIXTURE_COMMAND_OBSERVATION=exited
                    return 0
                  fi ;;
              esac
              return 1
            }
            sleep() { FIXTURE_PROBE_OBSERVED=1; if [ '\(step)' = probe-sleep ]; then return 53; fi; return 0; }
            wc() {
              if [ '\(step)' = probe-output ] && [ "$FIXTURE_PROBE_OBSERVED" = 1 ]; then return 53; fi
              command wc "$@"
            }
            \(step == "state-read" ? """
            read() {
              if [ "$*" = '-r last_output_size last_progress_epoch' ]; then return 53; fi
              builtin read "$@"
            }
            """ : "")
            swift_test_unregister_active_command_group() { :; }
            swift_test_f2_collect_events() { :; }
            swift_test_read_invocation_facts() { :; }
            swift_test_report_invocation_facts() { :; }
            swift_test_judge_invocation_status() { SWIFT_TEST_JUDGED_STATUS=0; }
            swift_test_f2_finalize_resources() { :; }
            swift_test_record_lane_peaks() { :; }
            write_lane_timing_sidecar() { :; }
            runner_status=0
            run_swift_with_timeout fixture 600 swift test || runner_status=$?
            exit "$runner_status"
            """
        )
        #expect(
            result.exitCode == Int32(step == "held-log" ? 1 : 53),
            Comment(rawValue: result.output))
        let commandLaunched = step.hasPrefix("probe-") || step == "state-read"
        #expect(FileManager.default.fileExists(atPath: fixtureDirectory + "/started") == commandLaunched)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory)
        #expect(!leftovers.contains { $0.hasPrefix("agentstudio-swift-test-") })
        if step == "held-log" {
            #expect(FileManager.default.fileExists(atPath: fixtureDirectory + "/evidence.held-steps.log"))
        }
    }

    private func createFixtureDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "tq99-preparation-\(UUIDv7.generate().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return path
    }

    private func runFixture(_ command: String) async throws -> LaneScriptBashResult {
        try await runLaneScriptBash(command, environment: swiftTaskFixtureEnvironment())
    }
}
