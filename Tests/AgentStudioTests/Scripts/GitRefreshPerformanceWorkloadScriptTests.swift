import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite(.serialized)
struct GitRefreshPerformanceWorkloadScriptTests {
    @Test("workload proof script has stable safety contract and bash syntax")
    func workloadProofScriptHasStableSafetyContractAndBashSyntax() async throws {
        let syntax = try await runScript(arguments: ["-n", scriptPath])
        let cleanupSyntax = try await runScript(arguments: ["-n", cleanupScriptPath])
        let comparisonSyntax = try await runScript(arguments: ["-n", comparisonScriptPath])
        let comparisonPythonSyntax = try await runCommandToExit(
            command: try await TestToolResolver.resolved().python3.path,
            arguments: ["-m", "py_compile", comparisonPythonScriptPath])
        #expect(syntax.exitCode == 0)
        #expect(cleanupSyntax.exitCode == 0)
        #expect(comparisonSyntax.exitCode == 0, Comment(rawValue: comparisonSyntax.stderr))
        #expect(comparisonPythonSyntax.exitCode == 0, Comment(rawValue: comparisonPythonSyntax.stderr))

        let source = try String(contentsOf: URL(fileURLWithPath: scriptPath), encoding: .utf8)
        Self.expectSharedObservabilityContract(source)
        Self.expectDebugRunnerContract(source)
        Self.expectVictoriaProofContract(source)
        Self.expectJSONLProofGuard(source)
        Self.expectFixtureAndCleanupContract(source)
        Self.expectStrictSQLiteFixtureAndQuiescenceContract(source)
    }

