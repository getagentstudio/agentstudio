import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Bridge observability verifier script")
struct BridgeObservabilityVerifierScriptTests {
    @Test(
        "verifier accepts recorded IDs and paths while rejecting secrets",
        arguments: ["item_id", "path", "token", "secret"])
    func verifierAcceptsSelectedFileMaterializationWithPositiveFileLines(exposedField: String) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=debug-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=999999999
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=bridge-review-observability-smoke
        AGENTSTUDIO_BRIDGE_OBSERVABILITY_SCENARIO=package_apply_content_fetch_v1
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let diagnosticRecord = """
            {"_msg":"app.startup_diagnostic_action.completed","agentstudio.startup_diagnostic.action":"bridge-review-observability-smoke","agentstudio.startup_diagnostic.expected_visible_pane.count":1,"agentstudio.startup_diagnostic.bridge.review_expected_item.count":697,"agentstudio.startup_diagnostic.bridge.review_metadata_item.count":697,"agentstudio.startup_diagnostic.bridge.review_metadata_tree_row.count":905,"agentstudio.startup_diagnostic.bridge.review_shell.visible":true,"agentstudio.startup_diagnostic.bridge.review_shell.state":"ready","agentstudio.startup_diagnostic.bridge.code_view.visible":true,"agentstudio.startup_diagnostic.bridge.selected_item.visible":true,"agentstudio.startup_diagnostic.bridge.selected_path.visible":true,"agentstudio.startup_diagnostic.bridge.selected_content.visible":true,"agentstudio.startup_diagnostic.bridge.selected_content.state":"ready","agentstudio.startup_diagnostic.bridge.selected_content_role.count":1,"agentstudio.startup_diagnostic.bridge.selected_content_cache_key.count":1,"agentstudio.startup_diagnostic.bridge.selected_content_character.count":1294,"agentstudio.startup_diagnostic.bridge.selected_content_line.count":0,"agentstudio.startup_diagnostic.bridge.selected_materialized.update_result":"updated","agentstudio.startup_diagnostic.bridge.selected_materialized.item_type":"file","agentstudio.startup_diagnostic.bridge.selected_materialized.item_version":5,"agentstudio.startup_diagnostic.bridge.selected_materialized.addition_line.count":0,"agentstudio.startup_diagnostic.bridge.selected_materialized.deletion_line.count":0,"agentstudio.startup_diagnostic.bridge.selected_materialized.file_line.count":31,"agentstudio.startup_diagnostic.bridge.page_issue.count":0,"agentstudio.startup_diagnostic.bridge.page_issue.disallowed.count":0,"agentstudio.startup_diagnostic.bridge.bridge_command.count":1,"agentstudio.startup_diagnostic.bridge.review_intake_ready_command.count":1,"agentstudio.startup_diagnostic.bridge.bridge_response.count":1,"agentstudio.startup_diagnostic.bridge.intake_frame.count":1,"agentstudio.startup_diagnostic.bridge.review_intake_snapshot_frame.count":1,"agentstudio.startup_diagnostic.bridge.review_intake_metadata_window_frame.count":1,"agentstudio.startup_diagnostic.bridge.review_intake.last_frame_kind":"review.metadataWindow","agentstudio.startup_diagnostic.bridge.review_intake.last_stream_id_matches":true,"agentstudio.startup_diagnostic.bridge.diff_container.count":5,"agentstudio.startup_diagnostic.bridge.code_view.instance.first_item.height_px":44,"agentstudio.startup_diagnostic.bridge.code_view.rendered_item.count":5,"agentstudio.startup_diagnostic.bridge.code_view.rendered_item.type":"file","agentstudio.startup_diagnostic.bridge.code_view.rendered_item.version":5,"agentstudio.startup_diagnostic.bridge.code_view_panel.width_px":2208,"agentstudio.startup_diagnostic.bridge.code_view_panel.height_px":1081,"agentstudio.startup_diagnostic.bridge.diff_container.width_px":2195,"agentstudio.startup_diagnostic.bridge.code_text.length":2243,"agentstudio.startup_diagnostic.bridge.code_shadow_text.length":2222,"agentstudio.startup_diagnostic.bridge.worker_pool.state":"ready","agentstudio.startup_diagnostic.bridge.worker_pool.manager_state":"initialized","agentstudio.startup_diagnostic.bridge.worker_pool.workers_failed":false,"agentstudio.startup_diagnostic.bridge.worker_diagnostic.diff_success_count":3,"agentstudio.startup_diagnostic.bridge.worker_diagnostic.failure_count":0,"agentstudio.startup_diagnostic.render_proof.succeeded":true}
            """
        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-bridge-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_OBSERVABILITY_ALLOW_COMPLETED_EXIT": "1",
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_ATTEMPTS": "1",
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_RETRY_DELAY_SECONDS": "0",
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-bridge-verifier-file-materialization",
                    """
                    #!/bin/bash
                    args="$*"
                    if [[ "$args" == *" agentstudio.bridge.\(exposedField):*"* ]]; then
                      printf '{"agentstudio.bridge.\(exposedField)":"fixture-value"}\\n'
                      exit 0
                    fi
                    if [[ "$args" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$args" == *"app.startup_diagnostic_action.command_exercised"* ]] || [[ "$args" == *"app.startup_diagnostic_action.completed"* ]]; then
                      printf '%s\\n' '\(diagnosticRecord)'
                      exit 0
                    fi
                    if [[ "$args" == *"api/v1/query"* ]]; then
                      if [[ "$args" == *"unless"* ]] || [[ "$args" == *"package_push"* ]] || [[ "$args" == *"package_apply"* ]] || [[ "$args" == *"unknown"* ]] || [[ "$args" == *"diff_package_metadata"* ]] || [[ "$args" == *"diff_package_delta"* ]] || [[ "$args" == *"review_delta"* ]] || [[ "$args" == *"review_invalidation"* ]] || [[ "$args" == *"review_reset"* ]] || [[ "$args" == *"review_metadata"* && "$args" == *"push_envelope"* ]] || [[ "$args" == *"review_metadata"* && "$args" == *"push_apply"* && "$args" == *"transport=\\"push\\""* ]] || [[ "$args" == *"review_metadata"* && "$args" == *"first_render"* && "$args" == *"transport=\\"push\\""* ]]; then
                        printf '{"status":"success","data":{"resultType":"vector","result":[]}}\\n'
                        exit 0
                      fi
                      printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1780000000,"1"]}]}}\\n'
                      exit 0
                    fi
                    if [[ "$args" == *"agentstudio.bridge.item_id:"* ]] || [[ "$args" == *"agentstudio.bridge.lane:"* ]] || [[ "$args" == *"agentstudio.bridge.tab_id:"* ]] || [[ "$args" == *"agentstudio.bridge.session_id:"* ]] || [[ "$args" == *"agentstudio.bridge.operation_id:"* ]] || [[ "$args" == *"agentstudio.bridge.request_id:"* ]] || [[ "$args" == *"agentstudio.bridge.content_hash:"* ]] || [[ "$args" == *"agentstudio.bridge.checkpoint_id:"* ]] || [[ "$args" == *"agentstudio.bridge.dynamic_key:"* ]] || [[ "$args" == *"agentstudio.bridge.path:"* ]] || [[ "$args" == *"agentstudio.bridge.prompt:"* ]] || [[ "$args" == *"agentstudio.bridge.raw_error:"* ]] || [[ "$args" == *"agentstudio.bridge.payload:"* ]] || [[ "$args" == *"agentstudio.bridge.text:"* ]] || [[ "$args" == *"agentstudio.bridge.output:"* ]] || [[ "$args" == *"agentstudio.bridge.token:"* ]] || [[ "$args" == *"agentstudio.bridge.secret:"* ]]; then
                      exit 0
                    fi
                    if [[ "$args" == *"performance.bridge.webkit.package_push"* ]] || [[ "$args" == *"performance.bridge.web.package_apply"* ]] || [[ "$args" == *"agentstudio.bridge.rpc.method_class:telemetry"* ]] || [[ "$args" == *"span_attr:agentstudio.bridge.rpc.method_class\\":\\"telemetry"* ]] || [[ "$args" == *"performance.bridge.webkit.push_envelope"* && "$args" == *"unknown"* ]] || [[ "$args" == *"performance.bridge.webkit.push_envelope"* && "$args" == *"diff_package_metadata"* ]] || [[ "$args" == *"performance.bridge.webkit.push_envelope"* && "$args" == *"diff_package_delta"* ]] || [[ "$args" == *"performance.bridge.webkit.push_envelope"* && "$args" == *"review_metadata"* ]] || [[ "$args" == *"performance.bridge.webkit.push_envelope"* && "$args" == *"review_delta"* ]] || [[ "$args" == *"performance.bridge.webkit.push_envelope"* && "$args" == *"review_invalidation"* ]] || [[ "$args" == *"performance.bridge.webkit.push_envelope"* && "$args" == *"review_reset"* ]] || [[ "$args" == *"performance.bridge.web.push_apply"* && "$args" == *"diff_package_metadata"* ]] || [[ "$args" == *"performance.bridge.web.push_apply"* && "$args" == *"diff_package_delta"* ]] || [[ "$args" == *"performance.bridge.web.push_apply"* && "$args" == *"review_metadata"* ]] || [[ "$args" == *"performance.bridge.web.push_apply"* && "$args" == *"review_delta"* ]] || [[ "$args" == *"performance.bridge.web.push_apply"* && "$args" == *"review_invalidation"* ]] || [[ "$args" == *"performance.bridge.web.push_apply"* && "$args" == *"review_reset"* ]] || [[ "$args" == *"performance.bridge.web.first_render"* && "$args" == *"diff_package_metadata"* && "$args" == *"push"* ]] || [[ "$args" == *"performance.bridge.web.first_render"* && "$args" == *"review_metadata"* && "$args" == *"push"* ]]; then
                      exit 0
                    fi
                    if [[ "$args" == *"performance.bridge."* ]]; then
                      printf '{"_msg":"performance.bridge.test","agentstudio.bridge.phase":"test","agentstudio.bridge.plane":"data","agentstudio.bridge.priority":"hot","agentstudio.bridge.slice":"test","agentstudio.bridge.transport":"test","trace_id":"trace","span_id":"span"}\\n'
                      exit 0
                    fi
                    if [[ "$args" == *"span_attr:agent.proof.marker"* ]]; then
                      printf '{"trace_id":"trace","span_id":"span","span_name":"bridge.test","span_attr:agent.proof.marker":"debug-marker","span_attr:agentstudio.bridge.test.scenario":"package_apply_content_fetch_v1","span_attr:agentstudio.bridge.phase":"test"}\\n'
                      exit 0
                    fi
                    if [[ "$args" == *":*"* ]]; then
                      exit 0
                    fi
                    printf '{"service.name":"AgentStudio","service.version":"0.0.1-debug+testcode","dev.runtime.flavor":"debug","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path,
            ]
        )

        let expectedExit: Int32 = ["token", "secret"].contains(exposedField) ? 1 : 0
        #expect(result.exitCode == expectedExit, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        if expectedExit == 1 {
            #expect(
                result.stderr.contains("unsafe Bridge field survived OTLP logs: agentstudio.bridge.\(exposedField)"))
        }
    }

    @Test("verifier accepts skipped review startup diagnostic when frame is not live")
    func verifierAcceptsSkippedReviewStartupDiagnosticFrameNotLive() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=debug-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=999999999
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=bridge-review-observability-smoke
        AGENTSTUDIO_BRIDGE_OBSERVABILITY_SCENARIO=package_apply_content_fetch_v1
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let skippedRecord = """
            {"_msg":"app.startup_diagnostic_action.skipped","agentstudio.startup_diagnostic.action":"bridge-review-observability-smoke","agentstudio.startup_diagnostic.render_proof.succeeded":false,"agentstudio.startup_diagnostic.bridge.frame_liveness.raf_alive":"false","agentstudio.startup_diagnostic.skip_reason":"frame_not_live"}
            """
        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-bridge-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_OBSERVABILITY_ALLOW_COMPLETED_EXIT": "1",
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_ATTEMPTS": "1",
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_RETRY_DELAY_SECONDS": "0",
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-bridge-verifier-skipped-frame",
                    """
                    #!/bin/bash
                    args="$*"
                    if [[ "$args" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$args" == *"app.startup_diagnostic_action.command_exercised"* ]]; then
                      printf '%s\\n' '\(skippedRecord.replacingOccurrences(of: "_msg\":\"app.startup_diagnostic_action.skipped", with: "_msg\":\"app.startup_diagnostic_action.command_exercised"))'
                      exit 0
                    fi
                    if [[ "$args" == *"app.startup_diagnostic_action.completed"* ]]; then
                      exit 0
                    fi
                    if [[ "$args" == *"app.startup_diagnostic_action.skipped"* ]]; then
                      printf '%s\\n' '\(skippedRecord)'
                      exit 0
                    fi
                    if [[ "$args" == *":*"* ]]; then
                      exit 0
                    fi
                    printf '{"service.name":"AgentStudio","service.version":"0.0.1-debug+testcode","dev.runtime.flavor":"debug","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stdout.contains("SKIP Bridge startup diagnostic"))
        #expect(result.stdout.contains("frame_not_live"))
        #expect(!result.stderr.contains("missing Bridge startup diagnostic completed record"))
    }

    @Test("verifier rejects skipped review startup diagnostic unless render proof failed")
    func verifierRejectsSkippedReviewStartupDiagnosticWithoutFailedRenderProof() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=debug-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=999999999
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=bridge-review-observability-smoke
        AGENTSTUDIO_BRIDGE_OBSERVABILITY_SCENARIO=package_apply_content_fetch_v1
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let skippedRecord = """
            {"_msg":"app.startup_diagnostic_action.skipped","agentstudio.startup_diagnostic.action":"bridge-review-observability-smoke","agentstudio.startup_diagnostic.render_proof.succeeded":true,"agentstudio.startup_diagnostic.bridge.frame_liveness.raf_alive":"false","agentstudio.startup_diagnostic.skip_reason":"frame_not_live"}
            """
        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-bridge-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_OBSERVABILITY_ALLOW_COMPLETED_EXIT": "1",
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_ATTEMPTS": "1",
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_RETRY_DELAY_SECONDS": "0",
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-bridge-verifier-spoofed-skipped-frame",
                    """
                    #!/bin/bash
                    args="$*"
                    if [[ "$args" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$args" == *"app.startup_diagnostic_action.command_exercised"* ]]; then
                      printf '%s\\n' '\(skippedRecord.replacingOccurrences(of: "_msg\":\"app.startup_diagnostic_action.skipped", with: "_msg\":\"app.startup_diagnostic_action.command_exercised"))'
                      exit 0
                    fi
                    if [[ "$args" == *"app.startup_diagnostic_action.completed"* ]]; then
                      exit 0
                    fi
                    if [[ "$args" == *"app.startup_diagnostic_action.skipped"* ]]; then
                      printf '%s\\n' '\(skippedRecord)'
                      exit 0
                    fi
                    if [[ "$args" == *":*"* ]]; then
                      exit 0
                    fi
                    printf '{"service.name":"AgentStudio","service.version":"0.0.1-debug+testcode","dev.runtime.flavor":"debug","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path,
            ]
        )

        #expect(result.exitCode != 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(!result.stdout.contains("SKIP Bridge startup diagnostic"))
    }

    @Test("verifier covers all bridge telemetry planes with marker-scoped Victoria proof")
    func verifierCoversBridgeTelemetryPlanesWithMarkerScopedVictoriaProof() throws {
        let verifierScript = try String(
            contentsOfFile: "scripts/verify-bridge-observability.sh",
            encoding: .utf8
        )
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)

        #expect(verifierScript.contains("bridge-review-observability-smoke"))
        #expect(verifierScript.contains("scripts/verify-debug-observability.sh"))
        #expect(verifierScript.contains("scripts/verify-bridge-web-no-direct-otlp.sh"))
        #expect(verifierScript.contains("AGENTSTUDIO_BRIDGE_OBSERVABILITY_SCENARIO"))
        #expect(verifierScript.contains("performance.bridge.swift.package_build"))
        #expect(verifierScript.contains("performance.bridge.webkit.rpc_dispatch"))
        #expect(verifierScript.contains("performance.bridge.web.content_fetch"))
        #expect(verifierScript.contains("TRACES_QUERY_URL"))
        #expect(verifierScript.contains("span_attr:agent.proof.marker"))
        #expect(verifierScript.contains("agent.proof.marker"))
        #expect(!verifierScript.contains("agentstudio.trace.name"))
        #expect(verifierScript.contains("span_attr:agentstudio.bridge.test.scenario"))
        #expect(verifierScript.contains("span_attr:agentstudio.bridge.rpc.method_class"))
        #expect(verifierScript.contains("agentstudio.bridge.plane"))
        #expect(verifierScript.contains("agentstudio.bridge.priority"))
        #expect(verifierScript.contains("agentstudio.bridge.slice"))
        #expect(verifierScript.contains("agentstudio.bridge.rpc.method_class:telemetry"))
        #expect(verifierScript.contains("telemetry_self_rpc=absent"))
        #expect(verifierScript.contains("historical_bridge_lane_field"))
        #expect(verifierScript.contains("BRIDGE_HISTORICAL_LANE_SUFFIX"))
        #expect(
            verifierScript.contains(
                "performance.bridge.webkit.push_envelope|transport|data|hot|diff_status|push"
            ))
        #expect(
            verifierScript.contains(
                "performance.bridge.web.intake_frame|intake|data|cold|review_metadata|intake"
            ))
        #expect(
            !verifierScript.contains(
                "performance.bridge.web.intake_frame|intake|data|warm|review_delta|intake"
            ))
        #expect(
            verifierScript.contains(
                "performance.bridge.web.review_metadata_apply|review_metadata_apply|data|hot|review_metadata|intake"
            ))
        #expect(
            verifierScript.contains(
                "performance.bridge.web.first_render|render|data|hot|review_metadata|intake"
            ))
        #expect(
            verifierScript.contains(
                "performance.bridge.webkit.telemetry_batch|accepted|observability|best_effort|telemetry_batch|rpc"
            ))
        #expect(
            verifierScript.contains(
                "performance.bridge.web.content_fetch|fetch|data|hot|content_fetch|content"
            ))
        #expect(
            verifierScript.contains(
                "performance.bridge.swift.content_load|success|data|hot|content_fetch|content"
            ))
        #expect(
            verifierScript.contains(
                "performance.bridge.web.rpc_send|send|control|warm|review_rpc|rpc"
            ))
        #expect(verifierScript.contains("plane=\"'\"$plane\"'\""))
        #expect(verifierScript.contains("priority=\"'\"$priority\"'\""))
        #expect(verifierScript.contains("slice=\"'\"$slice\"'\""))
        #expect(verifierScript.contains("agentstudio.bridge.test.scenario"))
        #expect(verifierScript.contains("agentstudio.bridge.raw_error"))
        #expect(verifierScript.contains("agentstudio.bridge.prompt"))
        #expect(verifierScript.contains("missing Bridge broad push_envelope metric fallback"))
        #expect(verifierScript.contains("Bridge push_envelope metric used unknown producer slice"))
        #expect(verifierScript.contains("Bridge push_envelope log used unknown producer slice"))
        #expect(verifierScript.contains("legacy Bridge package_push metric survived hard cutover"))
        #expect(verifierScript.contains("legacy Bridge package_apply metric survived hard cutover"))
        #expect(verifierScript.contains("Bridge Review package data still used WebKit push transport"))
        #expect(verifierScript.contains("Bridge Review package data still used web push apply transport"))
        #expect(verifierScript.contains("Bridge Review first render still reported push transport"))
        #expect(
            verifierScript.contains(
                "event=\"performance.bridge.webkit.push_envelope\",slice=\"unknown\""
            ))
        #expect(miseConfig.contains("[tasks.verify-bridge-observability]"))
    }

    @Test("verify-debug-observability asserts viewer TTFI presence and a report-only 300ms gate")
    func verifierAssertsViewerTtfiPresenceAndReportOnlyGate() throws {
        let script = try String(
            contentsOfFile: "scripts/verify-debug-observability.sh",
            encoding: .utf8
        )

        // Presence contract wired into the file-view smoke path.
        #expect(script.contains("performance.bridge.viewer.time_to_first_interaction"))
        #expect(script.contains("phase=\"time_to_first_interaction\""))
        #expect(script.contains("slice=\"content_fetch\""))
        #expect(script.contains("require_bridge_viewer_ttfi_report_only_gate"))
        // Report-only numeric gate with an env-tunable budget defaulting to 300ms.
        #expect(script.contains("AGENTSTUDIO_BRIDGE_TTFI_GATE_MS"))
        #expect(script.contains(":-300"))
        #expect(script.contains("bridge_viewer_ttfi_report_gate"))
        #expect(script.contains("REPORT (over budget"))
    }

    @Test("viewer TTFI report-only gate logs pass/over-budget but never exits non-zero")
    func viewerTtfiReportOnlyGateNeverExitsNonZero() async throws {
        // Arrange / Act: p95 far above the default 300ms budget.
        let overBudget = try await runTtfiGateSelfTest(p95: "1500", gateMilliseconds: nil)
        // Assert: report-only means over-budget still succeeds, with an over-budget log.
        #expect(overBudget.exitCode == 0, "stdout: \(overBudget.stdout)")
        #expect(overBudget.stdout.contains("REPORT (over budget"))

        // Under budget logs PASS and also succeeds.
        let underBudget = try await runTtfiGateSelfTest(p95: "120", gateMilliseconds: nil)
        #expect(underBudget.exitCode == 0, "stdout: \(underBudget.stdout)")
        #expect(underBudget.stdout.contains("TTFI gate PASS"))

        // The budget threshold is env-tunable.
        let customBudget = try await runTtfiGateSelfTest(p95: "250", gateMilliseconds: "200")
        #expect(customBudget.exitCode == 0, "stdout: \(customBudget.stdout)")
        #expect(customBudget.stdout.contains("REPORT (over budget"))
    }

    private func runTtfiGateSelfTest(
        p95: String,
        gateMilliseconds: String?
    ) async throws -> TtfiGateSelfTestResult {
        try await withoutBlockingCooperativePool {
            let outputDirectory = FileManager.default.temporaryDirectory
                .appending(path: "bridge-ttfi-gate-\(UUIDv7.generate().uuidString)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDirectory) }
            let stdoutURL = outputDirectory.appending(path: "stdout.log")
            let stderrURL = outputDirectory.appending(path: "stderr.log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["scripts/verify-debug-observability.sh"]
            var environment = ProcessInfo.processInfo.environment
            environment["AGENTSTUDIO_BRIDGE_TTFI_GATE_SELFTEST_P95"] = p95
            if let gateMilliseconds {
                environment["AGENTSTUDIO_BRIDGE_TTFI_GATE_MS"] = gateMilliseconds
            } else {
                environment.removeValue(forKey: "AGENTSTUDIO_BRIDGE_TTFI_GATE_MS")
            }
            process.environment = environment
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()
            return TtfiGateSelfTestResult(
                exitCode: process.terminationStatus,
                stdout: try String(contentsOf: stdoutURL, encoding: .utf8)
            )
        }
    }

    @Test("BridgeWeb does not contain direct browser OTLP exporter hooks")
    func bridgeWebDoesNotContainDirectBrowserOTLPExporterHooks() throws {
        let scanScript = try String(
            contentsOfFile: "scripts/verify-bridge-web-no-direct-otlp.sh",
            encoding: .utf8
        )

        #expect(scanScript.contains("BridgeWeb/package.json"))
        #expect(scanScript.contains("BridgeWeb/pnpm-lock.yaml"))
        #expect(scanScript.contains("/^importers:$/"))
        #expect(scanScript.contains("/^packages:$/"))
        #expect(scanScript.contains("lockfile_importers"))
        #expect(scanScript.contains("BridgeWeb/src"))
        #expect(scanScript.contains("Sources/AgentStudio/Resources/BridgeWeb/app"))
        #expect(scanScript.contains("BRIDGE_WEB_OTLP_SCAN_TARGETS"))
        #expect(scanScript.contains("default_scan_targets=("))
        #expect(scanScript.contains("scan_targets=(\"${default_scan_targets[@]}\")"))
        #expect(scanScript.contains("scan_targets+=(\"${extra_scan_targets[@]}\")"))
        #expect(scanScript.contains("mktemp -t bridge-web-otlp-scan"))
        #expect(scanScript.contains("@opentelemetry"))
        #expect(scanScript.contains("/v1/traces"))
        #expect(scanScript.contains("/v1/logs"))
        #expect(scanScript.contains("/v1/metrics"))
        #expect(scanScript.contains("OTEL_EXPORTER_OTLP"))
        #expect(scanScript.contains("OTLPHTTP"))
        #expect(scanScript.contains("127.0.0.1:4318"))
        #expect(scanScript.contains("localhost:4318"))
        #expect(scanScript.contains("-- \"$pattern\""))
    }

    @Test("BridgeWeb direct OTLP scanner keeps default roots when extra targets are supplied")
    func bridgeWebDirectOTLPScannerKeepsDefaultRootsWhenExtraTargetsAreSupplied() async throws {
        let exitCode = try await runBridgeWebOTLPScanner(environment: [
            "BRIDGE_WEB_OTLP_SCAN_TARGETS": "/dev/null"
        ])

        #expect(exitCode == 0)
    }

    @Test("BridgeWeb direct OTLP scanner fails on seeded browser exporter markers")
    func bridgeWebDirectOTLPScannerFailsOnSeededMarkers() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-web-direct-otlp-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let seededFile = temporaryDirectory.appendingPathComponent("bad.ts")
        try "@opentelemetry/exporter-trace-otlp-http".write(to: seededFile, atomically: true, encoding: .utf8)

        let exitCode = try await runBridgeWebOTLPScanner(environment: [
            "BRIDGE_WEB_OTLP_SCAN_TARGETS": temporaryDirectory.path
        ])

        #expect(exitCode != 0)
    }

    private func runBridgeWebOTLPScanner(environment: [String: String]) async throws -> Int32 {
        try await withoutBlockingCooperativePool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["scripts/verify-bridge-web-no-direct-otlp.sh"]
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }
}

private struct TtfiGateSelfTestResult: Sendable {
    let exitCode: Int32
    let stdout: String
}
