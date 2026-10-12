import AgentStudioInfrastructure
import Foundation
import Testing

@Suite("Swift lane phase continuation")
struct SwiftLanePhaseContinuationTests {
    @Test("fast native failure retains both isolated phases and its verdict", arguments: [1, 7, 139])
    func fastNativeFailureRetainsLaterPhases(status: Int) async throws {
        let result = try await runPhaseBash(
            phaseProbe(lane: "fast", failingPhase: "native", status: status)
        )
        #expect(result.exitCode == Int32(status), Comment(rawValue: result.output))
        #expect(phaseLines(result.output) == ["native", "aggregate", "fast-process"])
    }

    @Test("fast isolated failure retains the last phase and a failing verdict")
    func fastIsolatedFailureRetainsLastPhase() async throws {
        let result = try await runPhaseBash(
            phaseProbe(lane: "fast", failingPhase: "aggregate", status: 1)
        )
        #expect(result.exitCode == 1, Comment(rawValue: result.output))
        #expect(phaseLines(result.output) == ["native", "aggregate", "fast-process"])
    }

    @Test("large batch failure retains later phases", arguments: ["parallel", "serial"])
    func largeBatchFailureRetainsLaterPhases(failingPhase: String) async throws {
        let result = try await runPhaseBash(
            phaseProbe(lane: "large", failingPhase: failingPhase, status: 1)
        )
        #expect(result.exitCode == 1, Comment(rawValue: result.output))
        #expect(phaseLines(result.output) == ["parallel", "serial", "large-process"])
    }

    @Test("large serial-only failure retains its isolated phase")
    func largeSerialOnlyFailureRetainsIsolatedPhase() async throws {
        let result = try await runPhaseBash(
            phaseProbe(lane: "large", failingPhase: "serial-only", status: 1, parallel: false)
        )
        #expect(result.exitCode == 1, Comment(rawValue: result.output))
        #expect(phaseLines(result.output) == ["serial-only", "large-process"])
    }

    @Test("runner timeout or interruption stops later phases", arguments: [124, 129, 130, 143])
    func runnerTerminationStopsLaterPhases(status: Int) async throws {
        for (lane, phase, expected) in [
            ("fast", "native", ["native"]),
            ("fast", "aggregate", ["native", "aggregate"]),
            ("large", "parallel", ["parallel"]),
            ("large", "serial", ["parallel", "serial"]),
        ] {
            let result = try await runPhaseBash(phaseProbe(lane: lane, failingPhase: phase, status: status))
            #expect(result.exitCode == Int32(status), Comment(rawValue: result.output))
            #expect(phaseLines(result.output) == expected)
        }
    }

    @Test(
        "filter preparation failures start no phases",
        arguments: [
            "fast_non_webkit_skip_pattern", "aggregate_serial_non_webkit_suite_filters",
            "large_non_webkit_filter_pattern", "large_serial_non_webkit_filter_pattern",
            "large_process_global_filter_pattern",
        ])
    func preparationFailureStartsNoPhases(generator: String) async throws {
        let lane = generator.hasPrefix("large") ? "large" : "fast"
        let result = try await runPhaseBash(
            phaseProbe(lane: lane, failingPhase: "none", status: 0, preparationFailure: generator)
        )
        #expect(result.exitCode == 1, Comment(rawValue: result.output))
        #expect(phaseLines(result.output).isEmpty)
    }

    @Test("successful lanes preserve phase order", arguments: ["fast", "large"])
    func successfulLanePreservesPhaseOrder(lane: String) async throws {
        let result = try await runPhaseBash(phaseProbe(lane: lane, failingPhase: "none", status: 0))
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(
            phaseLines(result.output)
                == (lane == "fast"
                    ? ["native", "aggregate", "fast-process"] : ["parallel", "serial", "large-process"]))
    }

    @Test("isolated timeout stays terminal through the dispatcher")
    func isolatedTimeoutStaysTerminalThroughDispatcher() async throws {
        let evidenceDirectory = NSTemporaryDirectory() + "tq99-isolated-\(UUIDv7.generate().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: evidenceDirectory) }
        let result = try await runPhaseBash(
            """
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=tq99
            LANE_EVENT_STREAM_DIR='\(evidenceDirectory)'
            swift_test_isolated_process_concurrency() { echo 1; }
            run_selected_isolated_suite() { echo "PHASE:$2"; return 124; }
            dispatch_isolated_suites fast TimedOutSuite MustNotStartSuite
            """
        )
        #expect(result.exitCode == 124, Comment(rawValue: result.output))
        #expect(phaseLines(result.output) == ["TimedOutSuite"])
    }

    @Test("the lane signal trap exits before later phases")
    func laneSignalTrapExitsBeforeLaterPhases() async throws {
        let result = try await runPhaseBash(
            phaseProbe(lane: "fast", failingPhase: "none", status: 0, signalLane: true)
        )
        #expect(result.exitCode == 143, Comment(rawValue: result.output))
        #expect(phaseLines(result.output) == ["native"])
    }