    @Test("owned zmx cleanup kills exact IDs and fails closed on prefix collisions")
    func ownedZmxCleanupKillsExactIDsAndFailsClosedOnPrefixCollisions() async throws {
        let fixtureRoot = URL(fileURLWithPath: "/tmp/asw.test-\(UUID().uuidString)")
        let fakeZmx = fixtureRoot.appendingPathComponent("zmx")
        let inventory = fixtureRoot.appendingPathComponent("inventory")
        let calls = fixtureRoot.appendingPathComponent("calls")
        let artifact = fixtureRoot.appendingPathComponent("cleanup.env")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try "owned\nowned-suffix\nindependent\n".write(to: inventory, atomically: true, encoding: .utf8)
        try "".write(to: calls, atomically: true, encoding: .utf8)
        try """
        #!/bin/bash
        set -euo pipefail
        case "$1" in
          list)
            sed 's/^/name=/; s/$/\\tpid=1/' "$FAKE_ZMX_INVENTORY"
            ;;
          kill)
            printf '%s\\n' "$2" >>"$FAKE_ZMX_CALLS"
            grep -vxF "$2" "$FAKE_ZMX_INVENTORY" >"$FAKE_ZMX_INVENTORY.next" || true
            mv "$FAKE_ZMX_INVENTORY.next" "$FAKE_ZMX_INVENTORY"
            ;;
        esac
        """.write(to: fakeZmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)

        let result = try await runScript(
            arguments: [cleanupScriptPath, fakeZmx.path, fixtureRoot.path, artifact.path, "owned", "independent"],
            environment: [
                "FAKE_ZMX_INVENTORY": inventory.path,
                "FAKE_ZMX_CALLS": calls.path,
                "OWNED_ZMX_LIST_DEADLINE_SECONDS": "none",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "independent\n")
        let cleanupArtifact = try String(contentsOf: artifact, encoding: .utf8)
        #expect(cleanupArtifact.contains("collision_owned_id=owned"))
        #expect(cleanupArtifact.contains("collision_session_name=owned-suffix"))
        #expect(cleanupArtifact.contains("unresolved_session_id=owned"))
    }

    @Test("owned zmx cleanup recognizes padded inventory names and verifies exact IDs are absent")
    func ownedZmxCleanupRecognizesPaddedInventoryNames() async throws {
        try await verifyOwnedZmxCleanupWithPaddedInventory(listDeadline: "none")
    }

    func verifyOwnedZmxCleanupWithPaddedInventory(listDeadline: String) async throws {
        let fixtureRoot = URL(fileURLWithPath: "/tmp/asw.padded-\(UUIDv7.generate().uuidString)")
        let fakeZmx = fixtureRoot.appendingPathComponent("zmx")
        let inventory = fixtureRoot.appendingPathComponent("inventory")
        let calls = fixtureRoot.appendingPathComponent("calls")
        let artifact = fixtureRoot.appendingPathComponent("cleanup.env")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try "owned\nindependent\n".write(to: inventory, atomically: true, encoding: .utf8)
        try "".write(to: calls, atomically: true, encoding: .utf8)
        try """
        #!/bin/bash
        set -euo pipefail
        case "$1" in
          list)
            while IFS= read -r session_name; do
              printf '  name=%s\\tpid=1\\n' "$session_name"
            done <"$FAKE_ZMX_INVENTORY"
            ;;
          kill)
            printf '%s\\n' "$2" >>"$FAKE_ZMX_CALLS"
            grep -vxF "$2" "$FAKE_ZMX_INVENTORY" >"$FAKE_ZMX_INVENTORY.next" || true
            mv "$FAKE_ZMX_INVENTORY.next" "$FAKE_ZMX_INVENTORY"
            ;;
        esac
        """.write(to: fakeZmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)

        let result = try await runScript(
            arguments: [cleanupScriptPath, fakeZmx.path, fixtureRoot.path, artifact.path, "owned", "independent"],
            environment: [
                "FAKE_ZMX_INVENTORY": inventory.path,
                "FAKE_ZMX_CALLS": calls.path,
                "OWNED_ZMX_LIST_DEADLINE_SECONDS": listDeadline,
            ]
        )

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: calls, encoding: .utf8) == "owned\nindependent\n")
        #expect(try String(contentsOf: inventory, encoding: .utf8).isEmpty)
        let cleanupArtifact = try String(contentsOf: artifact, encoding: .utf8)
        #expect(cleanupArtifact.contains("attempted_session_id=owned"))
        #expect(cleanupArtifact.contains("attempted_session_id=independent"))
        #expect(cleanupArtifact.contains("cleanup_status=verified_clean"))
    }

    @Test("owned zmx cleanup reports a hung inventory call")
    func ownedZmxCleanupReportsHungInventoryCall() async throws {
        let fixtureRoot = URL(fileURLWithPath: "/tmp/asw.hung-\(UUIDv7.generate().uuidString)")
        let fakeZmx = fixtureRoot.appendingPathComponent("zmx")
        let inventoryFIFO = fixtureRoot.appendingPathComponent("inventory-fifo")
        let artifact = fixtureRoot.appendingPathComponent("cleanup.env")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        #expect(mkfifo(inventoryFIFO.path, 0o600) == 0)
        try "#!/bin/bash\nIFS= read -r ignored < '\(inventoryFIFO.path)'\n"
            .write(to: fakeZmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)

        let result = try await runScript(
            arguments: [cleanupScriptPath, fakeZmx.path, fixtureRoot.path, artifact.path, "owned"],
            environment: ["OWNED_ZMX_LIST_DEADLINE_SECONDS": "0"]
        )

        #expect(result.exitCode == 1)
        let cleanupArtifact = try String(contentsOf: artifact, encoding: .utf8)
        #expect(cleanupArtifact.contains("list_error=timeout"))
        #expect(cleanupArtifact.contains("unresolved_session_id=owned"))
    }

    @Test("owned zmx cleanup rejects production beta and ordinary debug roots before inspection")
    func ownedZmxCleanupRejectsProtectedRootsBeforeInspection() async throws {
        for protectedRoot in [
            "/Users/test/.agentstudio/z",
            "/Users/test/.agent-studio-b/z",
            "/Users/test/.agentstudio-db/abcd/z",
        ] {
            let result = try await runScript(
                arguments: [
                    cleanupScriptPath, "/must-not-run/zmx", protectedRoot, "/tmp/protected-root-cleanup.env", "owned",
                ]
            )

            #expect(result.exitCode == 2)
            #expect(result.stderr.contains("refusing zmx cleanup outside a disposable workload root"))
        }
    }

    @Test("required performance metric inventory gates git lanes without topology lookups")
    func requiredPerformanceMetricInventoryGatesGitLanesWithoutTopologyLookups() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: scriptPath), encoding: .utf8)
        let inventoryStart = try #require(
            source.range(of: "required_performance_metric_event_names() {")
        )
        let inventoryEnd = try #require(
            source.range(
                of: "\n}\n\nmissing_required_performance_metric_events()",
                range: inventoryStart.upperBound..<source.endIndex
            )
        )
        let inventory = source[inventoryStart.lowerBound..<inventoryEnd.lowerBound]

        #expect(!inventory.contains("performance.topology.repo_and_worktree"))
        #expect(source.contains("wait_for_trace_event performance.git.status 30"))
        #expect(source.contains("require_status_latency_metrics"))
    }

    private static func expectSharedObservabilityContract(_ source: String) {
        #expect(source.contains("standard per-worktree debug observability"))
        #expect(source.contains("VictoriaMetrics performance evidence"))
        #expect(source.contains("LOGS_QUERY_URL="))
        #expect(source.contains("METRICS_QUERY_URL="))
        #expect(source.contains("AI_TOOLS_OBSERVABILITY_STACK_HELPER"))
        #expect(source.contains("$HOME/dev/ai-tools/observability/observability-stack"))
        #expect(!source.contains("SHRAVAN_OBSERVABILITY"))
        #expect(!source.contains("$HOME/dev/devfiles/shared/observability/observability-stack"))
        #expect(source.contains("Set >=255 when this script is used to cover"))
        #expect(source.contains("AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR"))
        #expect(source.contains("AGENTSTUDIO_PERF_SAMPLE_DURING_WORKLOAD"))
        #expect(source.contains("Default: 0 so sampling cannot perturb"))
        #expect(source.contains("AGENTSTUDIO_PERF_ALLOW_JSONL_PROOF"))
        #expect(source.contains("AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES"))
        #expect(source.contains("standard proof requires Victoria"))
        #expect(source.contains("AGENTSTUDIO_OBSERVABILITY_STATE_FILE"))
        #expect(source.contains("DEFAULT_UI_PROOF_ROOT=\"/tmp/asperf\""))
        #expect(source.contains("absolute_path()"))
        #expect(source.contains("PROOF_ROOT=\"$(absolute_path \"$AGENTSTUDIO_PERF_PROOF_ROOT\")\""))
        #expect(source.contains("validate_trace_name()"))
        #expect(source.contains("safe path component"))
        #expect(source.contains("elif [ \"$DRIVE_COMMAND_BAR\" = \"1\" ]; then"))
        #expect(source.contains("TRACE_NAME=\"$(validate_trace_name \"perf-$(date +%H%M%S)-$$\")\""))
    }

    private static func expectDebugRunnerContract(_ source: String) {
        #expect(source.contains("load_debug_identity_for_workload()"))
        #expect(source.contains("\"$PROJECT_ROOT/scripts/run-debug-observability.sh\" --print-identity"))
        #expect(source.contains("DEBUG_IDENTITY_DATA_DIR=\"$(decode_env_file_value"))
        #expect(source.contains("RUNTIME_DATA_ROOT=\"$(mktemp -d /tmp/asw.XXXXXX)\""))
        #expect(source.contains("WORKLOAD_ZMX_DIR=\"$RUNTIME_DATA_ROOT/z\""))
        #expect(source.contains("WORKLOAD_ZMX_EXECUTABLE=\"$RUNTIME_DATA_ROOT/bin/zmx\""))
        #expect(source.contains("TRACE_DIR=\"$ARTIFACT/traces\""))
        #expect(source.contains("launch_debug_observability_app()"))
        #expect(source.contains("\"$PROJECT_ROOT/scripts/run-debug-observability.sh\" --detach"))
        #expect(source.contains("\"$PROJECT_ROOT/scripts/verify-debug-observability.sh\""))
        #expect(
            source.contains(
                "WORKLOAD_TRACE_TAGS=\"${AGENTSTUDIO_TRACE_TAGS:-performance,app.startup,terminal.startup}\""))
        #expect(source.contains("AGENTSTUDIO_TRACE_TAGS=$WORKLOAD_TRACE_TAGS"))
        #expect(source.contains("AGENTSTUDIO_TRACE_NAME=$TRACE_NAME"))
        #expect(source.contains("AGENTSTUDIO_TRACE_DIR=$TRACE_DIR"))
        #expect(source.contains("AGENTSTUDIO_DEBUG_DATA_DIR=$RUNTIME_DATA_ROOT"))
        #expect(source.contains("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=command-bar-repo-filter"))
        #expect(source.contains("APP_PID=\"$(decode_env_file_value"))
        #expect(source.contains("DEBUG_STATE_COPY=\"$ARTIFACT/debug-observability.env\""))
        #expect(source.contains("cp \"$DEBUG_OBSERVABILITY_STATE_FILE\" \"$DEBUG_STATE_COPY\""))
        assertVictoriaMetricsContract(source)
        #expect(source.contains("preflight_debug_observability_idle()"))
        #expect(source.contains("\"$PROJECT_ROOT/scripts/run-debug-observability.sh\" --preflight-idle"))
        #expect(source.contains("QUERY_START=\"$(decode_env_file_value"))
        #expect(source.contains("--data-urlencode \"start=$QUERY_START\""))
        #expect(source.contains("SAMPLE_DURING_WORKLOAD=\"${AGENTSTUDIO_PERF_SAMPLE_DURING_WORKLOAD:-0}\""))
        #expect(source.contains("sample_during_workload=$SAMPLE_DURING_WORKLOAD"))
        #expect(source.contains("[ \"$SAMPLE_DURING_WORKLOAD\" = \"1\" ]"))
        #expect(source.contains("sample skipped during measured workload"))
        assertGitStatusMetricSummaryContract(source)
        #expect(source.contains("capture_restore_trace"))
        #expect(source.contains("grep \"pid=$APP_PID \" \"$restore_trace_source\""))
        #expect(
            source.contains("did not observe performance.coordinator.write within startup timeout\" >&2\n  sample_app"))
        #expect(source.contains("startup diagnostic command-bar repo filter smoke for PID"))
        #expect(source.contains("driver=startup-diagnostic"))
        #expect(source.contains("action=command-bar-repo-filter"))
        #expect(source.contains("startup command-bar repo filter smoke"))
        #expect(source.contains("wait_for_command_bar_repo_filter_event"))
        #expect(source.contains("wait_for_startup_diagnostic_completion"))
        #expect(source.contains("app.startup_diagnostic_action.completed"))
        #expect(source.contains("app.startup_diagnostic_action.blocked"))
        #expect(source.contains("startup diagnostic reported blocked"))
        #expect(
            source.contains(
                "perf:report candidate selection requires AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR=1"
            )
        )
        #expect(source.contains("agentstudio.performance.commandbar.query_character.count\\\":\\\"?[1-9][0-9]*\\\"?"))
    }

    private static func expectVictoriaProofContract(_ source: String) {
        #expect(source.contains("query_victoria_logs()"))
        #expect(source.contains("query_victoria_metrics()"))
        #expect(source.contains("logsql_escape_exact_value()"))
        #expect(source.contains("logsql_exact_filter()"))
        #expect(source.contains("victoria_event_query()"))
        #expect(
            source.contains(
                "printf '{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"} %s %s'"
            ))
        #expect(
            source.contains("$(logsql_exact_filter \"agent.proof.marker\" \"$TRACE_NAME\")")
        )
        #expect(source.contains("$(logsql_exact_filter \"_msg\" \"$event_name\")"))
        #expect(!source.contains("agent.proof.marker:%s"))
        #expect(!source.contains("_msg:%s"))
        #expect(source.contains("victoria_event_count()"))
        #expect(
            source.contains(
                #"if [ "$(victoria_event_count "$event_name")" -gt 0 ]; then"#
            )
        )
        #expect(
            !source.contains(
                #"if [ "$(victoria_metric_event_count "$event_name")" -gt 0 ]; then"#
            )
        )
        #expect(source.contains("victoria_metric_event_query()"))
        #expect(source.contains("victoria_metric_event_count()"))
        #expect(source.contains("agentstudio_performance_events_total"))
        #expect(source.contains("agent.proof.marker=\"%s\",event=\"%s\""))
        #expect(source.contains("agentstudio_performance_event_elapsed_ms_bucket"))
        #expect(source.contains("histogram_quantile(0.95"))
        #expect(source.contains("victoria_event_elapsed_max()"))
        #expect(source.contains("victoria_metric_command_bar_filter_query()"))
        #expect(source.contains("agentstudio_performance_commandbar_query_character_count"))
        #expect(source.contains("performance.coordinator.write \\"))
        #expect(
            source.contains(
                "echo \"$event_name victoria_metrics_count=$victoria_metrics_count victoria_logs_count=$victoria_logs_count jsonl_count=$jsonl_count\""
            ))
        #expect(source.contains("allow_jsonl_proof=$ALLOW_JSONL_PROOF"))
        #expect(
            source.contains(
                "query_character_max=\"$(victoria_log_command_bar_filter_query_character_max)\""
            )
        )
        #expect(source.contains("performance.commandbar.filter.query_character.max="))
        let summaryMetadataKeys =
            "source_head source_digest executable_digest trace_tags activation_mode launch_method "
            + "executable_identity worktree_identity issued_interaction_count regression_boundary_percent "
            + "performance.tabbar.capture_count performance.tabbar.terminal_count "
            + "performance.tabbar.lifecycle_exact performance.tabbar.duplicate_capture_sequence_count "
            + "performance.tabbar.duplicate_terminal_sequence_count performance.tabbar.missing_terminal_sequence_count "
            + "performance.tabbar.unexpected_terminal_sequence_count performance.tabbar.invalid_terminal_outcome_count "
            + "agentstudio.performance.trace_queue.dropped_record.count "
            + "agentstudio.performance.trace_queue.high_watermark "
            + "final_tab_count_equivalent final_active_tab_equivalent final_membership_equivalent "
            + "workload_fingerprint required_performance_metric_minimum_count "
            + "required_commandbar_query_character_minimum"
        for metadataKey in summaryMetadataKeys.split(separator: " ") {
            #expect(source.contains("echo \"\(metadataKey)="))
        }
        #expect(source.contains("workload_fingerprint()"))
        #expect(source.contains("source_digest()"))
        #expect(source.contains("capture_authenticated_final_state_oracle()"))
        #expect(source.contains("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=1"))
        #expect(source.contains("performance.tabbar.terminal"))
        #expect(source.contains("performance.tabbar.capture"))
        #expect(source.contains("performance.tabbar.current"))
        #expect(source.contains("performance.tabbar.publication"))
        #expect(source.contains("performance.tabbar.visible"))
        #expect(source.contains("performance.tabbar.worker"))
        #expect(source.contains("agentstudio_performance_trace_queue_dropped_record_count"))
        #expect(source.contains("agentstudio_performance_trace_queue_high_watermark"))
        #expect(source.contains("AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE"))
        #expect(source.contains("AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD"))
        #expect(source.contains("tabbar_lifecycle_continuity=query_failed"))
        #expect(!source.contains("tabbar_lifecycle_continuity=not_available"))
    }

    private static func expectJSONLProofGuard(_ source: String) {
        #expect(source.contains("jsonl_proof_enabled()"))
        #expect(source.contains("current_trace_jsonl_files()"))
        #expect(source.contains("find \"$TRACE_DIR\" -maxdepth 1 -name \"agentstudio-$TRACE_NAME-*.jsonl\""))
        #expect(source.contains("fail_if_trace_marker_would_reuse_jsonl()"))
        #expect(source.contains("trace marker already has JSONL files"))
        #expect(source.contains("jsonl_proof_enabled && current_trace_jsonl_has_event \"$event_name\""))
        #expect(source.contains("jsonl_proof_enabled && current_trace_jsonl_has_command_bar_filter"))
        #expect(!source.contains("if current_trace_jsonl_has_event \"$event_name\"; then"))
        #expect(!source.contains("if current_trace_jsonl_has_command_bar_filter; then"))
        #expect(!source.contains("grep -R \"\\\"body\\\":\\\"$event_name\\\"\" \"$TRACE_DIR\""))
        #expect(!source.contains("grep -R \"\\\"body\\\":\\\"performance.commandbar.filter\\\"\" \"$TRACE_DIR\""))
    }

    private static func expectFixtureAndCleanupContract(_ source: String) {
        #expect(!source.contains("AGENTSTUDIO_PERF_APP_BINARY"))
        #expect(!source.contains("AGENTSTUDIO_PERF_APP_BUNDLE"))
        #expect(!source.contains("AGENTSTUDIO_PERF_SKIP_BUILD"))
        #expect(!source.contains("AGENTSTUDIO_PERF_TRACE_BACKEND"))
        #expect(!source.contains("AgentStudio Performance Proof.app"))
        #expect(!source.contains("materialize_app_bundle_for_ui_smoke"))
        #expect(!source.contains("AGENTSTUDIO_DATA_DIR=\"$APP_DATA_DIR\""))
        #expect(!source.contains("mise run build"))
        #expect(!source.contains("ps -axo pid=,command="))
        #expect(!source.contains("pgrep -f \"$app_binary\""))
        #expect(source.contains("osascript") == false)
        #expect(source.contains("key code 35") == false)
        #expect(source.contains("cmd-P smoke") == false)
        #expect(source.contains("performance.commandbar.filter"))
        #expect(source.contains("git init \"$repo_dir\""))
        #expect(source.contains("git -C \"$repo_dir\" config user.email"))
        #expect(source.contains("mkdir -p \"$(dirname \"$worktree_dir\")\""))
        #expect(source.contains("commit.gpgsign false"))
        #expect(source.contains("tag.gpgsign false"))
        #expect(source.contains("stop_pid \"$APP_PID\""))
        #expect(source.contains("$ZMX_CLEANUP_SCRIPT"))
        #expect(source.contains("${ZMX_SESSION_IDS[@]}"))
        #expect(source.contains("pkill") == false)
        #expect(source.contains("AGENTSTUDIO_PERF_ACTIVE_PANES"))
    }

    @Test("prepare-only summary emits comparable Victoria metric fields")
    func prepareOnlySummaryEmitsComparableVictoriaMetricFields() async throws {
        let proofRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-workload-summary-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: proofRoot)
        }

        let result = try await runScript(
            arguments: [scriptPath, "--prepare-only"],
            environment: [
                "AGENTSTUDIO_PERF_PROOF_ROOT": proofRoot.path,
                "AGENTSTUDIO_TRACE_NAME": "summary-shape-test",
                "AGENTSTUDIO_PERF_REPO_COUNT": "1",
                "AGENTSTUDIO_PERF_WORKTREE_COUNT": "1",
                "AGENTSTUDIO_PERF_ACTIVE_PANES": "1",
                "AGENTSTUDIO_PERF_WRITER_COUNT": "1",
                "AGENTSTUDIO_PERF_DURATION_SECONDS": "1",
                "AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR": "0",
                "AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES": "1",
                "AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL": "http://127.0.0.1:1/select/logsql/query",
                "AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL": "http://127.0.0.1:1/api/v1/query",
                "AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE":
                    #"{"status":"success","data":{"result":[{"value":[0,"0"]}]}}"#,
                "AGENTSTUDIO_PERF_TEST_LOGS_RESPONSE":
                    #"{"_msg":"performance.tabbar.capture","agentstudio.performance.tabbar.sequence":"1","agentstudio.performance.elapsed_ms":"3","agentstudio.performance.commandbar.query_character.count":"3"}"#
                    + "\n"
                    + #"{"_msg":"performance.tabbar.terminal","agentstudio.performance.tabbar.sequence":"1","agentstudio.performance.tabbar.terminal.outcome":"published","agentstudio.performance.elapsed_ms":"7","agentstudio.performance.commandbar.query_character.count":"7"}"#
                    + "\n",
            ]
        )

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))

        let summaryURL =
            proofRoot
            .appendingPathComponent("summary-shape-test")
            .appendingPathComponent("summary.txt")
        let summary = try String(contentsOf: summaryURL, encoding: .utf8)
        for eventName in Self.comparablePerformanceEventNames {
            #expect(summary.contains("\(eventName).victoria_metrics_count=0"))
            #expect(summary.contains("\(eventName).victoria_logs_count=2"))
            #expect(summary.contains("\(eventName).elapsed_ms.max=7"))
            #expect(summary.contains("\(eventName).elapsed_ms.p95=0"))
            #expect(summary.contains("\(eventName).elapsed_ms.p95_unavailable=false"))
        }
        #expect(summary.contains("performance.commandbar.filter.query_character.max=7"))
        #expect(summary.contains("performance.tabbar.lifecycle_exact=true"))
        #expect(summary.contains("performance.tabbar.duplicate_capture_sequence_count=0"))
        #expect(summary.contains("performance.tabbar.missing_terminal_sequence_count=0"))
    }

    @Test("prepare-only workload proof rejects duplicate and missing tab bar lifecycle sequences")
    func prepareOnlyWorkloadProofRejectsInvalidTabBarLifecycleSequences() async throws {
        let proofRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-workload-lifecycle-rejection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: proofRoot) }

        let result = try await runScript(
            arguments: [scriptPath, "--prepare-only"],
            environment: [
                "AGENTSTUDIO_PERF_PROOF_ROOT": proofRoot.path,
                "AGENTSTUDIO_TRACE_NAME": "invalid-lifecycle-test",
                "AGENTSTUDIO_PERF_REPO_COUNT": "1",
                "AGENTSTUDIO_PERF_WORKTREE_COUNT": "1",
                "AGENTSTUDIO_PERF_ACTIVE_PANES": "1",
                "AGENTSTUDIO_PERF_WRITER_COUNT": "1",
                "AGENTSTUDIO_PERF_DURATION_SECONDS": "1",
                "AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR": "0",
                "AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES": "1",
                "AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL": "http://127.0.0.1:1/select/logsql/query",
                "AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL": "http://127.0.0.1:1/api/v1/query",
                "AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE":
                    #"{"status":"success","data":{"result":[{"value":[0,"7"]}]}}"#,
                "AGENTSTUDIO_PERF_TEST_LOGS_RESPONSE":
                    #"{"_msg":"performance.tabbar.capture","agentstudio.performance.tabbar.sequence":"1"}"#
                    + "\n"
                    + #"{"_msg":"performance.tabbar.capture","agentstudio.performance.tabbar.sequence":"1"}"#
                    + "\n"
                    + #"{"_msg":"performance.tabbar.capture","agentstudio.performance.tabbar.sequence":"2"}"#
                    + "\n"
                    + #"{"_msg":"performance.tabbar.terminal","agentstudio.performance.tabbar.sequence":"1","agentstudio.performance.tabbar.terminal.outcome":"published"}"#
                    + "\n",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("duplicate capture sequences"))
        #expect(result.stderr.contains("missing terminal sequences"))
    }

    @Test("prepare-only workload proof rejects missing trace queue completeness metrics")
    func prepareOnlyWorkloadProofRejectsMissingTraceQueueCompletenessMetrics() async throws {
        let proofRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-workload-trace-queue-rejection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: proofRoot) }

        let result = try await runScript(
            arguments: [scriptPath, "--prepare-only"],
            environment: [
                "AGENTSTUDIO_PERF_PROOF_ROOT": proofRoot.path,
                "AGENTSTUDIO_TRACE_NAME": "missing-trace-queue-test",
                "AGENTSTUDIO_PERF_REPO_COUNT": "1",
                "AGENTSTUDIO_PERF_WORKTREE_COUNT": "1",
                "AGENTSTUDIO_PERF_ACTIVE_PANES": "1",
                "AGENTSTUDIO_PERF_WRITER_COUNT": "1",
                "AGENTSTUDIO_PERF_DURATION_SECONDS": "1",
                "AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR": "0",
                "AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES": "1",
                "AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL": "http://127.0.0.1:1/select/logsql/query",
                "AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL": "http://127.0.0.1:1/api/v1/query",
                "AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE": "",
                "AGENTSTUDIO_PERF_TEST_LOGS_RESPONSE":
                    #"{"_msg":"performance.tabbar.capture","agentstudio.performance.tabbar.sequence":"1"}"#
                    + "\n"
                    + #"{"_msg":"performance.tabbar.terminal","agentstudio.performance.tabbar.sequence":"1","agentstudio.performance.tabbar.terminal.outcome":"published"}"#
                    + "\n",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("trace queue completeness metrics are missing"))
    }

    @Test("prepare-only workload proof reports lifecycle query transport failure")
    func prepareOnlyWorkloadProofReportsLifecycleQueryTransportFailure() async throws {
        let proofRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-workload-lifecycle-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: proofRoot) }

        let result = try await runScript(
            arguments: [scriptPath, "--prepare-only"],
            environment: [
                "AGENTSTUDIO_PERF_PROOF_ROOT": proofRoot.path,
                "AGENTSTUDIO_TRACE_NAME": "lifecycle-transport-test",
                "AGENTSTUDIO_PERF_REPO_COUNT": "1",
                "AGENTSTUDIO_PERF_WORKTREE_COUNT": "1",
                "AGENTSTUDIO_PERF_ACTIVE_PANES": "1",
                "AGENTSTUDIO_PERF_WRITER_COUNT": "1",
                "AGENTSTUDIO_PERF_DURATION_SECONDS": "1",
                "AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR": "0",
                "AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES": "1",
                "AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL": "http://127.0.0.1:1/select/logsql/query",
                "AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL": "http://127.0.0.1:1/api/v1/query",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("VictoriaLogs Tab Bar capture query failed"))
    }

    @Test("workload proof rejects canned query responses outside prepare-only tests")
    func workloadProofRejectsCannedQueryResponsesOutsidePrepareOnlyTests() async throws {
        let proofRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-workload-test-response-guard-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: proofRoot)
        }

        let result = try await runScript(
            arguments: [scriptPath],
            environment: [
                "AGENTSTUDIO_PERF_PROOF_ROOT": proofRoot.path,
                "AGENTSTUDIO_TRACE_NAME": "test-response-guard",
                "AGENTSTUDIO_PERF_REPO_COUNT": "1",
                "AGENTSTUDIO_PERF_WORKTREE_COUNT": "1",
                "AGENTSTUDIO_PERF_ACTIVE_PANES": "1",
                "AGENTSTUDIO_PERF_WRITER_COUNT": "1",
                "AGENTSTUDIO_PERF_DURATION_SECONDS": "1",
                "AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL": "http://127.0.0.1:1/",
                "AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE":
                    #"{"status":"success","data":{"result":[{"value":[0,"7"]}]}}"#,
            ]
        )

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE"))
        #expect(result.stderr.contains("AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES"))
    }

    @Test("workload fixture materializes and reloads through strict SQLite")
    func workloadFixtureMaterializesThroughStrictSQLite() async throws {
        let input = try fixtureMaterializationInput(environment: ProcessInfo.processInfo.environment)
        defer {
            if input.removesDataRoot {
                try? FileManager.default.removeItem(at: input.dataRoot)
            }
        }

        let fixture = try JSONDecoder().decode(PerformanceWorkloadSQLiteFixture.self, from: input.fixtureData)
        Self.expectFixtureCounts(fixture, expected: input.expectedCounts)
        Self.expectGeneratedDurableIdentitiesAreUUIDv7(fixture)
        let saveBundle = WorkspaceSQLiteSaveBundle(workspace: fixture.workspaceSnapshot)
        guard case .prepared = await WorkspaceCompositionPreparer.prepareOffMain(saveBundle.workspace) else {
            Issue.record("Generated workload fixture was rejected before strict SQLite materialization")
            return
        }

        let dataEnvironment = [AppDataPaths.dataDirectoryEnvironmentKey: input.dataRoot.path]
        let coreDatabaseURL = AppDataPaths.coreSQLiteURL(
            environment: dataEnvironment,
            isDebugBuild: true
        )
        let localDatabaseURL = AppDataPaths.localSQLiteURL(
            environment: dataEnvironment,
            isDebugBuild: true
        )
        let datastoreFactory = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: coreDatabaseURL,
            localDatabaseURL: localDatabaseURL
        )
        let writer = datastoreFactory.makeDatastore()
        guard case .prepared = await writer.prepareDatabasesForBoot() else {
            Issue.record("Strict SQLite writer did not prepare")
            return
        }

        try await writer.saveRepositoryTopologySnapshot(fixture.repositoryTopologySnapshot, captureRevision: 1)
        try await writer.saveWorkspaceSnapshotBundle(saveBundle)
        let reader = datastoreFactory.makeDatastore()
        guard case .prepared = await reader.prepareDatabasesForBoot() else {
            Issue.record("Strict SQLite reader did not prepare")
            return
        }
        guard case .loaded(let loadedWorkspace) = await reader.loadWorkspaceSnapshot() else {
            Issue.record("Strict SQLite workspace reload did not return the materialized fixture")
            return
        }
        guard
            case .loaded(let loadedTopology) = await reader.loadRepositoryTopologySnapshot()
        else {
            Issue.record("Strict SQLite topology reload did not return the materialized fixture")
            return
        }
        guard case .prepared = await WorkspaceCompositionPreparer.prepareOffMain(loadedWorkspace) else {
            Issue.record("Strict SQLite reload produced an invalid workspace composition")
            return
        }

        #expect(loadedWorkspace.id == fixture.id)
        #expect(loadedWorkspace.activeTabId == fixture.activeTabId)
        #expect(Set(loadedTopology.repos.map(\.id)) == Set(fixture.repos.map(\.id)))
        #expect(Set(loadedTopology.worktrees.map(\.id)) == Set(fixture.worktrees.map(\.id)))
        #expect(Set(loadedWorkspace.panes.map(\.id)) == Set(fixture.panes.map(\.id)))
        #expect(Set(loadedWorkspace.tabs.map(\.id)) == Set(fixture.tabs.map(\.id)))
        #expect(loadedTopology.repos.count == input.expectedCounts.repos)
        #expect(loadedTopology.worktrees.count == input.expectedCounts.worktrees)
        #expect(loadedWorkspace.panes.count == input.expectedCounts.panes)
        #expect(loadedWorkspace.tabs.count == input.expectedCounts.tabs)
    }

    private let scriptPath = "scripts/verify-git-refresh-performance-workload.sh"
    private let cleanupScriptPath = "scripts/cleanup-owned-zmx-sessions.sh"
    private let comparisonScriptPath = "scripts/compare-atomlib-v2-performance.sh"
    private let comparisonPythonScriptPath = "scripts/compare-atomlib-v2-performance.py"

    private static let comparablePerformanceEventNames = [
        "performance.commandbar.items",
        "performance.commandbar.filter",
        "performance.tabbar.refresh",
        "performance.sidebar.projection",
        "performance.sidebar.row_index",
        "performance.coordinator.write",
    ]

    private static func assertVictoriaMetricsContract(_ source: String) {
        #expect(source.contains("query_victoria_logs()"))
        #expect(source.contains("query_victoria_metrics()"))
        #expect(source.contains("victoria_event_query()"))
        #expect(source.contains("victoria_event_count()"))
        #expect(source.contains("victoria_metric_event_query()"))
        #expect(source.contains("victoria_metric_event_count()"))
        #expect(source.contains("victoria_metric_event_label_selector()"))
        #expect(source.contains("victoria_metric_event_count_for_reason()"))
        #expect(source.contains("victoria_metric_event_elapsed_p95()"))
        #expect(source.contains("victoria_metric_event_elapsed_max()"))
        #expect(source.contains("victoria_metric_status_unavailable_reason_values()"))
        #expect(source.contains("require_status_latency_metrics()"))
        #expect(source.contains("agentstudio_performance_events_total"))
        #expect(source.contains("agentstudio_performance_event_elapsed_ms_bucket"))
        #expect(source.contains("agentstudio_performance_event_elapsed_ms_max"))
        #expect(source.contains("agent.proof.marker=\"%s\",event=\"%s\""))
        #expect(source.contains("victoria_metric_command_bar_filter_query()"))
        #expect(source.contains("agentstudio_performance_commandbar_query_character_count"))
    }

    private static func assertGitStatusMetricSummaryContract(_ source: String) {
        #expect(source.contains("performance.git.status_unavailable\nperformance.git.snapshot_dedup"))
        #expect(source.contains("performance.git.status.elapsed_ms.p95="))
        #expect(source.contains("performance.git.status.elapsed_ms.max="))
        #expect(source.contains("performance.git.status_unavailable.reason.$unavailable_reason.count="))
        #expect(source.contains("performance.git.status_unavailable.reason.$unavailable_reason.elapsed_ms.p95="))
        #expect(source.contains("read_already_in_flight"))
    }

    func runScript(
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> ScriptRunResult {
        let processOutput = try await withoutBlockingCooperativePool {
            let stdoutURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentstudio-script-stdout-\(UUIDv7.generate().uuidString).log")
            let stderrURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentstudio-script-stderr-\(UUIDv7.generate().uuidString).log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? FileManager.default.removeItem(at: stdoutURL)
                try? FileManager.default.removeItem(at: stderrURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, newValue in newValue }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            try process.run()
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()
            return GitWorkloadProcessOutput(
                exitCode: process.terminationStatus,
                stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
                stderr: try String(contentsOf: stderrURL, encoding: .utf8)
            )
        }
        return ScriptRunResult(
            exitCode: processOutput.exitCode,
            stdout: processOutput.stdout,
            stderr: processOutput.stderr
        )
    }

    private func temporaryFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-performance-comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}

