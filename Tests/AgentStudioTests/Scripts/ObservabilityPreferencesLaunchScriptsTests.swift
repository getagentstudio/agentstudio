import Darwin
import Foundation
import Testing

@Suite("Observability preferences launch scripts")
struct ObservabilityPreferencesLaunchScriptsTests {
    @Test("debug preferences launcher writes global preferences and omits trace selection env")
    func debugPreferencesLauncherWritesGlobalPreferencesAndOmitsTraceSelectionEnv() throws {
        let strictScript = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)
        let preferenceScript = try String(
            contentsOfFile: "scripts/run-debug-preferences-observability.sh",
            encoding: .utf8
        )
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)

        #expect(preferenceScript.contains("AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE=honor_preferences"))
        #expect(preferenceScript.contains("preferences.global.json"))
        #expect(preferenceScript.contains("\"schemaVersion\": 1"))
        #expect(preferenceScript.contains("\"enabled\": true"))
        #expect(preferenceScript.contains("\"traceTags\": \"*\""))
        #expect(preferenceScript.contains("\"traceBackend\": \"otlp\""))
        #expect(preferenceScript.contains("\"traceFlush\": \"buffered\""))
        #expect(preferenceScript.contains("\"otlpEndpoint\": \"$otlp_endpoint\""))
        #expect(!preferenceScript.contains("AGENTSTUDIO_TRACE_TAGS="))
        #expect(!preferenceScript.contains("AGENTSTUDIO_TRACE_BACKEND="))
        #expect(!preferenceScript.contains("AGENTSTUDIO_TRACE_FLUSH="))
        #expect(!preferenceScript.contains("OTEL_EXPORTER_OTLP_ENDPOINT="))
        #expect(!preferenceScript.contains("OTEL_EXPORTER_OTLP_PROTOCOL="))
        #expect(preferenceScript.contains("observability-control-guards.sh"))
        #expect(preferenceScript.contains("validate_observability_controls"))
        #expect(preferenceScript.contains("validate_safe_trace_name"))
        #expect(preferenceScript.contains("assert_child_path_under_parent"))
        #expect(preferenceScript.contains("validate_loopback_url OTEL_EXPORTER_OTLP_ENDPOINT"))

        #expect(strictScript.contains("preferences_mode=\"${AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE:-}\""))
        let preferencesModeRange = try #require(
            strictScript.range(of: "preferences_mode=\"${AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE:-}\""))
        let duplicateCheckRange = try #require(
            strictScript.range(
                of: "if existing_state_pid=\"$(running_debug_state_pid",
                range: preferencesModeRange.upperBound..<strictScript.endIndex
            ))
        #expect(preferencesModeRange.lowerBound < duplicateCheckRange.lowerBound)
        #expect(strictScript.contains("if [ \"$preferences_mode\" = \"honor_preferences\" ]; then"))
        #expect(
            strictScript.contains("write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE \"$preferences_mode\""))
        let preferenceModeWriteCount =
            strictScript.components(
                separatedBy: "write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE \"$preferences_mode\""
            ).count - 1
        #expect(preferenceModeWriteCount >= 6)
        #expect(miseConfig.contains("[tasks.run-debug-preferences-observability]"))
        #expect(miseConfig.contains("run = \"/bin/bash scripts/run-debug-preferences-observability.sh\""))
    }

    @Test("beta preferences launcher writes isolated global preferences and omits trace selection env")
    func betaPreferencesLauncherWritesGlobalPreferencesAndOmitsTraceSelectionEnv() throws {
        let preferenceScript = try String(
            contentsOfFile: "scripts/run-beta-preferences-observability.sh",
            encoding: .utf8)
        let strictScript = try String(contentsOfFile: "scripts/run-beta-observability.sh", encoding: .utf8)
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)

        #expect(preferenceScript.contains("preferences.global.json"))
        #expect(preferenceScript.contains("AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE=honor_preferences"))
        #expect(preferenceScript.contains("\"traceTags\": \"*\""))
        #expect(preferenceScript.contains("\"traceBackend\": \"otlp\""))
        #expect(preferenceScript.contains("\"traceFlush\": \"buffered\""))
        #expect(preferenceScript.contains("\"otlpEndpoint\": \"$otlp_endpoint\""))
        #expect(preferenceScript.contains("default_launch_data_root=\"$proof_root/$trace_name\""))
        #expect(preferenceScript.contains("launch_data_root=\"$AGENTSTUDIO_BETA_DATA_DIR\""))
        #expect(preferenceScript.contains("exec \"$PROJECT_ROOT/scripts/run-beta-observability.sh\" \"$@\""))
        #expect(!preferenceScript.contains("export AGENTSTUDIO_TRACE_TAGS"))
        #expect(!preferenceScript.contains("export AGENTSTUDIO_TRACE_BACKEND"))
        #expect(!preferenceScript.contains("export AGENTSTUDIO_TRACE_FLUSH"))
        #expect(!preferenceScript.contains("export OTEL_EXPORTER_OTLP_ENDPOINT"))
        #expect(!preferenceScript.contains("export OTEL_EXPORTER_OTLP_PROTOCOL"))
        #expect(preferenceScript.contains("observability-control-guards.sh"))
        #expect(preferenceScript.contains("validate_observability_controls"))
        #expect(preferenceScript.contains("validate_safe_trace_name"))
        #expect(preferenceScript.contains("assert_child_path_under_parent"))
        #expect(preferenceScript.contains("validate_loopback_url OTEL_EXPORTER_OTLP_ENDPOINT"))
        #expect(strictScript.contains("preferences_mode=\"${AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE:-}\""))
        let preferencesModeRange = try #require(
            strictScript.range(of: "preferences_mode=\"${AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE:-}\""))
        let duplicateCheckRange = try #require(
            strictScript.range(of: "if ! existing_pids=\"$(running_beta_channel_pids"))
        #expect(preferencesModeRange.lowerBound < duplicateCheckRange.lowerBound)
        #expect(strictScript.contains("if [ \"$preferences_mode\" = \"honor_preferences\" ]; then"))
        #expect(
            strictScript.contains("write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE \"$preferences_mode\""))
        let preferenceModeWriteCount =
            strictScript.components(
                separatedBy: "write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE \"$preferences_mode\""
            ).count - 1
        #expect(preferenceModeWriteCount >= 4)
        #expect(miseConfig.contains("[tasks.run-beta-preferences-observability]"))
        #expect(miseConfig.contains("run = \"/bin/bash scripts/run-beta-preferences-observability.sh\""))
    }

    @Test("stable preferences launcher and verifier are wired for local proof")
    func stablePreferencesLauncherAndVerifierAreWiredForLocalProof() throws {
        let launcherScript = try String(
            contentsOfFile: "scripts/run-stable-preferences-observability.sh",
            encoding: .utf8)
        let verifierScript = try String(
            contentsOfFile: "scripts/verify-stable-preferences-observability.sh",
            encoding: .utf8)
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)

        #expect(launcherScript.contains("preferences.global.json"))
        #expect(launcherScript.contains("AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE=honor_preferences"))
        #expect(
            launcherScript.contains(
                "STABLE_ARTIFACT_ROOT=\"${AGENTSTUDIO_STABLE_ARTIFACT_ROOT:-$HOME/.agentstudio-db/stable-preferences-observability}\""
            ))
        #expect(launcherScript.contains("--env \"AGENTSTUDIO_DATA_DIR=$launch_data_root\""))
        #expect(launcherScript.contains("--env \"AGENTSTUDIO_TRACE_NAME=$trace_name\""))
        #expect(!launcherScript.contains("AGENTSTUDIO_TRACE_TAGS=$trace_tags"))
        #expect(!launcherScript.contains("OTEL_EXPORTER_OTLP_ENDPOINT=$otlp_endpoint"))
        #expect(launcherScript.contains("observability-control-guards.sh"))
        #expect(launcherScript.contains("validate_observability_controls"))
        #expect(launcherScript.contains("validate_safe_trace_name"))
        #expect(launcherScript.contains("assert_child_path_under_parent"))
        #expect(launcherScript.contains("validate_loopback_url OTEL_EXPORTER_OTLP_ENDPOINT"))
        #expect(verifierScript.contains("dev.release.channel=\\\"stable\\\""))
        #expect(verifierScript.contains("app.preferences.global.loaded"))
        #expect(verifierScript.contains("AGENTSTUDIO_EXPECTED_STABLE_APP"))
        #expect(verifierScript.contains("validate_loopback_url AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL"))
        #expect(miseConfig.contains("[tasks.run-stable-preferences-observability]"))
        #expect(miseConfig.contains("[tasks.verify-stable-preferences-observability]"))
    }

    @Test("preferences launchers reject unsafe trace names before writing preferences")
    func preferencesLaunchersRejectUnsafeTraceNamesBeforeWritingPreferences() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let debugDataRoot = fixture.url("debug-data")
        let betaProofRoot = fixture.url("beta-proof")
        let stableArtifactRoot = fixture.url("stable-artifacts")
        let stableApp = try fixture.makeAppBundle(
            name: "AgentStudio.app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app"
        )
        let pgrep = try fixture.executable(
            "pgrep",
            """
            #!/bin/bash
            exit 1
            """
        )

        let debugResult = try await fixture.runScript(
            "scripts/run-debug-preferences-observability.sh",
            arguments: [],
            environment: [
                "AGENTSTUDIO_TRACE_NAME": "..",
                "AGENTSTUDIO_DEBUG_DATA_DIR": debugDataRoot.path,
            ])
        #expect(debugResult.exitCode == 2)
        #expect(debugResult.stderr.contains("unsafe AGENTSTUDIO_TRACE_NAME"))
        #expect(
            !FileManager.default.fileExists(
                atPath: debugDataRoot.appending(path: "preferences.global.json").path))

        let betaResult = try await fixture.runScript(
            "scripts/run-beta-preferences-observability.sh",
            arguments: ["--app", fixture.url("AgentStudio Beta.app").path],
            environment: [
                "AGENTSTUDIO_TRACE_NAME": "..",
                "AGENTSTUDIO_BETA_PREFERENCES_PROOF_ROOT": betaProofRoot.path,
            ])
        #expect(betaResult.exitCode == 2)
        #expect(betaResult.stderr.contains("unsafe AGENTSTUDIO_TRACE_NAME for preferences proof"))
        #expect(
            !FileManager.default.fileExists(
                atPath: betaProofRoot.appending(path: "preferences.global.json").path))

        let stableResult = try await fixture.runScript(
            "scripts/run-stable-preferences-observability.sh",
            arguments: ["--app", stableApp.path, "--detach"],
            environment: [
                "AGENTSTUDIO_TRACE_NAME": "..",
                "AGENTSTUDIO_STABLE_ARTIFACT_ROOT": stableArtifactRoot.path,
                "AGENTSTUDIO_PGREP_BIN": pgrep.path,
            ])
        #expect(stableResult.exitCode == 2)
        #expect(stableResult.stderr.contains("unsafe AGENTSTUDIO_TRACE_NAME for stable preferences proof"))
        #expect(
            !FileManager.default.fileExists(
                atPath: stableArtifactRoot.appending(path: "preferences.global.json").path))
    }

    @Test("preferences launcher rejects untrusted stack helper before execution")
    func preferencesLauncherRejectsUntrustedStackHelperBeforeExecution() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let helperMarker = fixture.url("helper-executed")
        let untrustedHelper = try fixture.executable(
            "untrusted-observability-stack",
            """
            #!/bin/bash
            touch "\(helperMarker.path)"
            echo "http://127.0.0.1:4318"
            """
        )
        let proofRoot = fixture.url("beta-proof")

        let result = try await fixture.runScript(
            "scripts/run-beta-preferences-observability.sh",
            arguments: ["--app", fixture.url("AgentStudio Beta.app").path],
            environment: [
                "AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES": "0",
                "AI_TOOLS_OBSERVABILITY_STACK_HELPER": untrustedHelper.path,
                "AGENTSTUDIO_BETA_PREFERENCES_PROOF_ROOT": proofRoot.path,
                "AGENTSTUDIO_TRACE_NAME": "safe-marker",
            ])

        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("AI_TOOLS_OBSERVABILITY_STACK_HELPER must point to the trusted ai-tools helper"))
        #expect(!FileManager.default.fileExists(atPath: helperMarker.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: proofRoot.appending(path: "safe-marker/preferences.global.json").path))
    }

    @Test("stable preferences verifier rejects non-loopback logs query URL before curl")
    func stablePreferencesVerifierRejectsNonLoopbackLogsQueryURLBeforeCurl() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let curlMarker = fixture.url("curl-executed")
        try "".write(to: stateFile, atomically: true, encoding: .utf8)

        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-stable-preferences-observability.sh",
            stateFile: stateFile,
            environment: [
                "AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL": "http://collector.example.com/select/logsql/query",
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    touch "\(curlMarker.path)"
                    exit 0
                    """
                ).path,
            ])

        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL must be a loopback http URL"))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test("global preferences startup performance verifier compares real debug launches")
    func globalPreferencesStartupPerformanceVerifierComparesRealDebugLaunches() throws {
        let verifierScript = try String(
            contentsOfFile: "scripts/verify-global-preferences-startup-performance.sh",
            encoding: .utf8)
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)

        #expect(verifierScript.contains("globalPreferencesLoaderStaysWithinStartupBudget"))
        #expect(verifierScript.contains("AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_SAMPLE_COUNT"))
        #expect(verifierScript.contains("MEDIAN_DELTA_BUDGET_MS"))
        #expect(verifierScript.contains("MAX_DELTA_BUDGET_MS"))
        #expect(verifierScript.contains("run_sample baseline"))
        #expect(verifierScript.contains("run_sample preferences"))
        #expect(verifierScript.contains("launch_command_elapsed_ms"))
        #expect(verifierScript.contains("preference_load_elapsed_ms"))
        #expect(verifierScript.contains("startup_elapsed_ms"))
        #expect(verifierScript.contains("app.process.start"))
        #expect(verifierScript.contains("app.did_finish_launching.succeeded"))
        #expect(verifierScript.contains("startup_median_ms"))
        #expect(verifierScript.contains("startup_max_vs_baseline_median_ms"))
        #expect(verifierScript.contains("preference_load_median_ms"))
        #expect(verifierScript.contains("run-debug-observability.sh"))
        #expect(verifierScript.contains("run-debug-preferences-observability.sh"))
        #expect(verifierScript.contains("app.preferences.global.loaded"))
        #expect(
            verifierScript.contains(
                "event_filter=\"$(logsql_exact_filter \"_msg\" \"app.preferences.global.loaded\")\""))
        #expect(verifierScript.contains("wait_for_debug_observability"))
        #expect(verifierScript.contains("wait_for_preference_status"))
        #expect(verifierScript.contains("AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_VERIFY_ATTEMPTS"))
        #expect(verifierScript.contains("raw-launch-samples.tsv"))
        #expect(verifierScript.contains("summary.json"))
        #expect(verifierScript.contains("validate_loopback_url AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL"))
        #expect(miseConfig.contains("description = \"Verify global preferences loader and launch startup budgets\""))
    }

    @Test("preferences launchers reject escaped data roots before writing preferences")
    func preferencesLaunchersRejectEscapedDataRootsBeforeWritingPreferences() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let escapedDebugRoot = fixture.url("escaped-debug-root")
        let escapedBetaRoot = fixture.url("escaped-beta-root")
        let escapedStableRoot = fixture.url("escaped-stable-root")
        let debugHome = fixture.url("debug-home")
        let betaProofRoot = fixture.url("beta-proof-root")
        let stableArtifactRoot = fixture.url("stable-artifact-root")
        let stableStateFile = fixture.url("stable-state.env")
        let stableApp = try fixture.makeAppBundle(
            name: "AgentStudio.app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app"
        )
        let pgrep = try fixture.executable(
            "pgrep",
            """
            #!/bin/bash
            exit 1
            """
        )

        let debugResult = try await fixture.runScript(
            "scripts/run-debug-preferences-observability.sh",
            arguments: [],
            environment: [
                "AGENTSTUDIO_TRACE_NAME": "escaped-debug-root",
                "HOME": debugHome.path,
                "AGENTSTUDIO_DEBUG_DATA_DIR": escapedDebugRoot.path,
            ])
        #expect(debugResult.exitCode == 2)
        #expect(debugResult.stderr.contains("AGENTSTUDIO_DEBUG_DATA_DIR must stay under"))
        #expect(
            !FileManager.default.fileExists(atPath: escapedDebugRoot.appending(path: "preferences.global.json").path))

        let betaResult = try await fixture.runScript(
            "scripts/run-beta-preferences-observability.sh",
            arguments: ["--app", fixture.url("AgentStudio Beta.app").path],
            environment: [
                "AGENTSTUDIO_TRACE_NAME": "escaped-beta-root",
                "AGENTSTUDIO_BETA_PREFERENCES_PROOF_ROOT": betaProofRoot.path,
                "AGENTSTUDIO_BETA_DATA_DIR": escapedBetaRoot.path,
            ])
        #expect(betaResult.exitCode == 2)
        #expect(betaResult.stderr.contains("AGENTSTUDIO_BETA_DATA_DIR must stay under"))
        #expect(
            !FileManager.default.fileExists(atPath: escapedBetaRoot.appending(path: "preferences.global.json").path))

        let stableResult = try await fixture.runScript(
            "scripts/run-stable-preferences-observability.sh",
            arguments: ["--app", stableApp.path, "--detach"],
            environment: [
                "AGENTSTUDIO_TRACE_NAME": "escaped-stable-root",
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stableStateFile.path,
                "AGENTSTUDIO_STABLE_ARTIFACT_ROOT": stableArtifactRoot.path,
                "AGENTSTUDIO_STABLE_DATA_DIR": escapedStableRoot.path,
                "AGENTSTUDIO_PGREP_BIN": pgrep.path,
            ])
        #expect(stableResult.exitCode == 2)
        #expect(stableResult.stderr.contains("AGENTSTUDIO_STABLE_DATA_DIR must stay under"))
        #expect(
            !FileManager.default.fileExists(atPath: escapedStableRoot.appending(path: "preferences.global.json").path))
        let stableState = try String(contentsOf: stableStateFile, encoding: .utf8)
        #expect(stableState.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(stableState.contains("AGENTSTUDIO_OBSERVABILITY_REASON=invalid_data_root"))
    }

    @Test("beta observability verifier requires global preference load event in preference mode")
    func betaObservabilityVerifierRequiresGlobalPreferenceLoadEventInPreferenceMode() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let betaApp = try fixture.makeAppBundle(
            name: "AgentStudio Beta.app",
            releaseChannel: "beta"
        )
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=beta-marker
        AGENTSTUDIO_OBSERVABILITY_SERVICE_VERSION=0.0.0-test
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(betaApp.path))
        AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE=honor_preferences
        """.write(to: stateFile, atomically: true, encoding: .utf8)
        let curlArguments = fixture.url("curl-arguments")

        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-beta-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_EXPECTED_BETA_APP": betaApp.path,
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    printf '%s\\n' "$*" >> "\(curlArguments.path)"
                    if [[ "$*" == *"app.preferences.global.loaded"* ]]; then
                      exit 0
                    fi
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *":*"* ]]; then
                      exit 0
                    fi
                    printf '{"service.name":"AgentStudio","service.version":"0.0.0-test","dev.release.channel":"beta","_msg":"app.process.start"}\\n'
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
        #expect(result.stderr.contains("no global preferences loaded record"))
        let curlArgumentText = try String(contentsOf: curlArguments, encoding: .utf8)
        #expect(curlArgumentText.contains("app.preferences.global.loaded"))
    }

    @Test("debug observability verifier requires global preference load event in preference mode")
    func debugObservabilityVerifierRequiresGlobalPreferenceLoadEventInPreferenceMode() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=debug-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=\(LauncherScriptFixture.currentProcessStartIdentity)
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(fixture.url("Agent Studio Debug testcode.app").path))
        AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE=honor_preferences
        """.write(to: stateFile, atomically: true, encoding: .utf8)
        let debugApp = try fixture.makeAppBundle(
            name: "Agent Studio Debug testcode.app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug", debugCode: "testcode"
        )
        let curlArguments = fixture.url("curl-arguments")

        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-debug-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl",
                    """
                    #!/bin/bash
                    printf '%s\\n' "$*" >> "\(curlArguments.path)"
                    if [[ "$*" == *"app.preferences.global.loaded"* ]]; then
                      exit 0
                    fi
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
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
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("no global preferences loaded record"))
        let curlArgumentText = try String(contentsOf: curlArguments, encoding: .utf8)
        #expect(curlArgumentText.contains("app.preferences.global.loaded"))
    }
}
