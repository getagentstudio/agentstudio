import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

private let generatedLaneFilterBehaviorProbe = #"""
    source scripts/swift-test-helpers.sh

    assert_match_pair() {
      local generator="$1"
      local pattern="$2"
      local expected_match="$3"
      local expected_nonmatch="$4"

      if [[ "$expected_match" =~ $pattern ]]; then
        printf 'MATCH_OK %s\n' "$generator"
      else
        printf 'missing expected match generator=%s test_id=%s\n' \
          "$generator" "$expected_match" >&2
        return 1
      fi
      if [[ "$expected_nonmatch" =~ $pattern ]]; then
        printf 'unexpected match generator=%s test_id=%s\n' \
          "$generator" "$expected_nonmatch" >&2
        return 1
      fi
      return 0
    }

    assert_single_escaped_entries() {
      local generator="$1"
      local pattern_list="$2"
      local remainder anchor_count=0 closing_count=0
      remainder="$pattern_list"
      while [[ "$remainder" == *'\.'* ]]; do
        anchor_count=$((anchor_count + 1))
        remainder="${remainder#*'\.'}"
      done
      remainder="$pattern_list"
      while [[ "$remainder" == *'(/|$)'* ]]; do
        closing_count=$((closing_count + 1))
        remainder="${remainder#*'(/|$)'}"
      done
      if [ "$anchor_count" -eq 0 ] || [ "$anchor_count" -ne "$closing_count" ]; then
        printf 'invalid anchor count generator=%s anchors=%s closings=%s\n' \
          "$generator" "$anchor_count" "$closing_count" >&2
        return 1
      fi
      if [[ "$pattern_list" == *'\\.'* || "$pattern_list" == *'\\/'* \
        || "$pattern_list" == *'\\('* || "$pattern_list" == *'\\$'* ]]; then
        printf 'double-escaped entry generator=%s pattern=%s\n' \
          "$generator" "$pattern_list" >&2
        return 1
      fi
      printf 'SINGLE_ESCAPE_OK %s entries=%s\n' "$generator" "$anchor_count"
    }

    fast_concurrent_id='AgentStudioTests.AgentStudioFileViewStartupDiagnosticTests/smokeRenderProofRequiresStreamedTreeAndSelectedContent()'
    fast_isolated_id='AgentStudioSharedComponentsTests.AccessibilityPressBridgeTests/disabledAccessibilityPressBridgeRejectsPress()'
    large_concurrent_id='AgentStudioTests.AgentStudioGitDependencyTests/agentStudioGitUsesRemotePackageAndHostedArtifact()'
    large_serial_id='AgentStudioTests.BridgePackagedProductJourneyScriptTests/runnerDryRunDeclaresStrictLaunchAndFixtureContract()'
    large_process_global_id='AgentStudioInfrastructureTests.AgentStudioOTLPBootstrapSmokeTests/otelConfigurationAppliesExplicitLogBatchBackpressurePolicy()'
    fast_process_global_id='AgentStudioInfrastructureTests.SQLiteDatabaseFactoryProcessTests/bytePreservingStartupReaderSeesCommittedWALWithoutChangingDatabaseFiles()'
    webkit_id='AgentStudioTests.WebKitSerializedTests/BridgePaneControllerTests/handleBridgeReady_setsReadyAndTeardownResets()'

    fast_skip_pattern="$(fast_non_webkit_skip_pattern)" || exit 2
    fast_concurrent_pattern="$(swift_test_lane_filter_pattern fast concurrent)" || exit 2
    fast_concurrent_skip_pattern="$(swift_test_lane_fast_concurrent_skip_pattern)" || exit 2
    fast_process_global_pattern="$(fast_serial_process_filter_pattern)" || exit 2
    large_concurrent_pattern="$(large_non_webkit_filter_pattern)" || exit 2
    large_serial_pattern="$(large_serial_non_webkit_filter_pattern)" || exit 2
    large_process_global_pattern="$(large_process_global_filter_pattern)" || exit 2
    aggregate_serial_pattern="$(aggregate_serial_non_webkit_filter_pattern)" || exit 2
    webkit_filters="$(webkit_suite_filters)" || exit 2
    webkit_pattern='WebKitSerializedTests/BridgePaneControllerTests'

    assert_match_pair fast-skip "$fast_skip_pattern" "$fast_isolated_id" "$fast_concurrent_id" || exit 1
    assert_match_pair fast-concurrent-filter "$fast_concurrent_pattern" "$fast_concurrent_id" "$fast_isolated_id" || exit 1
    assert_match_pair fast-concurrent-skip "$fast_concurrent_skip_pattern" "$large_concurrent_id" "$fast_concurrent_id" || exit 1
    assert_match_pair fast-process-global "$fast_process_global_pattern" "$fast_process_global_id" "$fast_concurrent_id" || exit 1
    assert_match_pair large-concurrent "$large_concurrent_pattern" "$large_concurrent_id" "$fast_concurrent_id" || exit 1
    assert_match_pair large-serial "$large_serial_pattern" "$large_serial_id" "$large_concurrent_id" || exit 1
    assert_match_pair large-process-global "$large_process_global_pattern" "$large_process_global_id" "$large_concurrent_id" || exit 1
    assert_match_pair aggregate-serial "$aggregate_serial_pattern" "$fast_isolated_id" "$fast_concurrent_id" || exit 1
    if ! printf '%s\n' "$webkit_filters" | /usr/bin/grep -Fxq "$webkit_pattern"; then
      printf 'missing WebKit selector from generated list: %s\n' "$webkit_pattern" >&2
      exit 1
    fi
    assert_match_pair webkit-list "$webkit_pattern" "$webkit_id" "$fast_concurrent_id" || exit 1

    assert_single_escaped_entries fast-skip "$fast_skip_pattern" || exit 1
    assert_single_escaped_entries fast-concurrent-filter "$fast_concurrent_pattern" || exit 1
    assert_single_escaped_entries fast-concurrent-skip "$fast_concurrent_skip_pattern" || exit 1
    assert_single_escaped_entries fast-process-global "$fast_process_global_pattern" || exit 1
    assert_single_escaped_entries large-concurrent "$large_concurrent_pattern" || exit 1
    assert_single_escaped_entries large-serial "$large_serial_pattern" || exit 1
    assert_single_escaped_entries large-process-global "$large_process_global_pattern" || exit 1
    assert_single_escaped_entries aggregate-serial "$aggregate_serial_pattern" || exit 1
    printf 'LANE_FILTER_BEHAVIOR_OK generators=9\n'
    """#

@Suite("Swift lane runner load reporting")
struct SwiftLaneRunnerReportTests {
    @Test("timing sidecars preserve the command verdict and ordered boundaries")
    func timingSidecarPreservesVerdictAndBoundaries() async throws {
        let evidenceDirectory = NSTemporaryDirectory() + "agentstudio-timing-sidecar-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: evidenceDirectory) }
        let output = try await runBash(
            "LOG_PREFIX=timing; BUILD_PATH='\(evidenceDirectory)/build'; "
                + "export BUILD_PATH LANE_EVENT_STREAM_DIR='\(evidenceDirectory)' "
                + "LANE_TIMING_FILTER=FixtureSuite LANE_TIMING_BATCH=2 LANE_TIMING_SLOT=3 "
                + "LANE_TIMING_CONCURRENCY=4; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'fixture' 60 /bin/bash -c 'exit 7' || status=$?; "
                + "echo STATUS=${status:-0}"
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory)
        let sidecar = try #require(files.first { $0.hasSuffix(".timing.json") })
        let data = try Data(contentsOf: URL(fileURLWithPath: evidenceDirectory + "/" + sidecar))
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dispatch = try #require(record["dispatch_ms"] as? Int)
        let start = try #require(record["command_start_ms"] as? Int)
        let exit = try #require(record["command_exit_ms"] as? Int)
        let complete = try #require(record["wrapper_complete_ms"] as? Int)
        #expect(output.contains("STATUS=7"))
        #expect(dispatch <= start && start <= exit && exit <= complete)
        #expect(record["command_status"] as? Int == 7)
        #expect(record["filter"] as? String == "FixtureSuite")
        #expect(record["batch_id"] as? Int == 2)
        #expect(record["slot"] as? Int == 3)
        #expect(record["slot_cap"] as? Int == 4)
        #expect(record["phase"] == nil || record["phase"] is NSNull)
        #expect(record["timed_out"] as? Bool == false)
        #expect(record["event_stream_file"] is String)
    }

    @Test("prebuild flags are absent by default and appended when compiler statistics are enabled")
    func prebuildCompilerStatisticsFlagsAreOptIn() async throws {
        let statisticsDirectory = NSTemporaryDirectory() + "agentstudio-compiler-stats-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: statisticsDirectory) }
        let output = try await runBash(
            "LOG_PREFIX=timing; PREBUILD_TIMEOUT_SECONDS=60; BUILD_PATH=.build-probe; "
                + "source scripts/swift-test-helpers.sh; "
                + "run_swift_with_timeout() { printf 'ARG:%s\\n' \"\u{0024}@\"; }; "
                // The nested-sandbox flag has its own suite; pin it empty here so
                // this claim holds inside an agent sandbox too.
                + "swift_package_sandbox_arguments() { :; }; "
                + "CI_SWIFT_SANDBOX_POLICY_PATH=/dev/null; "
                + "unset SWIFT_BUILD_STATS_DIR; prebuild_swift_tests; echo ENABLED; "
                + "export SWIFT_BUILD_STATS_DIR='\(statisticsDirectory)'; prebuild_swift_tests"
        )
        let halves = output.components(separatedBy: "ENABLED\n")
        #expect(halves.count == 2)
        #expect(
            halves.first == "ARG:prebuild test bundles\nARG:60\nARG:swift\nARG:build\n"
                + "ARG:--build-tests\nARG:--build-path\nARG:.build-probe\n")
        #expect(
            halves.last?.contains(
                "ARG:-Xswiftc\nARG:-stats-output-dir\nARG:-Xswiftc\n"
                    + "ARG:\(statisticsDirectory)\n") == true)
    }

    @Test("timing summary measures actual scheduler idle and keeps missing spans unknown")
    func timingSummaryComputesActualIdleAndUnknowns() async throws {
        let evidenceDirectory = NSTemporaryDirectory() + "agentstudio-timing-summary-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: evidenceDirectory) }
        try FileManager.default.createDirectory(atPath: evidenceDirectory, withIntermediateDirectories: true)
        let eventFile = evidenceDirectory + "/fixture.events.jsonl"
        try "{\"kind\":\"runStarted\",\"instant\":{\"since1970\":1790000001.1}}\n"
            .appending(
                "{\"kind\":\"runEnded\",\"instant\":{\"since1970\":1790000001.3}}\n"
            )
            .write(toFile: eventFile, atomically: true, encoding: .utf8)
        let fixture: [String: Any] = [
            "lane": "fixture", "label": "prebuild test bundles", "dispatch_ms": 1_790_000_000_900,
            "command_start_ms": 1_790_000_001_000, "command_exit_ms": 1_790_000_001_350,
            "wrapper_complete_ms": 1_790_000_001_400,
            "event_stream_file": eventFile,
        ]
        let fixtureData = try JSONSerialization.data(withJSONObject: fixture)
        try fixtureData.write(to: URL(fileURLWithPath: evidenceDirectory + "/lane-fixture.timing.json"))
        let wrappedEventFile = evidenceDirectory + "/wrapped.events.jsonl"
        try "{\"kind\":\"event\",\"payload\":{\"kind\":\"runStarted\",\"instant\":{\"since1970\":1790000001.1}}}\n"
            .appending(
                "{\"kind\":\"event\",\"payload\":{\"kind\":\"runEnded\",\"instant\":{\"since1970\":1790000001.3}}}\n"
            )
            .write(toFile: wrappedEventFile, atomically: true, encoding: .utf8)
        var wrappedFixture = fixture
        wrappedFixture["lane"] = "fixture-wrapped"
        wrappedFixture["event_stream_file"] = wrappedEventFile
        let wrappedData = try JSONSerialization.data(withJSONObject: wrappedFixture)
        try wrappedData.write(to: URL(fileURLWithPath: evidenceDirectory + "/lane-wrapped.timing.json"))
        for (index, duration) in [100, 400, 100, 400, 100, 100].enumerated() {
            let dispatch = [1000, 1000, 1000, 1100, 1400, 1500][index]
            let item: [String: Any] = [
                "lane": "isolated", "label": "isolated process-global non-WebKit suite: \(index)",
                "filter": "Suite\(index)", "batch_id": index + 1,
                "slot": index % 3 + 1, "slot_cap": 3, "dispatch_ms": dispatch,
                "wrapper_complete_ms": dispatch + duration,
            ]
            let data = try JSONSerialization.data(withJSONObject: item)
            try data.write(to: URL(fileURLWithPath: evidenceDirectory + "/lane-\(index).timing.json"))
        }
        for slot in 1...4 {
            let item: [String: Any] = [
                "lane": "four-slot", "label": "isolated process-global non-WebKit suite: \(slot)",
                "filter": "FourSlotSuite\(slot)", "batch_id": slot,
                "slot": slot, "slot_cap": 4, "dispatch_ms": 2000,
                "wrapper_complete_ms": 2100,
            ]
            let data = try JSONSerialization.data(withJSONObject: item)
            try data.write(to: URL(fileURLWithPath: evidenceDirectory + "/lane-four-\(slot).timing.json"))
        }
        for slot in 1...3 {
            let item: [String: Any] = [
                "lane": "partial-four-slot", "label": "isolated process-global non-WebKit suite: \(slot)",
                "filter": "PartialFourSlotSuite\(slot)", "batch_id": slot,
                "slot": slot, "slot_cap": 4, "dispatch_ms": 3000,
                "wrapper_complete_ms": 3100,
            ]
            let data = try JSONSerialization.data(withJSONObject: item)
            try data.write(to: URL(fileURLWithPath: evidenceDirectory + "/lane-partial-\(slot).timing.json"))
        }
        for (phase, dispatch) in [("fast", 4000), ("webkit", 9000)] {
            let item: [String: Any] = [
                "lane": "shared-lane", "phase": phase, "label": "isolated suite: \(phase)",
                "filter": "Suite\(phase)", "batch_id": 1, "slot": 1, "slot_cap": 1,
                "dispatch_ms": dispatch, "wrapper_complete_ms": dispatch + 100,
            ]
            let data = try JSONSerialization.data(withJSONObject: item)
            try data.write(to: URL(fileURLWithPath: evidenceDirectory + "/lane-shared-\(phase).timing.json"))
        }
        _ = try await runBash("LANE_EVENT_STREAM_DIR='\(evidenceDirectory)' /bin/bash scripts/summarize-ci-timing.sh")
        let summary = try String(contentsOfFile: evidenceDirectory + "/timing-summary.md", encoding: .utf8)
        #expect(summary.contains("| fixture | 1 | 0.500 | 0.100 | 0.200 | 0.050 | 0.050 |"))
        #expect(summary.contains("| fixture-wrapped | 1 | 0.500 | 0.100 | 0.200 | 0.050 | 0.050 |"))
        #expect(summary.contains("| isolated | unknown | 6 | 3 | 0.600 | 0.600 |"))
        #expect(summary.contains("| four-slot | unknown | 4 | 4 | 0.100 | 0.000 |"))
        #expect(summary.contains("| partial-four-slot | unknown | 3 | 4 | 0.100 | 0.100 |"))
        #expect(summary.contains("| shared-lane | fast | 1 | 1 | 0.100 | 0.000 |"))
        #expect(summary.contains("| shared-lane | webkit | 1 | 1 | 0.100 | 0.000 |"))
        #expect(summary.contains("unknown"))
        let emptyDirectory = evidenceDirectory + "/empty"
        _ = try await runBash("LANE_EVENT_STREAM_DIR='\(emptyDirectory)' /bin/bash scripts/summarize-ci-timing.sh")
        let emptySummary = try String(contentsOfFile: emptyDirectory + "/timing-summary.md", encoding: .utf8)
        #expect(emptySummary.contains("Unknown/null spans: unknown (no sidecars)."))
    }

    @Test("every Swift test invocation takes its parallelization width from the one helper")
    func everySwiftTestInvocationTakesItsWidthFromTheOneHelper() throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let widthFunction = try shellFunction(named: "swift_test_parallelization_width", in: helperScript)
        let invocationLines = (helperScript + "\n" + laneRunnerScript)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("env AGENT_STUDIO_BENCHMARK_MODE=off") }
        let invocationsBypassingTheHelper = invocationLines.filter {
            !$0.contains("$(swift_test_parallelization_env_word)")
        }

        #expect(invocationLines.count >= 9)
        #expect(
            invocationsBypassingTheHelper.isEmpty,
            "Swift test invocations not routed through the width helper: \(invocationsBypassingTheHelper)"
        )
        // No default: the cap is experimental, and a set width hung this suite at
        // every width tried, so it must stay opt-in.
        #expect(widthFunction.contains("${SWIFT_TEST_PARALLELIZATION_WIDTH:-}"))
        #expect(!widthFunction.contains("hw.ncpu"))
        // No call site may name the variable directly; that is how they drift.
        #expect(
            invocationLines.allSatisfy {
                !$0.contains("SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=")
            }
        )
    }

    @Test("the width reaches the environment only when it is set")
    func widthReachesTheEnvironmentOnlyWhenItIsSet() async throws {
        // Absence and empty are different to Swift Testing: absence means
        // unlimited, and we never want to depend on how it parses "" or 0.
        let unsetWord = try await runBash(
            "env -u SWIFT_TEST_PARALLELIZATION_WIDTH bash -c "
                + "'source scripts/swift-test-helpers.sh; swift_test_parallelization_env_word'"
        )
        let setWord = try await runBash(
            "SWIFT_TEST_PARALLELIZATION_WIDTH=7 bash -c "
                + "'source scripts/swift-test-helpers.sh; swift_test_parallelization_env_word'"
        )
        // The word is used unquoted, so an empty helper must contribute no
        // argument at all to the invocation.
        let unsetArgumentCount = try await runBash(
            "env -u SWIFT_TEST_PARALLELIZATION_WIDTH bash -c "
                + "'source scripts/swift-test-helpers.sh; "
                + "set -- $(swift_test_parallelization_env_word); echo $#'"
        )
        let unsetLabel = try await runBash(
            "env -u SWIFT_TEST_PARALLELIZATION_WIDTH bash -c "
                + "'source scripts/swift-test-helpers.sh; swift_test_parallelization_width_label'"
        )
        let setLabel = try await runBash(
            "SWIFT_TEST_PARALLELIZATION_WIDTH=7 bash -c "
                + "'source scripts/swift-test-helpers.sh; swift_test_parallelization_width_label'"
        )

        #expect(unsetWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(
            setWord.trimmingCharacters(in: .whitespacesAndNewlines)
                == "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=7"
        )
        #expect(unsetArgumentCount.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        #expect(unsetLabel.trimmingCharacters(in: .whitespacesAndNewlines) == "unlimited")
        #expect(setLabel.trimmingCharacters(in: .whitespacesAndNewlines) == "7")
    }

    @Test("lane runner reports machine load before and after every lane")
    func laneRunnerReportsMachineLoadBeforeAndAfterEveryLane() throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let closingReport = try shellFunction(named: "print_closing_lane_report", in: laneRunnerScript)

        for preflightLabel in [
            "lane-report cpu_count=",
            "lane-report memory_bytes=",
            "lane-report parallelization_width=",
            "lane-report isolated_process_concurrency=",
            "lane-report xcode=",
            "lane-report swift=",
            "lane-report head_sha=",
            "lane-report tree_dirty=",
        ] {
            #expect(laneRunnerScript.contains(preflightLabel))
        }
        for closingLabel in [
            "lane-report exit_status=",
            "lane-report wall_seconds=",
            "lane-report cpu_seconds=",
            "lane-report cpu_utilization=",
            "lane-report peak_announced_tests=",
            "lane-report peak_running_parameterized_cases=",
            "lane-report failed_isolated_suites=",
            "lane-report head_sha=",
            "lane-report tree_dirty=",
            "lane-report bundle_state=",
            "lane-report bundle_identity=",
            "lane-report build_receipt_head_sha=",
        ] {
            #expect(closingReport.contains(closingLabel))
        }
        // Validity and verdict are decided by one helper, so the receipt cannot
        // print a verdict that skipped the validity check.
        #expect(closingReport.contains("print_lane_receipt_verdict \"$exit_status\""))
        // The whole point of a stable prefix is that a CI reader can grep it, so
        // the emitted label set is pinned rather than only spot-checked.
        #expect(
            laneReportLabels(in: helperScript + "\n" + laneRunnerScript) == [
                // Which tree and bundle the lane tested, and whether that makes
                // its verdict evidence at all.
                "build_receipt_head_sha",
                "bundle_identity",
                "bundle_state",
                "cpu_count",
                "cpu_seconds",
                "cpu_utilization",
                // Where a wedged run's event-stream ledger was kept, and whether
                // the lane's own child group was actually reaped on the way out.
                "event_stream",
                "evidence_retention",
                "exit_status",
                "fact_expected",
                "failed_isolated_suite",
                "failed_isolated_suites",
                "head_sha",
                // The harness steps a hung lane was still waiting on.
                "held_step_unarrived",
                "isolated_process_concurrency",
                "memory_bytes",
                "parallelization_width",
                // Tests whose start was posted: announced, never "started".
                "peak_announced_tests",
                "peak_running_parameterized_cases",
                "receipt_valid",
                "running_parameterized_cases_at_timeout",
                "stack_sample",
                "swift",
                "task_dump",
                "timeout_reap",
                "tree_dirty",
                "verdict",
                "wall_seconds",
                "xcode",
            ]
        )
        // A failing lane is the one whose load numbers matter most, so the
        // closing block hangs off EXIT, and it also releases the caller's slot.
        let invocationExit = try shellFunction(named: "finish_lane_invocation", in: laneRunnerScript)
        #expect(laneRunnerScript.contains("trap finish_lane_invocation EXIT"))
        #expect(invocationExit.contains("local exit_status=$?"))
        #expect(invocationExit.contains("print_closing_lane_report \"$exit_status\" || true"))
        #expect(invocationExit.contains("swift_build_slot_release || true"))
        #expect(invocationExit.contains("return \"$exit_status\""))
    }

    @Test("a child that dies by signal is named instead of swallowed")
    func childThatDiesBySignalIsNamedInsteadOfSwallowed() async throws {
        // A process that passes its tests and then crashes used to leave only
        // "ERROR task failed" and bash's job-table line; the captured output was
        // deleted before anyone could read why.
        let laneOutput = try await runBashAllowingFailure(
            "LOG_PREFIX=lane; TIMEOUT_SECONDS=60; BUILD_PATH=.build-agent-1; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'isolated suite: FakeSuite' 60 /bin/bash -c "
                + #"'echo \"Test run with 1 test in 1 suite passed\"; kill -SEGV $$' "#
                + "|| returned=$?; echo \"RETURNED=${returned:-0}\""
        )

        #expect(laneOutput.contains("exit_status=139"))
        #expect(laneOutput.contains("signal=SEGV"))
        #expect(laneOutput.contains("raw output tail for 'isolated suite: FakeSuite'"))
        // The tail is the point: the child's own output survives to the log.
        #expect(laneOutput.contains("Test run with 1 test in 1 suite passed"))
        #expect(laneOutput.contains("RETURNED=139"))
    }

    @Test("invalid child bytes do not break a passing lane or its failure diagnostics")
    func invalidChildBytesDoNotBreakLaneOutput() async throws {
        let fixtureDirectory = NSTemporaryDirectory() + "agentstudio-invalid-lane-output-\(UUIDv7.generate())"
        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=utf8-probe
            BUILD_PATH=.build-agent-1
            fixture_directory='\#(fixtureDirectory)'
            mkdir -p "$fixture_directory/events"
            export LANE_EVENT_STREAM_DIR="$fixture_directory/events"
            swift_test_begin_active_command_groups
            trap 'swift_test_cleanup_active_command_groups_directory; rm -f "$fixture_directory"/events/*; rmdir "$fixture_directory/events" "$fixture_directory"' EXIT

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

        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("PASS_CHILD_BEFORE"))
        #expect(result.output.contains("PASS_CHILD_AFTER"))
        #expect(result.output.contains("PASS_CHILD_STATUS=0"))
        #expect(result.output.contains("TESTS_PASSED"))
        #expect(result.output.contains("FAIL_CHILD_STATUS=7"))
    }

    @Test("lane stdout sources use one persistent line relay per stream")
    func laneStdoutSourcesUseOnePersistentLineRelayPerStream() throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let laneTaskScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let outputRelayScript = try String(contentsOfFile: "scripts/swift-test-output-relay.pl", encoding: .utf8)
        let outputRelayBegin = try shellFunction(named: "swift_test_output_relay_begin_command", in: helperScript)
        let outputRelayFinish = try shellFunction(named: "swift_test_output_relay_finish_command", in: helperScript)
        let commandWrapper = try shellFunction(named: "run_swift_with_timeout", in: helperScript)
        let commandBody = try shellFunction(named: "swift_test_run_with_timeout_body", in: helperScript)
        let pipelineChild = try shellFunction(named: "swift_test_run_pipeline_child", in: helperScript)
        let isolatedDispatcher = try shellFunction(named: "dispatch_isolated_suites", in: helperScript)

        let beginRange = commandWrapper.range(of: "swift_test_output_relay_begin_command")
        let bodyRange = commandWrapper.range(of: "swift_test_run_with_timeout_body")
        let finishRange = commandWrapper.range(of: "swift_test_output_relay_finish_command")
        #expect(beginRange != nil)
        #expect(bodyRange != nil)
        #expect(finishRange != nil)
        if let beginRange, let bodyRange, let finishRange {
            #expect(beginRange.lowerBound < bodyRange.lowerBound)
            #expect(bodyRange.lowerBound < finishRange.lowerBound)
        }

        #expect(commandBody.contains("still running ("))
        #expect(pipelineChild.contains("| $xcb_pipe 94>&- 99>&- |"))
        #expect(pipelineChild.contains("$SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH"))
        #expect(pipelineChild.contains("stream 94>&- 1>&99"))
        #expect(isolatedDispatcher.contains("swift_test_output_message"))
        #expect(laneTaskScript.contains("swift_test_output_relay_begin_dispatcher"))
        #expect(laneTaskScript.contains("swift_test_output_relay_finish_dispatcher"))
        #expect(outputRelayBegin.contains("exec 1>\"$relay_fifo\""))
        #expect(outputRelayFinish.contains("exec 1>&99"))
        #expect(outputRelayScript.contains("flock($lock_file, LOCK_EX)"))
        #expect(outputRelayScript.contains("substr($line, $offset, 512)"))
        #expect(outputRelayScript.contains("syswrite(STDOUT, $chunk)"))
    }

    @Test("signal names are resolved only for signalled exits")
    func signalNamesAreResolvedOnlyForSignalledExits() async throws {
        let names = try await runBash(
            "source scripts/swift-test-helpers.sh; "
                + "swift_test_signal_name 139; swift_test_signal_name 133; "
                + "swift_test_signal_name 1; swift_test_signal_name 0"
        )
        .split(separator: "\n").map(String.init)

        #expect(names == ["SEGV", "TRAP", "none", "none"])
    }

    @Test("one crashed isolated suite does not hide the suites after it")
    func oneCrashedIsolatedSuiteDoesNotHideTheSuitesAfterIt() async throws {
        // The rolling dispatcher must observe every child after one signal.
        let tallyPath = NSTemporaryDirectory() + "agentstudio-s2d-tally-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: tallyPath) }
        let laneOutput = try await runBashAllowingFailure(
            "LOG_PREFIX=lane; export SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE='\(tallyPath)'; "
                + ": >\"$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE\"; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "swift_test_isolated_process_concurrency() { echo 2; }; "
                + "run_selected_isolated_suite() { "
                + "if [ \"$2\" = CrashingSuite ]; then /bin/bash -c 'kill -SEGV $$'; "
                + "else echo SECOND_SUITE_RAN; fi; }; "
                + "lane_status=0; dispatch_isolated_suites fast CrashingSuite HealthySuite "
                + "|| lane_status=$?; echo \"LANE_STATUS=$lane_status\"; "
                + "echo \"COUNT=$(swift_test_failed_isolated_suite_count)\"; "
                + "cat \"$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE\""
        )

        // Both children ran; only the crashing one is recorded.
        #expect(laneOutput.contains("SECOND_SUITE_RAN"))
        #expect(laneOutput.contains("isolated suite failed: CrashingSuite"))
        #expect(!laneOutput.contains("isolated suite failed: HealthySuite"))
        #expect(laneOutput.contains("LANE_STATUS=1"))
        #expect(laneOutput.contains("COUNT=1"))
        #expect(laneOutput.contains("CrashingSuite\t139\tSEGV"))
    }

    @Test("the CPU count survives denied sysctl and getconf reads, as in agent sandboxes")
    func cpuCountSurvivesDeniedMachineReads() async throws {
        // Codex's Seatbelt sandbox denies the sysctl CLI. A lane that reads the
        // CPU count must fall back, not exit before any test runs.
        let fakeToolDirectory = NSTemporaryDirectory() + "agentstudio-denied-sysctl-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fakeToolDirectory) }
        let deniedToolScript = "#!/bin/sh\\necho denied >&2\\nexit 1\\n"
        let laneOutput = try await runBash(
            "mkdir -p '\(fakeToolDirectory)'; "
                + "printf '\(deniedToolScript)' > '\(fakeToolDirectory)/sysctl'; "
                + "chmod +x '\(fakeToolDirectory)/sysctl'; "
                + "source scripts/swift-test-helpers.sh; "
                + "PATH='\(fakeToolDirectory)':\"$PATH\"; "
                + "echo \"SYSCTL_DENIED_CPU=$(swift_test_cpu_count)\"; "
                + "echo \"SYSCTL_DENIED_CONCURRENCY=$(swift_test_isolated_process_concurrency)\"; "
                + "cp '\(fakeToolDirectory)/sysctl' '\(fakeToolDirectory)/getconf'; "
                + "echo \"ALL_DENIED_CPU=$(swift_test_cpu_count)\""
        )

        let reportedCounts = Dictionary(
            laneOutput.split(separator: "\n").compactMap { line -> (String, Int)? in
                let fields = line.split(separator: "=", maxSplits: 1)
                guard fields.count == 2, let count = Int(fields[1]) else { return nil }
                return (String(fields[0]), count)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        #expect((reportedCounts["SYSCTL_DENIED_CPU"] ?? 0) >= 1, Comment(rawValue: laneOutput))
        #expect((1...4).contains(reportedCounts["SYSCTL_DENIED_CONCURRENCY"] ?? 0), Comment(rawValue: laneOutput))
        #expect(reportedCounts["ALL_DENIED_CPU"] == 1, Comment(rawValue: laneOutput))
    }

    @Test("an isolated suite filter matches its type, never a file named after it")
    func isolatedSuiteFilterMatchesItsTypeNeverAFileNamedAfterIt() async throws {
        // Real ids captured from an event stream on this bundle. The third belongs
        // to a DIFFERENT suite that merely lives in RepoScannerTests.swift, and the
        // bare name selected it too: `--filter RepoScannerTests` admitted 2 suites
        // and 29 ids. Two process-global suites sharing one process is what
        // SIGSEGVed in CI 35276671883.
        let suiteIdentifier = "AgentStudioInfrastructureTests.RepoScannerTests"
        let ownFunctionIdentifier =
            "AgentStudioInfrastructureTests.RepoScannerTests/"
            + "cloneRootGitdirIndirectionsOutsideScannedPathAreFilteredOut()/RepoScannerTests.swift:234:6"
        let siblingIdentifier =
            "AgentStudioInfrastructureTests.RepoScannerClassificationTests/"
            + "gitDirectoryIsCloneRoot()/RepoScannerTests.swift:430:6"

        let matches = try await runBash(
            "source scripts/swift-test-helpers.sh; "
                + "pattern=$(swift_test_isolated_suite_filter_pattern RepoScannerTests); "
                + "echo \"PATTERN=$pattern\"; "
                + "for id in '\(suiteIdentifier)' '\(ownFunctionIdentifier)' '\(siblingIdentifier)'; do "
                + "if printf '%s' \"$id\" | /usr/bin/grep -Eq \"$pattern\"; "
                + "then echo MATCH; else echo NOMATCH; fi; done"
        )
        .split(separator: "\n").map(String.init)

        #expect(matches.first == "PATTERN=\\.RepoScannerTests(/|$)")
        // The suite's own id and its own functions are selected...
        #expect(matches.dropFirst().first == "MATCH")
        #expect(matches.dropFirst(2).first == "MATCH")
        // ...and the neighbour sharing the source file is not.
        #expect(matches.dropFirst(3).first == "NOMATCH")
    }

    @Test("every isolated per-process invocation anchors its suite filter")
    func everyIsolatedPerProcessInvocationAnchorsItsSuiteFilter() throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)

        // Fast and large isolated suites share one anchored invocation.
        #expect(
            helperScript.contains(
                "--filter \"$(swift_test_isolated_suite_filter_pattern \"$suite_filter\")\""
            ))
        let fastProcessInvocation = try shellFunction(
            named: "run_fast_serial_process_swift_tests",
            in: helperScript
        )
        #expect(
            fastProcessInvocation.contains(
                "--filter \"$(swift_test_isolated_suite_filter_pattern \"$fast_process_global_suite_filter\")\""
            ))
        let webKitInvocation = try shellFunction(named: "run_webkit_suite", in: helperScript)
        #expect(webKitInvocation.contains("--filter \"$filter\""))
        // Fast skips are generated from exact lane ownership, with the
        // aggregate isolated suites anchored by their own suite-type filters.
        #expect(helperScript.contains("--skip \"$fast_lane_skip_pattern\""))
        let fastRunner = try shellFunction(named: "run_fast_non_webkit_swift_tests", in: helperScript)
        #expect(fastRunner.contains("if ! fast_lane_skip_pattern=\"$(fast_non_webkit_skip_pattern)\"; then"))
        let skipBuilder = try shellFunction(named: "fast_non_webkit_skip_pattern", in: helperScript)
        #expect(skipBuilder.contains("$(swift_test_lane_fast_concurrent_skip_pattern)"))
        #expect(
            skipBuilder.contains(
                "if ! aggregate_serial_skip_filters=\"$(aggregate_serial_non_webkit_filter_pattern)\"; then"))
        #expect(
            skipBuilder.contains(
                "printf '%s|%s' \"$fast_lane_skip_filters\" \"$aggregate_serial_skip_filters\""
            ))
        #expect(!skipBuilder.contains("swift_test_isolated_suite_skip_pattern"))
        #expect(!skipBuilder.contains("large_non_webkit_filter_pattern"))
    }

    @Test("generated lane filters match only real test IDs in their lane")
    func generatedLaneFiltersMatchOnlyRealTestIds() async throws {
        let output = try await runBash(generatedLaneFilterBehaviorProbe)

        // The probe uses Swift Testing-shaped IDs from the real targets and Bash
        // ERE matching, the same regex dialect the lane filters are consumed as.
        guard output.contains("LANE_FILTER_BEHAVIOR_OK generators=9") else { return }
        #expect(output.contains("MATCH_OK fast-skip"))
        #expect(output.contains("MATCH_OK fast-concurrent-filter"))
        #expect(output.contains("MATCH_OK large-process-global"))
        #expect(output.contains("MATCH_OK aggregate-serial"))
        #expect(output.contains("MATCH_OK webkit-list"))
        #expect(output.contains("LANE_FILTER_BEHAVIOR_OK generators=9"))
    }

    @Test("a clean lane reports zero failed isolated suites")
    func cleanLaneReportsZeroFailedIsolatedSuites() async throws {
        let count = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_failed_isolated_suite_count"
        )

        // No tally file exported at all is the clean-lane case.
        #expect(count.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    @Test("the inactivity timeout names the test cases that were still running")
    func inactivityTimeoutNamesTheTestCasesThatWereStillRunning() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let timeoutRunner = try shellFunction(named: "swift_test_run_with_timeout_body", in: helperScript)
        // Case 1 of alpha ends; case 2 and beta do not, and the truncated final
        // line a killed writer leaves behind must not derail the parse.
        let streamRecords = [
            #"{\"kind\":\"testCaseStarted\",\"testID\":\"S/alpha(v:)\",\"_testCase\":{\"displayName\":\"v: 1\"}}"#,
            #"{\"kind\":\"testCaseStarted\",\"testID\":\"S/alpha(v:)\",\"_testCase\":{\"displayName\":\"v: 2\"}}"#,
            #"{\"kind\":\"testCaseEnded\",\"testID\":\"S/alpha(v:)\",\"_testCase\":{\"displayName\":\"v: 1\"}}"#,
            #"{\"kind\":\"testCaseStarted\",\"testID\":\"S/beta()\"}"#,
            #"{\"kind\":\"testCase"#,
        ].joined(separator: #"\n"#)
        let stillRunning = try await runBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; "
                + "print_running_parameterized_cases_at_timeout <(printf '\(streamRecords)\\n')"
        )
        let withoutStream = try await runBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; "
                + "print_running_parameterized_cases_at_timeout /nonexistent/event-stream"
        )
        let emptyStream = try await runBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; "
                + "print_running_parameterized_cases_at_timeout /dev/null"
        )

        #expect(timeoutRunner.contains("print_running_parameterized_cases_at_timeout \"$event_stream_file\""))
        #expect(
            stillRunning.split(separator: "\n").map(String.init) == [
                "[lane] lane-report running_parameterized_cases_at_timeout=S/alpha(v:) [v: 2]",
                "[lane] lane-report running_parameterized_cases_at_timeout=S/beta()",
            ]
        )
        // Missing stream and empty stream are different findings, so they read
        // differently rather than both looking like "nothing was running".
        #expect(withoutStream.contains("running_parameterized_cases_at_timeout=unavailable"))
        #expect(emptyStream.contains("running_parameterized_cases_at_timeout=none"))
    }

    @Test("the at-timeout case list is capped so one wedged lane cannot bury its log")
    func atTimeoutCaseListIsCappedSoOneWedgedLaneCannotBuryItsLog() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let idsFunction = try shellFunction(named: "swift_test_running_case_ids_from_events", in: helperScript)
        let cappedIDs = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_running_case_ids_from_events "
                + #"<(for index in $(seq 1 60); do printf '{"kind":"testCaseStarted","testID":"S/t%s()"}\n' "$index"; done)"#
        )

        #expect(idsFunction.contains("maximum_ids=\"${2:-40}\""))
        #expect(cappedIDs.split(separator: "\n").count == 40)
    }

    @Test("lane runner hang bounds default to the budgets CI already sets")
    func laneRunnerHangBoundsDefaultToBudgetsCIAlreadySets() throws {
        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let prebuildStep = try workflowStep(named: "Prebuild Swift test bundles", in: ciWorkflow)

        #expect(laneRunnerScript.contains("TIMEOUT_SECONDS=\"${SWIFT_TEST_TIMEOUT_SECONDS:-600}\""))
        #expect(
            laneRunnerScript.contains(
                "PREBUILD_TIMEOUT_SECONDS=\"${SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS:-1200}\""
            )
        )
        #expect(!laneRunnerScript.contains(":-60}"))
        #expect(!laneRunnerScript.contains(":-90}"))
        #expect(prebuildStep.contains("SWIFT_TEST_TIMEOUT_SECONDS: \"600\""))
        #expect(prebuildStep.contains("SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS: \"1200\""))
    }

    @Test("isolated suite process fan-out never exceeds the core count")
    func isolatedSuiteProcessFanOutNeverExceedsCoreCount() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let concurrencyFunction = try shellFunction(
            named: "swift_test_isolated_process_concurrency",
            in: helperScript
        )
        let observedConcurrency = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_isolated_process_concurrency"
        )
        // The oracle reads the core count in-process, not through the sysctl
        // command, which agent sandboxes deny.
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let concurrency = try #require(
            Int(observedConcurrency.trimmingCharacters(in: .whitespacesAndNewlines))
        )

        #expect(concurrencyFunction.contains("swift_test_cpu_count"))
        #expect(concurrency == min(4, coreCount))
        #expect(concurrency >= 1)
    }

    @Test("WebKit process fan-out stays at one for time-coupled Bridge waits")
    func webkitProcessFanOutStaysAtOneForTimeCoupledBridgeWaits() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let concurrencyFunction = try shellFunction(
            named: "swift_test_webkit_process_concurrency",
            in: helperScript
        )
        let observedConcurrency = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_webkit_process_concurrency"
        )

        #expect(concurrencyFunction.contains("SWIFT_TEST_WEBKIT_PROCESS_CONCURRENCY"))
        #expect(observedConcurrency.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("announced-test counter tracks posted start events, not the cap")
    func announcedTestCounterTracksPostedStartEvents() async throws {
        // a and b overlap (peak 2), a closes, then c opens (2 again). The
        // run-level and suite-level events are not tests.
        let observedPeak = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_peak_announced_from_output "
                + "<(printf '◇ Test run started.\\n"
                + "◇ Suite \"S\" started.\\n"
                + "◇ Test \"a\" started.\\n"
                + "◇ Test \"b\" started.\\n"
                + "✔ Test \"a\" passed after 0.1 seconds.\\n"
                + "◇ Test \"c\" started.\\n"
                + "✔ Test run with 3 tests in 1 suite passed after 0.5 seconds.\\n')"
        )

        #expect(observedPeak.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("running-test-case counter reads the post-serializer event stream")
    func runningTestCaseCounterReadsPostSerializerEventStream() async throws {
        // Two cases overlap before either ends, so the cap-observing peak is 2.
        let observedPeak = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_peak_running_cases_from_events "
                + "<(printf '{\"kind\":\"testCaseStarted\"}\\n"
                + "{\"kind\":\"testCaseStarted\"}\\n"
                + "{\"kind\":\"testCaseEnded\"}\\n"
                + "{\"kind\":\"testCaseStarted\"}\\n"
                + "{\"kind\":\"testCaseEnded\"}\\n"
                + "{\"kind\":\"testCaseEnded\"}\\n')"
        )
        let emptyStreamPeak = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_peak_running_cases_from_events /dev/null"
        )

        #expect(observedPeak.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        #expect(emptyStreamPeak.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    @Test("event-stream flags reach every test invocation but not the prebuild")
    func eventStreamFlagsReachEveryTestInvocationButNotThePrebuild() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let timeoutRunner = try shellFunction(named: "swift_test_run_with_timeout_body", in: helperScript)
        let acceptsEventStream = try shellFunction(
            named: "swift_test_command_accepts_event_stream",
            in: helperScript
        )

        #expect(timeoutRunner.contains("--event-stream-version 0 --event-stream-output-path"))
        #expect(timeoutRunner.contains("swift_test_command_accepts_event_stream"))
        // `swift build` rejects the flags, so the prebuild must be excluded.
        #expect(acceptsEventStream.contains("\"$argument\" = \"build\""))
        #expect(
            try await runBashStatus(
                "source scripts/swift-test-helpers.sh; "
                    + "swift_test_command_accepts_event_stream swift build --build-tests"
            ) == 1
        )
        #expect(
            try await runBashStatus(
                "source scripts/swift-test-helpers.sh; "
                    + "swift_test_command_accepts_event_stream swift test --skip-build"
            ) == 0
        )
    }
}

/// Every `lane-report <label>=` key the shell scripts can emit, sorted. A label
/// followed by fields (`held_step_unarrived name=… test=…`) counts too; prose
/// such as "lane-report prefix as" does not.
private func laneReportLabels(in script: String) -> [String] {
    let marker = "lane-report "
    var labels: Set<String> = []

    for line in script.split(separator: "\n") {
        guard let markerRange = line.range(of: marker) else { continue }
        let label = line[markerRange.upperBound...].prefix { $0.isLowercase || $0 == "_" }
        let afterLabel = line[markerRange.upperBound...].dropFirst(label.count)
        let firstFieldName = afterLabel.dropFirst().prefix { $0.isLowercase || $0 == "_" }
        let startsFields =
            afterLabel.first == " " && !firstFieldName.isEmpty
            && afterLabel.dropFirst(1 + firstFieldName.count).first == "="
        guard !label.isEmpty, afterLabel.first == "=" || startsFields else { continue }
        labels.insert(String(label))
    }
    return labels.sorted()
}

private func workflowStep(named stepName: String, in workflow: String) throws -> String {
    try namedBlock(
        startingWith: "      - name: \(stepName)",
        endingBefore: "\n      - name: ",
        in: workflow
    )
}

private func shellFunction(named functionName: String, in script: String) throws -> String {
    try namedBlock(
        startingWith: "\(functionName)() {",
        endingBefore: "\n}\n",
        in: script
    )
}

private func namedBlock(startingWith marker: String, endingBefore terminator: String, in text: String) throws
    -> String
{
    guard let startRange = text.range(of: marker) else {
        throw SwiftLaneRunnerReportError.missingBlock(marker)
    }
    let tail = text[startRange.lowerBound...]
    guard let endRange = tail.range(of: terminator, range: tail.index(after: startRange.lowerBound)..<tail.endIndex)
    else {
        return String(tail)
    }
    return String(tail[..<endRange.lowerBound])
}

private func runBash(_ command: String) async throws -> String {
    let result = try await runLaneScriptBash(command)
    #expect(result.exitCode == 0, Comment(rawValue: result.output))
    return result.output
}

/// Like `runBash`, but for scripts that deliberately fail: these tests drive
/// crashing children, so a non-zero status is the expected outcome.
private func runBashAllowingFailure(_ command: String) async throws -> String {
    (try await runLaneScriptBash(command)).output
}

private func runBashStatus(_ command: String) async throws -> Int32 {
    (try await runLaneScriptBash(command)).exitCode
}

private enum SwiftLaneRunnerReportError: Error {
    case missingBlock(String)
}