private struct GitWorkloadProcessOutput: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct FixtureCounts {
    let repos: Int
    let worktrees: Int
    let panes: Int
    let tabs: Int
}

private struct FixtureMaterializationInput {
    let dataRoot: URL
    let fixtureData: Data
    let expectedCounts: FixtureCounts
    let removesDataRoot: Bool
}

extension GitRefreshPerformanceWorkloadScriptTests {
    fileprivate static let workloadFixtureJSONEnvironmentKey = "AGENTSTUDIO_PERF_FIXTURE_JSON"
    fileprivate static let workloadFixtureDataRootEnvironmentKey = "AGENTSTUDIO_PERF_FIXTURE_DATA_ROOT"
    fileprivate static let expectedRepositoryCountEnvironmentKey = "AGENTSTUDIO_PERF_FIXTURE_EXPECTED_REPOS"
    fileprivate static let expectedWorktreeCountEnvironmentKey = "AGENTSTUDIO_PERF_FIXTURE_EXPECTED_WORKTREES"
    fileprivate static let expectedPaneCountEnvironmentKey = "AGENTSTUDIO_PERF_FIXTURE_EXPECTED_PANES"
    fileprivate static let expectedTabCountEnvironmentKey = "AGENTSTUDIO_PERF_FIXTURE_EXPECTED_TABS"
    fileprivate static let workloadFixtureEnvironmentKeys = [
        workloadFixtureJSONEnvironmentKey,
        workloadFixtureDataRootEnvironmentKey,
        expectedRepositoryCountEnvironmentKey,
        expectedWorktreeCountEnvironmentKey,
        expectedPaneCountEnvironmentKey,
        expectedTabCountEnvironmentKey,
    ]
    fileprivate static let commonQuiescenceGaugeNames = [
        "agentstudio_performance_filesystem_logical_debt_count",
        "agentstudio_performance_git_logical_debt_count",
        "agentstudio_performance_runtime_delivery_total_pending_count",
    ]