    @Test("native and isolated failures coexist in the closing lane report")
    func nativeAndIsolatedFailuresCoexistInClosingReport() async throws {
        let command = phaseProbe(lane: "fast", failingPhase: "native", status: 7)
            .replacingOccurrences(
                of: "run_fast_non_webkit_swift_tests",
                with: """
                    source scripts/swift-test-lane-report.sh
                    print_opening_lane_report
                    begin_lane_accounting
                    LANE_BUNDLE_STATE=not_built
                    swift_test_bundle_set() { echo FixtureBundle; }
                    swift_test_bundle_count() { echo 1; }
                    trap print_closing_lane_report EXIT
                    run_aggregate_serial_non_webkit_swift_tests() {
                      phase_result aggregate
                      swift_test_record_failed_isolated_suite FailedIsolatedSuite 1 none completed
                      return 1
                    }
                    run_fast_non_webkit_swift_tests

                    """
            )
        let result = try await runPhaseBash(command)
        #expect(result.exitCode == 7, Comment(rawValue: result.output))
        #expect(result.output.contains("lane-report exit_status=7"))
        #expect(result.output.contains("lane-report failed_isolated_suites=1"))
        #expect(result.output.contains("lane-report failed_isolated_suite=FailedIsolatedSuite status=1"))
        #expect(phaseLines(result.output) == ["native", "aggregate", "fast-process"])
    }

    @Test("fast process-global phase retains earlier failures", arguments: [1, 7, 124])
    func fastProcessGlobalPhaseRetainsEarlierFailures(status: Int) async throws {
        let result = try await runPhaseBash(
            """
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=tq99 TIMEOUT_SECONDS=600
            swift_testing_helper_path() { echo FixtureHelper; }
            swift_testing_framework_path() { echo FixtureFramework; }
            swift_testing_helper_environment() { SWIFT_TEST_HELPER_ENVIRONMENT=(FIXTURE_VALUE=stub); }
            swift_test_suite_lane_inventory() { echo FixtureInventory; }
            swift_test_lane_suite_types() { printf 'FailingSuite\\nHealthySuite\\n'; }
            swift_test_lane_suite_types_match_inventory() { :; }
            swift_test_bundle_for_suite() { echo FixtureBundle; }
            swift_test_parallelization_env_word() { :; }
            run_swift_with_timeout() {
              echo "PHASE:$LANE_TIMING_FILTER"
              if [ "$LANE_TIMING_FILTER" = FailingSuite ]; then return \(status); fi
              return 0
            }
            phase_status=0
            run_fast_serial_process_swift_tests || phase_status=$?
            exit "$phase_status"
            """
        )
        #expect(result.exitCode == Int32(status), Comment(rawValue: result.output))
        #expect(phaseLines(result.output) == (status == 124 ? ["FailingSuite"] : ["FailingSuite", "HealthySuite"]))
    }

    private func runPhaseBash(_ command: String) async throws -> LaneScriptBashResult {
        try await runLaneScriptBash(command, environment: swiftTaskFixtureEnvironment())
    }

    private func phaseLines(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            line.hasPrefix("PHASE:") ? String(line.dropFirst("PHASE:".count)) : nil
        }
    }

    private func phaseProbe(
        lane: String, failingPhase: String, status: Int, parallel: Bool = true,
        preparationFailure: String = "", signalLane: Bool = false
    ) -> String {
        """
        set -euo pipefail
        source scripts/swift-test-helpers.sh
        LOG_PREFIX=tq99 TIMEOUT_SECONDS=600 BUILD_PATH=.build-probe
        SWIFT_TEST_PARALLEL=\(parallel ? 1 : 0)
        fast_non_webkit_skip_pattern() { echo SkipFixture; }
        aggregate_serial_non_webkit_suite_filters() { echo AggregateFixture; }
        large_non_webkit_filter_pattern() { echo ConcurrentFixture; }
        large_serial_non_webkit_filter_pattern() { echo SerialFixture; }
        large_process_global_filter_pattern() { echo ProcessFixture; }
        swift_test_parallelization_env_word() { :; }
        swift_package_sandbox_arguments() { :; }
        phase_result() {
          echo "PHASE:$1"
          if [ "$1" = '\(failingPhase)' ]; then return \(status); fi
          return 0
        }
        run_swift_with_timeout() {
          case "$1" in
            native-concurrent*) phase_result native ;;
            parallel*) phase_result parallel ;;
            'serial large process suites') phase_result serial ;;
            'serial large non-WebKit suites') phase_result serial-only ;;
          esac
        }
        run_aggregate_serial_non_webkit_swift_tests() { phase_result aggregate; }
        run_fast_serial_process_swift_tests() { phase_result fast-process; }
        run_large_process_global_swift_tests() { phase_result large-process; }
        \(preparationFailure.isEmpty ? "" : "\(preparationFailure)() { return 1; }")
        \(signalLane ? """
        source scripts/swift-test-lane-report.sh
        swift_test_signal_active_command_groups() { :; }
        swift_test_terminate_active_isolated_suites() { :; }
        trap_lane_termination_signals
        run_swift_with_timeout() { phase_result native; kill -TERM $$; }
        """ : "")
        run_\(lane)_non_webkit_swift_tests
        """
    }
}
