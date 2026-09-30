import Darwin
import Foundation
import Testing

@Suite("Observability launch scripts")
struct ObservabilityLaunchScriptsTests {
    @Test("debug launcher creates isolated per-worktree app identity")
    func debugLauncherCreatesIsolatedPerWorktreeAppIdentity() throws {
        let script = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)

        #expect(script.contains("worktree_debug_code()"))
        #expect(script.contains("space = 36 ** 4"))
        #expect(script.contains("source \"$PROJECT_ROOT/scripts/swift-build-slot.sh\""))
        #expect(!script.contains("swift-build-slot.sh\" debug"))
        #expect(script.contains("--print-identity"))
        #expect(script.contains("AgentStudio Debug $code.app"))
        #expect(script.contains("Agent Studio Debug $code"))
        #expect(script.contains("com.agentstudio.app.debug.d$code"))
        #expect(script.contains("Delete :CFBundleURLTypes"))
        #expect(!script.contains("CFBundleURLTypes:0:CFBundleURLSchemes:0 \"agentstudio\""))
        #expect(script.contains("debug_root=\"$HOME/.agentstudio-db/$debug_code\""))
        #expect(script.contains("trace_name_is_safe_path_component()"))
        #expect(script.contains("write_launch_failed_state invalid_trace_name"))
        #expect(script.contains("launch_data_root=\"${AGENTSTUDIO_DEBUG_DATA_DIR:-$debug_root}\""))
        #expect(script.contains("launch_data_root=\"$debug_root/runs/$trace_name\""))
        #expect(script.contains("\"AGENTSTUDIO_DATA_DIR=$launch_data_root\""))
        #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION"))
        #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE"))
        #expect(script.contains("running_debug_app_pids()"))
        #expect(script.contains("Agent Studio Debug $debug_code is already running"))
        #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_STATUS already_running"))
    }

    @Test("debug launcher publishes one stable default app through disposable staging")
    func debugLauncherPublishesOneStableDefaultAppThroughDisposableStaging() throws {
        let script = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)

        #expect(script.contains("publish_debug_bundle()"))
        #expect(
            script.contains("debug_artifact_root=\"${AGENTSTUDIO_DEBUG_ARTIFACT_DIR:-$debug_root/apps}\"")
        )
        #expect(script.contains("renameatx_np"))
        #expect(!script.contains("$debug_root/apps/app-$(date"))
        #expect(script.contains("AGENTSTUDIO_DEBUG_ARTIFACT_DIR"))
        #expect(script.contains("debug_launch_lock=\"$debug_root/.launch.lock\""))
        #expect(script.contains("/usr/bin/lockf -s -t 0 9"))
    }

    @Test("debug worktree code avoids known four character collision")
    func debugWorktreeCodeAvoidsKnownFourCharacterCollision() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }

        let firstCode = try await fixture.worktreeDebugCode(for: "/tmp/worktree-657")
        let secondCode = try await fixture.worktreeDebugCode(for: "/tmp/worktree-1190")

        #expect(firstCode.count == 4)
        #expect(secondCode.count == 4)
        #expect(firstCode != secondCode)
    }

    @Test("mise swift test tasks forward requested filters through the slot wrapper")
    func miseSwiftTestTasksForwardRequestedFiltersThroughSlotWrapper() throws {
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let wrapperScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let testHelperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let agentInstructions = try String(contentsOfFile: "AGENTS.md", encoding: .utf8)
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let benchmarkWorkflow = try String(
            contentsOfFile: ".github/workflows/benchmarks.yml",
            encoding: .utf8
        )

        #expect(miseConfig.contains("run = \"/bin/bash scripts/run-swift-test-task.sh test\""))
        #expect(miseConfig.contains("run = \"/bin/bash scripts/run-swift-test-task.sh test-fast\""))
        #expect(miseConfig.contains("run = \"/bin/bash scripts/run-swift-test-task.sh test-prebuild\""))
        #expect(miseConfig.contains("run = \"/bin/bash scripts/run-swift-test-task.sh test-webkit\""))
        #expect(miseConfig.contains("[tasks.\"test:swift:e2e\"]"))
        #expect(miseConfig.contains("[tasks.\"test:swift:zmx-e2e\"]"))
        #expect(miseConfig.contains("source \"${PROJECT_ROOT}/scripts/swift-build-slot.sh\""))
        #expect(wrapperScript.contains("source \"${PROJECT_ROOT}/scripts/swift-build-slot.sh\""))
        #expect(!miseConfig.contains("swift-build-slot.sh\" debug"))
        #expect(!miseConfig.contains("swift-build-slot.sh\" release"))
        #expect(!wrapperScript.contains("swift-build-slot.sh\" debug"))
        #expect(!wrapperScript.contains("swift-build-slot.sh\" release"))
        #expect(wrapperScript.contains("TIMEOUT_SECONDS=\"${SWIFT_TEST_TIMEOUT_SECONDS:-600}\""))
        #expect(wrapperScript.contains("SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS:-1200"))
        #expect(wrapperScript.contains("SWIFT_TEST_SKIP_PREBUILD"))
        #expect(wrapperScript.contains("PREBUILD_TIMEOUT_SECONDS=$PREBUILD_TIMEOUT_SECONDS"))
        #expect(wrapperScript.contains("run_swift_with_timeout"))
        #expect(wrapperScript.contains("requested swift test args: $*"))
        #expect(wrapperScript.contains("requested_filter_mentions_suite()"))
        #expect(wrapperScript.contains("--skip WebKitSerializedTests"))
        #expect(wrapperScript.contains("--skip E2ESerializedTests"))
        #expect(wrapperScript.contains("--skip ZmxE2ETests"))
        #expect(wrapperScript.contains("swift_test_args=(\"$@\")"))
        #expect(wrapperScript.contains("swift_test_args+=("))
        #expect(
            wrapperScript.contains(
                "swift test $(swift_package_sandbox_arguments) --skip-build \"${swift_test_args[@]}\""))
        #expect(wrapperScript.contains("AGENTSTUDIO_TRACE_BACKEND=\"${SWIFT_TEST_TRACE_BACKEND:-jsonl}\""))
        #expect(
            testHelperScript.contains(
                "Maximum seconds without one-time test bundle build output progress"
            )
        )
        #expect(testHelperScript.contains("\"prebuild test bundles\" \\\n    \"$PREBUILD_TIMEOUT_SECONDS\""))
        #expect(testHelperScript.contains("swift_test_output_has_failures()"))
        #expect(testHelperScript.contains("emitted Swift Testing failure output despite exit 0"))
        #expect(testHelperScript.contains("recorded an issue"))
        #expect(testHelperScript.contains("grep -Eq \"unexpected signal code [0-9]+\" <<<\"$output\""))
        #expect(!testHelperScript.contains("echo \"$output\" | grep -Eq \"unexpected signal code [0-9]+\""))
        for liveBridgeTransportTest in [
            "test_bridgeReady_gatesAndIsIdempotent",
            "test_teardown_resetsBridgeReady",
            "test_schemeHandler_servesPackagedReactApp",
            "test_handleDiffCommandWithSmokeProvider_rendersReviewViewerShell",
            "test_sourceBackedInitialReviewLoad_rendersReviewViewerShell",
        ] {
            #expect(
                testHelperScript.contains(
                    "WebKitSerializedTests/BridgeTransportIntegrationTests/\(liveBridgeTransportTest)"
                ))
        }
        for staleWebKitFilter in [
            "test_pushJSON_transportFailure_setsConnectionHealthError",
            "test_requestWithId_emitsBridgeResponseEvent",
            "test_schemeHandler_servesAppHtml",
            "test_intakeSnapshotFrame_rendersReviewViewerShell",
            "test_pushJSON_concurrentBurstDeliversOrderedPageEvents",
            "test_contentFetch_traceparentHeaderReachesCustomSchemeHandler",
            "test_contentFetch_realDiffHandlesResolveAndDoNotRejectThroughReviewViewer",
            "WebKitSerializedTests/BridgeIntakeCarrierWebKitTests",
            "WebKitSerializedTests/InboxPostHandlerTests",
            "WebKitSerializedTests/InboxNotificationBridgeWebKitIntegrationTests",
        ] {
            #expect(!testHelperScript.contains(staleWebKitFilter))
        }
        #expect(testHelperScript.contains("No matching test cases were run"))
        #expect(!testHelperScript.contains("WebKitSerializedTests/WorkspaceSurfaceBridgeFilesystemRefreshTests"))
        #expect(testHelperScript.contains("WorkspaceSurfaceCoordinatorFilesystemSourceTests"))
        #expect(testHelperScript.contains("WebKitSerializedTests/BridgePaneControllerIPCProjectionTests"))
        #expect(testHelperScript.contains("WebKitSerializedTests/BridgePaneControllerContentAuthorityTests"))
        #expect(
            testHelperScript.contains(
                "WebKitSerializedTests/BridgeProductRealGitFileAndReviewWebKitTests"
            ))
        #expect(!testHelperScript.contains("\nWebKitSerializedTests/BridgeTransportIntegrationTests\n"))
        // The timeout path signals the lane's OWN child process group, and only
        // that group. It used to walk live parent links, which missed any
        // descendant that re-parented when its parent died — the survivor held a
        // build slot and made the next run fail with "all 2 slots are busy".
        #expect(testHelperScript.contains("terminate_lane_child_tree TERM \"$command_pid\""))
        #expect(testHelperScript.contains("terminate_lane_child_tree KILL \"$command_pid\""))
        #expect(!testHelperScript.contains("terminate_process_tree"))
        // A survivor that re-parented is unreachable from the child pid, so the
        // KILL path also sweeps this run's unique event-stream path. `pgrep` only
        // lists; the kills are explicit and by pid, never a pattern-matching kill.
        #expect(testHelperScript.contains("kill_lane_processes_by_run_token \"$event_stream_file\""))
        #expect(!testHelperScript.contains("pkill -f"))
        #expect(!testHelperScript.contains("pkill -9 -f"))
        #expect(!agentInstructions.contains("pkill -f \"swift-build\""))
        #expect(ciWorkflow.contains("SWIFT_TEST_TIMEOUT_SECONDS: \"600\""))
        #expect(!ciWorkflow.contains("SWIFT_TEST_WORKERS"))
        #expect(ciWorkflow.contains("run: mise run --skip-deps --raw test:swift:fast"))
        #expect(!ciWorkflow.contains("mise run test:swift:benchmark"))
        #expect(
            benchmarkWorkflow.contains(
                "set -o pipefail\n          mise run test:swift:benchmark 2>&1 | tee benchmark.log"
            )
        )
    }

    @Test("observability launchers scrub inherited AgentStudio process identity")
    func observabilityLaunchersUseCleanLaunchServicesEnvironment() throws {
        let debugScript = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)
        let betaScript = try String(contentsOfFile: "scripts/run-beta-observability.sh", encoding: .utf8)

        for script in [debugScript, betaScript] {
            #expect(script.contains("clean_open_env=("))
            #expect(script.contains("open_app()"))
            #expect(script.contains("for attempt in 1 2 3 4 5"))
            #expect(script.contains("-i"))
            #expect(script.contains("\"PATH=/usr/bin:/bin:/usr/sbin:/sbin\""))
            #expect(script.contains("\"${clean_open_env[@]}\" \"$OPEN_BIN\" ${wait_flag:+\"$wait_flag\"} -n"))
            #expect(script.contains("open_app \"$app_path\" \"$launch_log\" \"-W\""))
            #expect(script.contains("\"$OPEN_BIN\" ${wait_flag:+\"$wait_flag\"} -n"))
            #expect(!script.contains("PATH=\"$safe_path\" open -n"))
            #expect(!script.contains("-u MANPATH"))
            #expect(!script.contains("-u XDG_DATA_DIRS"))
            #expect(!script.contains("-u ZMX_DIR"))
            #expect(!script.contains("-u ZMX_SESSION"))
            #expect(!script.contains("-u ZMX_SESSION_PREFIX"))
            #expect(!script.contains("-u __CFBundleIdentifier"))
            #expect(!script.contains("-u GHOSTTY_BIN_DIR"))
            #expect(!script.contains("-u GHOSTTY_RESOURCES_DIR"))
            #expect(script.contains("--stdout \"$launch_log\""))
            #expect(script.contains("--stderr \"$launch_log\""))
            #expect(script.contains("--env \"AGENTSTUDIO_TRACE_BACKEND=$trace_backend\""))
            #expect(script.contains("--env \"AGENTSTUDIO_TRACE_PROOF_TOKEN=$trace_proof_token\""))
            #expect(script.contains("PGREP_BIN=\"${AGENTSTUDIO_PGREP_BIN:-/usr/bin/pgrep}\""))
            #expect(script.contains("LSOF_BIN=\"${AGENTSTUDIO_LSOF_BIN:-/usr/sbin/lsof}\""))
            #expect(script.contains("\"$PGREP_BIN\" -x AgentStudio"))
            #expect(script.contains("unable to inspect running AgentStudio PID $pid"))
            #expect(script.contains("unable to resolve executable for running AgentStudio PID $pid"))
            #expect(script.contains("\"$LSOF_BIN\" -a -p \"$pid\" -d txt -Fn"))
            #expect(!script.contains("ps -axo pid=,command="))
            #expect(script.contains("write_launch_failed_state()"))
            #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_STATUS launch_failed"))
            #expect(script.contains("LaunchServices open failed"))
        }
        #expect(debugScript.contains("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION"))
        #expect(
            betaScript.contains(
                "BETA_ARTIFACT_ROOT=\"${AGENTSTUDIO_BETA_ARTIFACT_ROOT:-$HOME/.agentstudio-db/beta-observability}\""))
        #expect(betaScript.contains("trace_dir=\"${AGENTSTUDIO_TRACE_DIR:-$BETA_ARTIFACT_ROOT/traces}\""))
        #expect(
            betaScript.contains(
                "launch_log=\"${AGENTSTUDIO_OBSERVABILITY_LAUNCH_LOG:-$BETA_ARTIFACT_ROOT/logs/$trace_name.log}\""))
        #expect(betaScript.contains("--latest-local"))
        #expect(betaScript.contains("missing required --app <AgentStudio Beta.app>"))
        #expect(betaScript.contains("AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION"))
        #expect(betaScript.contains("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION"))
        #expect(betaScript.contains("wait_for_beta_app_pid"))
        #expect(betaScript.contains("write_launch_failed_state otlp_collector_unhealthy"))
        #expect(!debugScript.contains("refusing to launch debug observability from inherited zmx environment"))
        #expect(!betaScript.contains("refusing to launch beta observability from inherited zmx environment"))
        #expect(debugScript.contains("AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD"))
        #expect(debugScript.contains("wait_for_app_pid"))
        #expect(debugScript.contains("agentstudio_pids_for_binary()"))
        #expect(debugScript.contains("launch_direct_binary()"))
        #expect(debugScript.contains("debug direct executable fallback"))
        #expect(!betaScript.contains("launch_direct_binary()"))
        #expect(!betaScript.contains("direct_executable"))
        #expect(!betaScript.contains("running_app_pids_for_binary()"))
        #expect(!betaScript.contains("agentstudio_pids_for_binary()"))
        #expect(betaScript.contains("running_beta_app_pids()"))
        #expect(betaScript.contains("AgentStudio beta is already running"))
        #expect(betaScript.contains("AGENTSTUDIO_OBSERVABILITY_STATUS already_running"))

        let createBetaScript = try String(contentsOfFile: "scripts/create-local-beta-bundle.sh", encoding: .utf8)
        #expect(
            createBetaScript.contains(
                "beta_artifact_root=\"${AGENTSTUDIO_BETA_ARTIFACT_ROOT:-$HOME/.agentstudio-db/beta-observability}\""))
        #expect(
            createBetaScript.contains(
                "artifact_dir=\"${AGENTSTUDIO_LOCAL_BETA_DIR:-$beta_artifact_root/$marketing_version}\""))
    }

    @Test("beta observability verifier bounds VictoriaLogs queries")
    func betaObservabilityVerifierBoundsVictoriaLogsQueries() throws {
        let verifierScript = try String(contentsOfFile: "scripts/verify-beta-observability.sh", encoding: .utf8)

        #expect(verifierScript.contains("CURL_BIN=\"${AGENTSTUDIO_CURL_BIN:-/usr/bin/curl}\""))
        #expect(verifierScript.contains("\"$CURL_BIN\" --fail --silent --show-error --max-time 5 --get"))
        #expect(
            verifierScript.contains(
                "stream_query=\"{service.name=\\\"AgentStudio\\\",dev.release.channel=\\\"beta\\\"}\""))
        #expect(verifierScript.contains("logsql_escape_exact_value()"))
        #expect(verifierScript.contains("logsql_exact_filter()"))
        #expect(verifierScript.contains("marker_query=\"$(logsql_exact_filter \"agent.proof.marker\" \"$MARKER\")\""))
        #expect(verifierScript.contains("startup_event_query=\"$(logsql_exact_filter \"_msg\""))
        #expect(verifierScript.contains("query=\"$stream_query $marker_query\""))
        #expect(!verifierScript.contains("marker_query=\"agent.proof.marker:${MARKER}\""))
        #expect(!verifierScript.contains("agentstudio.trace.name"))
        #expect(verifierScript.contains("AGENTSTUDIO_EXPECTED_BETA_APP"))
        #expect(verifierScript.contains("missing AGENTSTUDIO_EXPECTED_BETA_APP"))
        #expect(verifierScript.contains("AgentStudio beta observability app mismatch"))
        #expect(verifierScript.contains("shlex.split"))
        #expect(verifierScript.contains("AgentStudio beta observability did not start"))
        #expect(verifierScript.contains("state_status"))
        #expect(verifierScript.contains("state_pid"))
        #expect(verifierScript.contains("bundle_release_channel_for_executable"))
        #expect(verifierScript.contains("app.did_finish_launching.succeeded"))
        #expect(verifierScript.contains("terminal.tcc.access_probe"))
        #expect(verifierScript.contains("AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION"))
        #expect(verifierScript.contains("tcc-upgrade-probe"))
        #expect(verifierScript.contains("agentstudio.tcc.access.result"))
        #expect(verifierScript.contains("agentstudio.tcc.responsible.kind"))
        #expect(verifierScript.contains("agentstudio.app.startup.phase"))
        #expect(verifierScript.contains("agentstudio.app.startup.outcome"))
    }

    @Test("beta observability verifier fails before querying logs when launcher state failed")
    func betaObservabilityVerifierFailsFastForFailedLauncherState() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed
        AGENTSTUDIO_OBSERVABILITY_REASON=launchservices_open_failed
        AGENTSTUDIO_OBSERVABILITY_MARKER=marker\\ with\\ spaces
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let curlMarker = fixture.url("curl-called")

        let result = try await fixture.runVerifier(
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-fail-health",
                    """
                    #!/bin/bash
                    echo called > "\(curlMarker.path)"
                    exit 0
                    """
                ).path
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("launch_failed"))
        #expect(result.stderr.contains("launchservices_open_failed"))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test("beta observability verifier requires exact expected app binding")
    func betaObservabilityVerifierRequiresExactExpectedAppBinding() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=beta-marker
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(fixture.url("workflow/AgentStudio Beta.app").path))
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let curlMarker = fixture.url("curl-called")

        let result = try await fixture.runVerifier(
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    echo called > "\(curlMarker.path)"
                    exit 0
                    """
                ).path
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("missing AGENTSTUDIO_EXPECTED_BETA_APP"))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test("beta observability verifier uses configured curl for VictoriaLogs queries")
    func betaObservabilityVerifierUsesConfiguredCurlForQueries() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let betaApp = try fixture.makeAppBundle(name: "AgentStudioBeta.app", releaseChannel: "beta")
        let betaAppPath = betaApp.path
        let marker = "beta marker | fields process.pid"
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=\(shellEscapedStateValue(marker))
        AGENTSTUDIO_OBSERVABILITY_SERVICE_VERSION=0.0.54-beta.99
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=tcc-upgrade-probe
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(betaAppPath))
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let curlMarker = fixture.url("curl-called")
        let curlArguments = fixture.url("curl-arguments")

        let result = try await fixture.runVerifier(
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_EXPECTED_BETA_APP": betaAppPath,
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    echo called >> "\(curlMarker.path)"
                    printf '%s\\n' "$*" >> "\(curlArguments.path)"
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action."* ]]; then
                      exit 0
                    fi
                    if [[ "$*" == *"terminal.tcc.access_probe"* ]]; then
                      printf '{"_msg":"terminal.tcc.access_probe","agentstudio.tcc.phase":"startup_diagnostic","agentstudio.tcc.subject":"shell_child","agentstudio.tcc.access.target":"documents","agentstudio.tcc.access.result":"granted","agentstudio.tcc.responsible.kind":"agentstudio_beta","agentstudio.tcc.command.exit_class":"ok","agentstudio.tcc.probe.sequence":0}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"terminal.tcc.app_identity_snapshot"* ]]; then printf '{"_msg":"terminal.tcc.app_identity_snapshot","agentstudio.tcc.phase":"startup_diagnostic","agentstudio.tcc.bundle.kind":"beta","agentstudio.tcc.code_identity.kind":"same_disk_identity","agentstudio.tcc.bundle.changed":false,"agentstudio.tcc.bundle.executable.reachable":true,"agentstudio.tcc.probe.sequence":0}\\n'; exit 0; fi
                    if [[ "$*" == *":*"* ]]; then
                      exit 0
                    fi
                    printf '{"service.name":"AgentStudio","service.version":"0.0.54-beta.99","dev.release.channel":"beta","dev.runtime.flavor":"release","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(betaApp.path)/Contents/MacOS/AgentStudio"
                    echo "n/Library/Preferences/Logging/.plist-cache.test"
                    echo "n/usr/lib/dyld"
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: curlMarker.path))
        let curlArgumentText = try String(contentsOf: curlArguments, encoding: .utf8)
        let expectedTraceQuery = [
            "{service.name=\"AgentStudio\",dev.release.channel=\"beta\"}",
            "agent.proof.marker:=\"beta marker | fields process.pid\"",
        ].joined(separator: " ")
        #expect(curlArgumentText.contains(expectedTraceQuery))
        #expect(curlArgumentText.contains("_msg:=\"terminal.tcc.access_probe\""))
        #expect(curlArgumentText.contains("agentstudio.startup_diagnostic.action:=\"tcc-upgrade-probe\""))
        #expect(!curlArgumentText.contains("agent.proof.marker:beta marker | fields process.pid"))
    }

    @Test("beta observability verifier rejects PID from a different beta bundle path")
    func betaObservabilityVerifierRejectsPidFromDifferentBetaBundlePath() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let expectedApp = try fixture.makeAppBundle(name: "Expected AgentStudio Beta.app", releaseChannel: "beta")
        let actualRunningApp = try fixture.makeAppBundle(name: "Other AgentStudio Beta.app", releaseChannel: "beta")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=beta-marker
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(expectedApp.path))
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let curlMarker = fixture.url("curl-called")

        let result = try await fixture.runVerifier(
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_EXPECTED_BETA_APP": expectedApp.path,
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    echo called > "\(curlMarker.path)"
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(actualRunningApp.path)/Contents/MacOS/AgentStudio"
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("PID app mismatch"))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test("beta observability verifier rejects stale running state before querying logs")
    func betaObservabilityVerifierRejectsStaleRunningStateBeforeQueryingLogs() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let betaAppPath = try fixture.makeAppBundle(name: "AgentStudioBeta.app", releaseChannel: "beta").path
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=beta-marker
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_PID=999999999
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(betaAppPath))
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let curlMarker = fixture.url("curl-called")

        let result = try await fixture.runVerifier(
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_EXPECTED_BETA_APP": betaAppPath,
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    echo called > "\(curlMarker.path)"
                    printf '{"service.name":"AgentStudio","service.version":"0.0.54-beta.99","dev.release.channel":"beta","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("PID is not running"))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test("beta observability verifier fails when completed app launch telemetry is missing")
    func betaObservabilityVerifierFailsWhenCompletedAppLaunchTelemetryIsMissing() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let betaApp = try fixture.makeAppBundle(name: "AgentStudioBeta.app", releaseChannel: "beta")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=beta-marker
        AGENTSTUDIO_OBSERVABILITY_SERVICE_VERSION=0.0.54-beta.99
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(betaApp.path))
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)

        let result = try await fixture.runVerifier(
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_EXPECTED_BETA_APP": betaApp.path,
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]] || [[ "$*" == *":* | limit 1"* ]]; then
                      exit 0
                    fi
                    printf '{"service.name":"AgentStudio","service.version":"0.0.54-beta.99","dev.release.channel":"beta","dev.runtime.flavor":"release","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(betaApp.path)/Contents/MacOS/AgentStudio"
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("no completed app launch record"))
    }

    @Test("beta observability verifier rejects unexpected beta app path")
    func betaObservabilityVerifierRejectsUnexpectedBetaAppPath() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=beta-marker
        AGENTSTUDIO_OBSERVABILITY_SERVICE_VERSION=0.0.54-beta.99
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_APP=\(fixture.url("stale/AgentStudio Beta.app").path)
        """.write(to: stateFile, atomically: true, encoding: .utf8)
        let curlMarker = fixture.url("curl-called")

        let result = try await fixture.runVerifier(
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_EXPECTED_BETA_APP": fixture.url("workflow/AgentStudio Beta.app").path,
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    echo called > "\(curlMarker.path)"
                    exit 0
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("AgentStudio beta observability app mismatch"))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test("debug observability verifier requires completed app launch telemetry and scrubbed output")
    func debugObservabilityVerifierRequiresCompletedAppLaunchTelemetryAndScrubbedOutput() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let marker = "debug marker | fields process.pid"
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=\(shellEscapedStateValue(marker))
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(fixture.url("Agent Studio Debug testcode.app").path))
        """.write(to: stateFile, atomically: true, encoding: .utf8)
        let debugApp = try fixture.makeAppBundle(
            name: "Agent Studio Debug testcode.app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug.dtestcode"
        )
        let curlMarker = fixture.url("curl-called")
        let curlArguments = fixture.url("curl-arguments")

        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-debug-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    echo called >> "\(curlMarker.path)"
                    printf '%s\\n' "$*" >> "\(curlArguments.path)"
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action."* ]]; then
                      exit 0
                    fi
                    if [[ "$*" == *":*"* ]]; then
                      exit 0
                    fi
                    printf '{"service.name":"AgentStudio","service.version":"0.0.1-debug+abcd1234","dev.runtime.flavor":"debug","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(debugApp.path)/Contents/MacOS/AgentStudio"
                    echo "n/Library/Preferences/Logging/.plist-cache.test"
                    echo "n/usr/lib/dyld"
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: curlMarker.path))
        let curlArgumentText = try String(contentsOf: curlArguments, encoding: .utf8)
        let expectedTraceQuery = [
            "{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"}",
            "agent.proof.marker:=\"debug marker | fields process.pid\"",
        ].joined(separator: " ")
        #expect(curlArgumentText.contains(expectedTraceQuery))
        #expect(!curlArgumentText.contains("agent.proof.marker:debug marker | fields process.pid"))
        #expect(!curlArgumentText.contains("agentstudio.trace.name"))
    }

    @Test("debug observability verifier fails when completed app launch telemetry is missing")
    func debugObservabilityVerifierFailsWhenCompletedAppLaunchTelemetryIsMissing() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=debug-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(fixture.url("Agent Studio Debug testcode.app").path))
        """.write(to: stateFile, atomically: true, encoding: .utf8)
        let debugApp = try fixture.makeAppBundle(
            name: "Agent Studio Debug testcode.app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug.dtestcode"
        )

        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-debug-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    if [[ "$*" == *":* | limit 1"* ]] || [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      exit 0
                    fi
                    printf '{"service.name":"AgentStudio","service.version":"0.0.1-debug+abcd1234","dev.runtime.flavor":"debug","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(debugApp.path)/Contents/MacOS/AgentStudio"
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("no completed app launch record"))
    }

    @Test("debug observability verifier rejects stale running state before querying logs")
    func debugObservabilityVerifierRejectsStaleRunningStateBeforeQueryingLogs() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=debug-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=999999999
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(fixture.url("Agent Studio Debug testcode.app").path))
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let curlMarker = fixture.url("curl-called")

        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-debug-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    echo called > "\(curlMarker.path)"
                    printf '{"service.name":"AgentStudio","service.version":"0.0.1-debug+testcode","dev.runtime.flavor":"debug","_msg":"app.process.start"}\\n'
                    exit 0
                    """
                ).path
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("PID is not running"))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test("script runner captures final stderr output across repeated exits")
    func scriptRunnerCapturesFinalStderrOutputAcrossRepeatedExits() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let markerScript = try fixture.executable(
            "emit-final-stderr-marker",
            """
            #!/bin/bash
            printf '%s' "$OBSERVABILITY_TEST_MARKER" >&2
            """
        )

        for runIndex in 0..<64 {
            let marker = "observability-final-stderr-marker-\(runIndex)"
            let result = try await fixture.runScript(
                markerScript.path,
                arguments: [],
                environment: ["OBSERVABILITY_TEST_MARKER": marker]
            )

            #expect(result.exitCode == 0)
            #expect(result.stderr.contains(marker))
        }
    }

}

@Suite("Observability beta launcher scripts")
struct ObservabilityBetaLauncherScriptsTests {
    @Test("beta launcher uses latest local artifact only when explicitly requested")
    func betaLauncherUsesLatestLocalArtifactOnlyWhenExplicitlyRequested() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let primaryRoot = fixture.url("primary-beta-root")
        let legacyRoot = fixture.url("legacy-beta-root")
        let primaryApp = try fixture.makeAppBundle(
            name: "primary-beta-root/0.0.54-beta.16/AgentStudio Beta.app",
            releaseChannel: "beta"
        )
        let legacyApp = try fixture.makeAppBundle(
            name: "legacy-beta-root/0.0.54-beta.99/AgentStudio Beta.app",
            releaseChannel: "beta"
        )
        let staleTouchDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerTouchDate = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: staleTouchDate], ofItemAtPath: primaryApp.path)
        try FileManager.default.setAttributes([.modificationDate: newerTouchDate], ofItemAtPath: legacyApp.path)
        let openArgs = fixture.url("open-args")
        let stateFile = fixture.url("latest.env")

        let result = try await fixture.runScript(
            "scripts/run-beta-observability.sh",
            arguments: ["--latest-local", "--detach"],
            environment: [
                "AGENTSTUDIO_BETA_ARTIFACT_ROOT": primaryRoot.path,
                "AGENTSTUDIO_LEGACY_BETA_ARTIFACT_ROOT": legacyRoot.path,
                "AGENTSTUDIO_OPEN_BIN": try fixture.executable(
                    "open",
                    """
                    #!/bin/bash
                    printf '%s\\n' "$@" > "\(openArgs.path)"
                    exit 1
                    """
                ).path,
                "AGENTSTUDIO_PGREP_BIN": try fixture.executable(
                    "pgrep",
                    """
                    #!/bin/bash
                    exit 1
                    """
                ).path,
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1)
        let args = try String(contentsOf: openArgs, encoding: .utf8)
        #expect(args.contains(primaryApp.path))
        #expect(!args.contains(legacyApp.path))
    }

    @Test("beta launcher requires explicit app unless latest local diagnostic mode is selected")
    func betaLauncherRequiresExplicitAppUnlessLatestLocalDiagnosticModeIsSelected() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let openMarker = fixture.url("open-called")

        let result = try await fixture.runScript(
            "scripts/run-beta-observability.sh",
            arguments: ["--detach"],
            environment: [
                "AGENTSTUDIO_OPEN_BIN": try fixture.executable(
                    "open",
                    """
                    #!/bin/bash
                    echo called > "\(openMarker.path)"
                    exit 0
                    """
                ).path
            ]
        )

        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("missing required --app"))
        #expect(!FileManager.default.fileExists(atPath: openMarker.path))
    }

    @Test("beta launcher records launch failure when no PID appears")
    func betaLauncherRecordsPidLookupFailureState() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let app = try fixture.makeAppBundle(name: "AgentStudio Beta.app", releaseChannel: "beta")
        let openMarker = fixture.url("open-called")
        let stateFile = fixture.url("latest.env")

        let result = try await fixture.runScript(
            "scripts/run-beta-observability.sh",
            arguments: ["--app", app.path, "--detach"],
            environment: [
                "AGENTSTUDIO_OPEN_BIN": try fixture.executable(
                    "open",
                    """
                    #!/bin/bash
                    echo called > "\(openMarker.path)"
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_PGREP_BIN": try fixture.executable(
                    "pgrep",
                    """
                    #!/bin/bash
                    exit 1
                    """
                ).path,
                "AGENTSTUDIO_PID_WAIT_ATTEMPTS": "1",
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: openMarker.path))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=launchservices_pid_not_found"))
    }

    @Test("beta launcher records launch failure when collector is unhealthy")
    func betaLauncherRecordsCollectorHealthFailureState() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let app = try fixture.makeAppBundle(name: "AgentStudio Beta.app", releaseChannel: "beta")
        let openMarker = fixture.url("open-called")
        let stateFile = fixture.url("latest.env")

        let result = try await fixture.runScript(
            "scripts/run-beta-observability.sh",
            arguments: ["--app", app.path, "--detach"],
            environment: [
                "AGENTSTUDIO_OPEN_BIN": try fixture.executable(
                    "open",
                    """
                    #!/bin/bash
                    echo called > "\(openMarker.path)"
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_PGREP_BIN": try fixture.executable(
                    "pgrep",
                    """
                    #!/bin/bash
                    exit 1
                    """
                ).path,
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-fail-health",
                    """
                    #!/bin/bash
                    exit 7
                    """
                ).path,
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: openMarker.path))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=otlp_collector_unhealthy"))
    }

    @Test("beta launcher does not bind launched proof to a different beta bundle path")
    func betaLauncherDoesNotBindProofToDifferentBetaBundlePathAfterLaunch() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let selectedApp = try fixture.makeAppBundle(name: "Selected AgentStudio Beta.app", releaseChannel: "beta")
        let translocatedApp = try fixture.makeAppBundle(
            name: "Translocated/AgentStudio Beta.app", releaseChannel: "beta")
        let pgrepState = fixture.url("pgrep-state")
        let stateFile = fixture.url("latest.env")

        let result = try await fixture.runScript(
            "scripts/run-beta-observability.sh",
            arguments: ["--app", selectedApp.path, "--detach"],
            environment: [
                "AGENTSTUDIO_OPEN_BIN": try fixture.executable(
                    "open",
                    """
                    #!/bin/bash
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_PGREP_BIN": try fixture.executable(
                    "pgrep",
                    """
                    #!/bin/bash
                    if [ -f "\(pgrepState.path)" ]; then
                      echo 6464
                    else
                      touch "\(pgrepState.path)"
                      exit 1
                    fi
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(translocatedApp.path)/Contents/MacOS/AgentStudio"
                    """
                ).path,
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
                "AGENTSTUDIO_PID_WAIT_ATTEMPTS": "1",
            ]
        )

        #expect(result.exitCode == 1)
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=launchservices_pid_not_found"))
    }

}