    fileprivate static func expectStrictSQLiteFixtureAndQuiescenceContract(_ source: String) {
        for environmentKey in workloadFixtureEnvironmentKeys {
            #expect(source.contains(environmentKey))
        }
        #expect(source.contains("materialize_workspace_fixture()"))
        #expect(
            source.contains(
                "GitRefreshPerformanceWorkloadScriptTests.workloadFixtureMaterializesThroughStrictSQLite"))
        #expect(source.contains("\"content\": {\"version\": 3"))
        #expect(source.contains("\"zmxSessionID\":"))
        #expect(source.contains("uuid_v7()"))
        #expect(!source.contains("uuid_any()"))

        #expect(source.contains("COMMON_QUIESCENCE_TIMEOUT_SECONDS=75"))
        #expect(source.contains("METRICS_EXPORT_TIMEOUT_SECONDS=75"))
        #expect(source.contains("\"launchDirectory\": \"%s\""))
        #expect(
            source.contains(
                "\"facets\": {\"repoId\": \"%s\", \"worktreeId\": \"%s\", \"cwd\": null, \"tags\": []}"
            )
        )
        #expect(!source.contains("\"source\": {\"worktree\":"))
        #expect(source.contains("wait_for_common_quiescence()"))
        #expect(source.contains("wait_for_required_performance_metrics_export()"))
        #expect(source.contains("required_performance_metric_event_names()"))
        for eventName in comparablePerformanceEventNames {
            #expect(source.contains(eventName))
        }
        #expect(source.contains("missing_metric_events="))
        #expect(source.contains("\"\u{24}{missing_events[*]-}\""))
        #expect(
            !source.contains(
                "missing_events+=(\"performance.commandbar.filter.query_character.max\")"
            )
        )
        #expect(source.contains("WRITERS_FINISHED_AT"))
        #expect(source.contains("WRITERS_FINISHED_AT=\"$(date -u +%s)\""))
        #expect(source.contains("timestamp(%s{%s}) >= %s"))
        #expect(source.contains("latency_offset=$latency_offset"))
        #expect(source.contains("1ms 2>/dev/null || true"))
        for gaugeName in commonQuiescenceGaugeNames {
            #expect(source.contains(gaugeName))
        }
        #expect(source.contains("kill -0 \"$APP_PID\""))
        #expect(source.contains("/bin/ps"))
        #expect(source.contains("/usr/bin/footprint"))
        #expect(source.contains("-p \"$APP_PID\""))
        #expect(source.contains("capture_final_process_resources()"))
        #expect(
            source.contains("footprint_status\" != \"succeeded")
                && source.contains("exited during final resource capture")
        )

        expectSourceOrder(
            source,
            markers: [
                "\nprepare_fixture\n",
                "materialize_workspace_fixture\n",
                "launch_debug_observability_app\n",
                "WRITERS_FINISHED_AT=",
                "wait_for_common_quiescence ",
                "wait_for_required_performance_metrics_export",
                "capture_final_process_resources",
                "summarize_traces\n",
            ]
        )
    }

    fileprivate func fixtureMaterializationInput(
        environment: [String: String]
    ) throws -> FixtureMaterializationInput {
        let providedKeys = Self.workloadFixtureEnvironmentKeys.filter {
            !(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        try #require(
            providedKeys.isEmpty || providedKeys.count == Self.workloadFixtureEnvironmentKeys.count,
            "Operational fixture materialization requires all six environment inputs"
        )
        guard !providedKeys.isEmpty else {
            return FixtureMaterializationInput(
                dataRoot: try temporaryFixtureRoot(),
                fixtureData: Data(workloadFixtureJSON.utf8),
                expectedCounts: FixtureCounts(repos: 1, worktrees: 1, panes: 1, tabs: 1),
                removesDataRoot: true
            )
        }

        let fixturePath = try #require(environment[Self.workloadFixtureJSONEnvironmentKey])
        let explicitDataRoot = try #require(environment[Self.workloadFixtureDataRootEnvironmentKey])
        try Self.requireExplicitNonProductionDataRoot(explicitDataRoot)
        return FixtureMaterializationInput(
            dataRoot: URL(filePath: explicitDataRoot).standardizedFileURL,
            fixtureData: try Data(contentsOf: URL(filePath: fixturePath).standardizedFileURL),
            expectedCounts: FixtureCounts(
                repos: try Self.requiredPositiveCount(
                    environment[Self.expectedRepositoryCountEnvironmentKey],
                    key: Self.expectedRepositoryCountEnvironmentKey
                ),
                worktrees: try Self.requiredPositiveCount(
                    environment[Self.expectedWorktreeCountEnvironmentKey],
                    key: Self.expectedWorktreeCountEnvironmentKey
                ),
                panes: try Self.requiredPositiveCount(
                    environment[Self.expectedPaneCountEnvironmentKey],
                    key: Self.expectedPaneCountEnvironmentKey
                ),
                tabs: try Self.requiredPositiveCount(
                    environment[Self.expectedTabCountEnvironmentKey],
                    key: Self.expectedTabCountEnvironmentKey
                )
            ),
            removesDataRoot: false
        )
    }

    fileprivate static func expectSourceOrder(_ source: String, markers: [String]) {
        var searchStart = source.startIndex
        for marker in markers {
            guard let range = source.range(of: marker, range: searchStart..<source.endIndex) else {
                Issue.record("Missing ordered script marker: \(marker.trimmingCharacters(in: .whitespacesAndNewlines))")
                return
            }
            searchStart = range.upperBound
        }
    }

    fileprivate static func requiredPositiveCount(_ rawValue: String?, key: String) throws -> Int {
        let count = try #require(rawValue.flatMap(Int.init), "\(key) must be a positive integer")
        try #require(count > 0, "\(key) must be a positive integer")
        return count
    }

    fileprivate static func requireExplicitNonProductionDataRoot(_ rawPath: String) throws {
        try #require(rawPath.hasPrefix("/"), "Operational fixture data root must be an explicit absolute path")
        let root = URL(filePath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
        let forbiddenRoots = [
            AppDataPaths.rootDirectory(environment: [:], releaseChannel: .stable, isDebugBuild: false),
            AppDataPaths.rootDirectory(environment: [:], releaseChannel: .beta, isDebugBuild: false),
            AppDataPaths.rootDirectory(environment: [:], isDebugBuild: true),
            URL(filePath: "/"),
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        try #require(!forbiddenRoots.contains(root), "Operational fixture data root must not be a live app data root")
    }

    fileprivate static func expectFixtureCounts(
        _ fixture: PerformanceWorkloadSQLiteFixture,
        expected: FixtureCounts
    ) {
        #expect(fixture.repos.count == expected.repos)
        #expect(fixture.worktrees.count == expected.worktrees)
        #expect(fixture.panes.count == expected.panes)
        #expect(fixture.tabs.count == expected.tabs)
        #expect(Set(fixture.repos.map(\.id)).count == expected.repos)
        #expect(Set(fixture.worktrees.map(\.id)).count == expected.worktrees)
        #expect(Set(fixture.panes.map(\.id)).count == expected.panes)
        #expect(Set(fixture.tabs.map(\.id)).count == expected.tabs)
    }

    fileprivate static func expectGeneratedDurableIdentitiesAreUUIDv7(
        _ fixture: PerformanceWorkloadSQLiteFixture
    ) {
        let durableUUIDs =
            [fixture.id]
            + fixture.repos.map(\.id)
            + fixture.worktrees.map(\.id)
            + fixture.panes.map(\.id)
            + fixture.panes.compactMap { $0.drawer?.drawerId }
            + fixture.tabs.map(\.id)
            + fixture.tabs.flatMap { $0.arrangements.map(\.id) }
            + fixture.tabs.flatMap { $0.arrangements.flatMap(\.layout.dividerIds) }
        #expect(durableUUIDs.allSatisfy(UUIDv7.isV7))
        let terminalSessionUUIDs = fixture.panes.compactMap {
            $0.terminalState.flatMap { UUID(uuidString: $0.zmxSessionID.rawValue) }
        }
        #expect(terminalSessionUUIDs.count == fixture.panes.count)
        #expect(terminalSessionUUIDs.allSatisfy(UUIDv7.isV7))
    }
}

private struct PerformanceWorkloadSQLiteFixture: Decodable {
    let id: UUID
    let name: String
    let repos: [CanonicalRepo]
    let worktrees: [CanonicalWorktree]
    let unavailableRepoIds: Set<UUID>
    let panes: [Pane]
    let tabs: [Tab]
    let activeTabId: UUID?
    let sidebarWidth: CGFloat
    let windowFrame: CGRect?
    let watchedPaths: [WatchedPath]
    let createdAt: Date
    let updatedAt: Date

    var workspaceSnapshot: WorkspaceSQLiteSnapshot {
        WorkspaceSQLiteSnapshot(
            id: id,
            name: name,
            panes: panes,
            tabs: tabs,
            activeTabId: activeTabId,
            sidebarWidth: sidebarWidth,
            windowFrame: windowFrame,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    var repositoryTopologySnapshot: RepositoryTopologySQLiteSnapshot {
        RepositoryTopologySQLiteSnapshot(
            repos: repos,
            worktrees: worktrees,
            unavailableRepoIds: unavailableRepoIds,
            watchedPaths: watchedPaths,
            updatedAt: updatedAt
        )
    }
}
