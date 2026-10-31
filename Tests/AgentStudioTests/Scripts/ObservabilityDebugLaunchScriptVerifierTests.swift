import Darwin
import Foundation
import Testing

@Suite("Observability debug launch script verifier")
struct ObservabilityDebugLaunchScriptVerifierTests {

    @Test("debug launcher overwrites stale state when collector is unhealthy")
    func debugLauncherOverwritesStaleStateWhenCollectorIsUnhealthy() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let buildPath = try fixture.makeDebugBuildExecutable(
            """
            #!/bin/bash
            sleep 30
            """
        )
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_PID=99999
        AGENTSTUDIO_OBSERVABILITY_MARKER=stale-marker
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"],
            environment: [
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-unhealthy",
                    """
                    #!/bin/bash
                    exit 22
                    """
                ).path,
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1)
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=otlp_collector_unhealthy"))
        #expect(!state.contains("stale-marker"))
    }

    @Test("debug launcher falls back to direct executable when local app bundle is blocked")
    func debugLauncherFallsBackToDirectExecutableWhenLaunchServicesBlocksLocalBundle() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let hostileDataRoot = fixture.url("hostile-data")
        let buildPath = try fixture.makeDebugBuildExecutable(
            """
            #!/bin/bash
            for name in ZMX_DIR ZMX_SESSION ZMX_SESSION_PREFIX GHOSTTY_RESOURCES_DIR GHOSTTY_BIN_DIR __CFBundleIdentifier; do
              if [ -n "${!name:-}" ]; then
                printf "%s leaked\\n" "$name" > "\(fixture.url("leaked-env").path)"
                exit 44
              fi
            done
            printf "data=%s\\n" "$AGENTSTUDIO_DATA_DIR" > "\(fixture.url("launched-env").path)"
            printf "ipc_socket_dir=%s\\n" "$AGENTSTUDIO_IPC_SOCKET_DIR" >> "\(fixture.url("launched-env").path)"
            printf "zmx_path=%s\\n" "$AGENTSTUDIO_ZMX_PATH" >> "\(fixture.url("launched-env").path)"
            printf "ghostty_disable_default_config=%s\\n" "$AGENTSTUDIO_GHOSTTY_DISABLE_DEFAULT_CONFIG" >> "\(fixture.url("launched-env").path)"
            printf "ghostty_disable_vsync=%s\\n" "$AGENTSTUDIO_GHOSTTY_DISABLE_VSYNC" >> "\(fixture.url("launched-env").path)"
            printf "backend=%s\\n" "$AGENTSTUDIO_TRACE_BACKEND" >> "\(fixture.url("launched-env").path)"
            printf "marker=%s\\n" "$AGENTSTUDIO_TRACE_NAME" >> "\(fixture.url("launched-env").path)"
            printf "restore_trace=%s\\n" "${AGENTSTUDIO_RESTORE_TRACE:-}" >> "\(fixture.url("launched-env").path)"
            printf "diagnostic=%s\\n" "${AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION:-}" >> "\(fixture.url("launched-env").path)"
            printf "watch_folder=%s\\n" "${AGENTSTUDIO_STARTUP_WATCH_FOLDER:-}" >> "\(fixture.url("launched-env").path)"
            printf "ipc_no_auth=%s\\n" "${AGENTSTUDIO_IPC_UNSAFE_NO_AUTH:-}" >> "\(fixture.url("launched-env").path)"
            printf "ipc_escrow=%s\\n" "${AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW:-}" >> "\(fixture.url("launched-env").path)"
            sleep 30
            """
        )

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"],
            environment: [
                "AGENTSTUDIO_OPEN_BIN": try fixture.executable(
                    "open",
                    """
                    #!/bin/bash
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
                "AGENTSTUDIO_DITTO_BIN": try fixture.executable(
                    "ditto",
                    """
                    #!/bin/bash
                    cp -R "$1" "$2"
                    """
                ).path,
                "AGENTSTUDIO_CODESIGN_BIN": try fixture.executable(
                    "codesign",
                    """
                    #!/bin/bash
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
                "AGENTSTUDIO_DEBUG_DATA_DIR": hostileDataRoot.path,
                "AGENTSTUDIO_RESTORE_TRACE": "1",
                "AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION": "cross-tab-move-geometry-smoke",
                "AGENTSTUDIO_STARTUP_WATCH_FOLDER": fixture.url("watch-folder").path,
                "AGENTSTUDIO_IPC_UNSAFE_NO_AUTH": "1",
                "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW": try fixture.makeDebugEscrow().path,
                "ZMX_DIR": "/tmp/hostile-zmx-dir",
                "ZMX_SESSION": "hostile-session",
                "ZMX_SESSION_PREFIX": "hostile-prefix",
                "GHOSTTY_RESOURCES_DIR": "/tmp/hostile-ghostty-resources",
                "GHOSTTY_BIN_DIR": "/tmp/hostile-ghostty-bin",
                "__CFBundleIdentifier": "com.hostile.bundle",
            ]
        )

        #expect(result.exitCode == 0)
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        defer {
            if let pid = state.firstMatch(of: /AGENTSTUDIO_OBSERVABILITY_PID=([0-9]+)/)?.1 {
                kill(pid_t(pid) ?? -1, SIGTERM)
            }
        }

        try expectDirectExecutableFallbackState(
            state,
            buildExecutable: buildPath.appending(path: "debug/AgentStudio"),
            hostileDataRoot: hostileDataRoot
        )
        try fixture.expectIPCHealthChecked()
        let launchedEnv = try await fixture.waitForFile(
            fixture.url("launched-env"), containing: "ipc_escrow=\(fixture.url("ipc-escrow.json").path)")
        try expectDirectExecutableFallbackLaunchEnvironment(
            launchedEnv, hostileDataRoot: hostileDataRoot, escrowPath: fixture.url("ipc-escrow.json").path)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("leaked-env").path))
    }

    @Test("debug launcher forwards diagnostic env through LaunchServices")
    func debugLauncherForwardsDiagnosticEnvironmentThroughLaunchServices() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let openArgsURL = fixture.url("open-args")
        let launchedAppURL = fixture.url("launched-app")
        let buildPath = try fixture.makeDebugBuildExecutable(
            """
            #!/bin/bash
            sleep 30
            """
        )

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"],
            environment: try launchServicesDiagnosticEnvironment(
                fixture: fixture,
                openArgsURL: openArgsURL,
                launchedAppURL: launchedAppURL,
                stateFile: stateFile
            )
        )

        #expect(result.exitCode == 0)
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        try fixture.expectIPCHealthChecked()
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=launchservices"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_PID=42424"))
        #expect(state.contains("/runs/debug-observability-"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=cross-tab-move-geometry-smoke"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STARTUP_WATCH_FOLDER="))

        let openArgs = try String(contentsOf: openArgsURL, encoding: .utf8)
        #expect(openArgs.split(separator: "\n").contains("-g"))
        #expect(openArgs.contains("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=cross-tab-move-geometry-smoke"))
        #expect(openArgs.contains("AGENTSTUDIO_STARTUP_WATCH_FOLDER="))
        #expect(openArgs.contains("AGENTSTUDIO_RESTORE_TRACE=1"))
        #expect(openArgs.contains("AGENTSTUDIO_IPC_UNSAFE_NO_AUTH=1"))
        #expect(openArgs.contains("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=\(fixture.url("ipc-escrow.json").path)"))
        #expect(openArgs.contains("AGENTSTUDIO_DATA_DIR="))
        #expect(openArgs.contains("AGENTSTUDIO_IPC_SOCKET_DIR="))
        #expect(openArgs.contains("AGENTSTUDIO_ZMX_PATH="))
        #expect(openArgs.contains("AGENTSTUDIO_GHOSTTY_DISABLE_DEFAULT_CONFIG=1"))
        #expect(openArgs.contains("AGENTSTUDIO_GHOSTTY_DISABLE_VSYNC=1"))
        #expect(openArgs.contains("/bin/zmx"))
        #expect(openArgs.contains("/ipc-socket"))
        #expect(openArgs.contains("/runs/debug-observability-"))
        try expectOwnerOnlyDirectory(stateValue("AGENTSTUDIO_OBSERVABILITY_DATA_DIR", in: state))
        try expectOwnerOnlyDirectory(stateValue("AGENTSTUDIO_OBSERVABILITY_ZMX_DIR", in: state))
        try expectOwnerOnlyDirectory(
            openArgs
                .split(separator: "\n")
                .map(String.init)
                .first { $0.hasPrefix("AGENTSTUDIO_IPC_SOCKET_DIR=") }?
                .replacingOccurrences(of: "AGENTSTUDIO_IPC_SOCKET_DIR=", with: "") ?? "")
    }

    @Test("debug launcher foreground activation is explicit opt in")
    func debugLauncherForegroundActivationIsExplicitOptIn() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let openArgsURL = fixture.url("open-args")
        let launchedAppURL = fixture.url("launched-app")
        let buildPath = try fixture.makeDebugBuildExecutable(
            """
            #!/bin/bash
            sleep 30
            """
        )
        var environment = try launchServicesDiagnosticEnvironment(
            fixture: fixture,
            openArgsURL: openArgsURL,
            launchedAppURL: launchedAppURL,
            stateFile: stateFile
        )
        environment["AGENTSTUDIO_DEBUG_LAUNCH_ACTIVATE"] = "1"

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"],
            environment: environment
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let openArguments = try String(contentsOf: openArgsURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(!openArguments.contains("-g"))
        try fixture.expectIPCHealthChecked()
    }

    @Test("debug observability verifier requires requested startup diagnostic telemetry")
    func debugObservabilityVerifierRequiresRequestedStartupDiagnosticTelemetry() async throws {
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
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=cross-tab-move-geometry-smoke
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(fixture.url("Agent Studio Debug testcode.app").path))
        """.write(to: stateFile, atomically: true, encoding: .utf8)
        let debugApp = try fixture.makeAppBundle(
            name: "Agent Studio Debug testcode.app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug", debugCode: "testcode"
        )

        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-debug-observability.sh",
            stateFile: stateFile,
            environment: [
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_ATTEMPTS": "1",
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_RETRY_DELAY_SECONDS": "0",
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-missing-startup-diagnostic",
                    """
                    #!/bin/bash
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
                    """
                ).path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("startup diagnostic command_exercised record missing"))
    }

    @Test("debug observability verifier does not require render proof for command bar workload diagnostic")
    func debugObservabilityVerifierDoesNotRequireRenderProofForCommandBarWorkloadDiagnostic() async throws {
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
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=command-bar-repo-filter
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(fixture.url("Agent Studio Debug testcode.app").path))
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
                    "curl-command-bar-workload",
                    """
                    #!/bin/bash
                    printf '%s\\n' "$*" >> "\(curlArguments.path)"
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

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let curlArgumentText = try String(contentsOf: curlArguments, encoding: .utf8)
        #expect(!curlArgumentText.contains("app.startup_diagnostic_action.command_exercised"))
        #expect(!curlArgumentText.contains("app.startup_diagnostic_action.completed"))
    }

    @Test("debug observability verifier accepts completed startup diagnostic render proof")
    func debugObservabilityVerifierAcceptsCompletedStartupDiagnosticRenderProof() async throws {
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
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=cross-tab-move-geometry-smoke
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(fixture.url("Agent Studio Debug testcode.app").path))
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
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action.command_exercised"* ]]; then
                      printf '{"_msg":"app.startup_diagnostic_action.command_exercised","agentstudio.startup_diagnostic.action":"cross-tab-move-geometry-smoke","agentstudio.startup_diagnostic.expected_visible_pane.count":3,"agentstudio.startup_diagnostic.fixture.terminal_view.count":3,"agentstudio.startup_diagnostic.fixture.surface_reference.count":3,"agentstudio.startup_diagnostic.fixture.surface.count":3,"agentstudio.startup_diagnostic.fixture.valid_geometry.count":3,"agentstudio.startup_diagnostic.render_proof.succeeded":true}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action.completed"* ]]; then
                      printf '{"_msg":"app.startup_diagnostic_action.completed","agentstudio.startup_diagnostic.action":"cross-tab-move-geometry-smoke","agentstudio.startup_diagnostic.expected_visible_pane.count":"3","agentstudio.startup_diagnostic.fixture.terminal_view.count":"3","agentstudio.startup_diagnostic.fixture.surface_reference.count":"3","agentstudio.startup_diagnostic.fixture.surface.count":"3","agentstudio.startup_diagnostic.fixture.valid_geometry.count":"3","agentstudio.startup_diagnostic.render_proof.succeeded":"true"}\\n'
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

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let curlArgumentText = try String(contentsOf: curlArguments, encoding: .utf8)
        let expectedDiagnosticFilter =
            "agentstudio.startup_diagnostic.action:=\"cross-tab-move-geometry-smoke\""
        #expect(curlArgumentText.contains("app.startup_diagnostic_action.command_exercised"))
        #expect(curlArgumentText.contains("app.startup_diagnostic_action.completed"))
        #expect(curlArgumentText.contains(expectedDiagnosticFilter))
    }

    @Test("debug launcher exposes idle preflight command")
    func debugLauncherExposesIdlePreflightCommand() throws {
        let source = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)

        #expect(source.contains("run-debug-observability.sh --preflight-idle"))
        #expect(source.contains("preflight_idle=true"))
        #expect(source.contains("running_debug_state_pid \"$state_file\" \"$debug_code\""))
    }

    @Test("debug verifier queries trace marker as VictoriaLogs field")
    func debugVerifierQueriesTraceMarkerAsVictoriaLogsField() throws {
        let source = try String(contentsOfFile: "scripts/verify-debug-observability.sh", encoding: .utf8)

        #expect(source.contains("stream_query=\"{service.name=\\\"AgentStudio\\\",dev.runtime.flavor=\\\"debug\\\"}\""))
        #expect(source.contains("logsql_escape_exact_value()"))
        #expect(source.contains("logsql_exact_filter()"))
        #expect(source.contains("marker_query=\"$(logsql_exact_filter \"agent.proof.marker\" \"$MARKER\")\""))
        #expect(source.contains("startup_event_query=\"$(logsql_exact_filter \"_msg\""))
        #expect(source.contains("query=\"$stream_query $marker_query\""))
        #expect(!source.contains("marker_query=\"agent.proof.marker:${MARKER}\""))
        #expect(!source.contains("agentstudio.trace.name"))
    }

    @Test("debug launcher fails closed when LaunchServices accepts app but PID never appears")
    func debugLauncherFailsClosedWhenLaunchServicesAcceptsAppButPidNeverAppears() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let launchedEnv = fixture.url("launched-env")
        let buildPath = try fixture.makeDebugBuildExecutable(
            """
            #!/bin/bash
            printf "direct fallback launched\\n" > "\(launchedEnv.path)"
            sleep 30
            """
        )

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"],
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
                    exit 1
                    """
                ).path,
                "AGENTSTUDIO_DITTO_BIN": try fixture.executable(
                    "ditto",
                    """
                    #!/bin/bash
                    cp -R "$1" "$2"
                    """
                ).path,
                "AGENTSTUDIO_CODESIGN_BIN": try fixture.executable(
                    "codesign",
                    """
                    #!/bin/bash
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_PID_WAIT_ATTEMPTS": "1",
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: launchedEnv.path))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=launchservices_pid_not_found"))
    }

    @Test("release scripts do not resolve inject-bundle-version through PATH bash")
    func releaseScriptsUseSystemBashForNestedBundleVersionInjection() throws {
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let verifierScript = try String(contentsOfFile: "scripts/verify-release-scripts.sh", encoding: .utf8)

        #expect(!miseConfig.contains("\nbash scripts/inject-bundle-version.sh"))
        #expect(miseConfig.contains("/bin/bash scripts/inject-bundle-version.sh"))
        #expect(
            !miseConfig.contains("run = \"bash \\\"$HOME/dev/devfiles/shared/observability/observability-stack\\\""))
        #expect(!miseConfig.contains("$HOME/dev/devfiles/shared/observability/observability-stack"))
        #expect(!miseConfig.contains("observability:agentstudio-beta-env"))
        #expect(!miseConfig.contains("run = \"bash \\\"$HOME/dev/ai-tools/observability/observability-stack\\\""))
        #expect(
            miseConfig.contains(
                "run = \"/bin/bash \\\"$HOME/dev/ai-tools/observability/observability-stack\\\" up\""))
        #expect(
            miseConfig.contains(
                "run = \"/bin/bash \\\"$HOME/dev/ai-tools/observability/observability-stack\\\" status\""))
        #expect(
            miseConfig.contains(
                "run = \"/bin/bash \\\"$HOME/dev/ai-tools/observability/observability-stack\\\" smoke\""))
        #expect(
            miseConfig.contains(
                "run = \"/bin/bash \\\"$HOME/dev/ai-tools/observability/observability-stack\\\" down\""))
        #expect(!verifierScript.contains("\nbash \"$ROOT_DIR/scripts/inject-bundle-version.sh\""))
        #expect(verifierScript.contains("/bin/bash \"$ROOT_DIR/scripts/inject-bundle-version.sh\""))
    }

}
