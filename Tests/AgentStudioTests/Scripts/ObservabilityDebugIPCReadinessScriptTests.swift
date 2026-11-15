import AgentStudioTestHarness
import Foundation
import Testing

extension ObservabilityDebugLaunchScriptsTests {
    @Test("launch deadlines remain expired across separate system Python processes")
    func debugLauncherRecognizesExpiredDeadlineAcrossProcesses() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let referencePython = try await TestToolResolver.resolved().python3
        let source = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)
        let clockStart = try #require(source.range(of: "launch_wait_time() {"))
        let clockEnd = try #require(source.range(of: "wait_for_app_ipc() {"))
        let clockFunctions = String(source[clockStart.lowerBound..<clockEnd.lowerBound])
        // Controlled clocks cannot detect a process-local origin in the production clock.
        // This deadline is already past before its consumer starts, independent of scheduling speed.
        let command = try fixture.executable(
            "expired-shared-clock",
            """
            #!/bin/bash
            set -euo pipefail
            \(clockFunctions)
            unset AGENTSTUDIO_OBSERVABILITY_TEST_LAUNCH_CLOCK_BIN
            launch_wait_deadline=$("$LAUNCH_CLOCK_REFERENCE_PYTHON" -c 'import time; print(time.clock_gettime(time.CLOCK_MONOTONIC) - 1)')
            if launch_wait_has_time; then exit 0; fi
            printf 'deadline_expired\\n'
            exit 1
            """
        )
        let result = try await fixture.runScript(
            command.path, arguments: [], environment: ["LAUNCH_CLOCK_REFERENCE_PYTHON": referencePython.path]
        )
        #expect(result.exitCode == 1, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stdout == "deadline_expired\n")
    }

    @Test("PID discovery stops at the elapsed launch deadline before another inventory")
    func debugLauncherBoundsPIDDiscoveryByElapsedTime() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let launchedApp = fixture.url("launched-app")
        let lateProbe = fixture.url("late-pid-probe")
        let clockRead = fixture.url("clock-read")
        let buildPath = try fixture.makeDebugBuildExecutable("#!/bin/bash\nexit 0\n")
        var environment = try launchServicesDiagnosticEnvironment(
            fixture: fixture, openArgsURL: fixture.url("open-args"), launchedAppURL: launchedApp, stateFile: stateFile
        )
        environment["AGENTSTUDIO_PID_WAIT_ATTEMPTS"] = "2"
        environment["AGENTSTUDIO_PGREP_BIN"] = try fixture.executable(
            "missing-pid", "#!/bin/bash\n[ ! -f '\(launchedApp.path)' ] || touch '\(lateProbe.path)'\nexit 1\n"
        ).path
        environment["AGENTSTUDIO_OBSERVABILITY_TEST_LAUNCH_CLOCK_BIN"] = try fixture.executable(
            "expired-pid-clock",
            "#!/bin/bash\nif [ -f '\(clockRead.path)' ]; then echo 1; else touch '\(clockRead.path)'; echo 0; fi\n"
        ).path
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"], environment: environment
        )
        #expect(result.exitCode == 1, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: lateProbe.path))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=launchservices_pid_not_found"))
    }

    @Test("IPC readiness fails when its launched process exits between health attempts")
    func debugLauncherStopsWhenPIDExitsDuringIPCWait() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let healthCalls = fixture.url("health-calls-before-exit")
        let buildPath = try fixture.makeDebugBuildExecutable("#!/bin/bash\nexit 0\n")
        try fixture.makeDebugBuildCLI("#!/bin/bash\necho attempted >> '\(healthCalls.path)'\nexit 1\n")
        var environment = try launchServicesDiagnosticEnvironment(
            fixture: fixture, openArgsURL: fixture.url("open-args"),
            launchedAppURL: fixture.url("launched-app"), stateFile: stateFile
        )
        environment["AGENTSTUDIO_OBSERVABILITY_TEST_PROCESS_ALIVE_BIN"] = try fixture.executable(
            "process-exited", "#!/bin/bash\n[ ! -f '\(healthCalls.path)' ]\n"
        ).path
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"], environment: environment
        )
        #expect(result.exitCode == 1, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let calls = try String(contentsOf: healthCalls, encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 1)
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=ipc_app_exited"))
        #expect(!state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running"))
    }

    @Test("manual launch health does not grant an automation credential")
    func debugLauncherChecksManualLaunchWithoutGrantingEscrow() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let healthReply = fixture.url("manual-health-reply")
        let healthCount = fixture.url("manual-health-count")
        try "0".write(to: healthCount, atomically: true, encoding: .utf8)
        let buildPath = try fixture.makeDebugBuildExecutable("#!/bin/bash\nexit 0\n")
        try fixture.makeDebugBuildCLI(
            """
            #!/bin/bash
            set -eu
            printf '%s' "$(($(cat '\(healthCount.path)') + 1))" > '\(healthCount.path)'
            [ -z "${AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW:-}" ] || exit 71
            [ "$1" = --socket ] && [ "$3" = system.ping ] || exit 72
            case "$2" in */ipc-socket/agentstudio.sock) ;; *) exit 73 ;; esac
            printf 'healthy' > '\(healthReply.path)'
            """
        )
        var environment = try launchServicesDiagnosticEnvironment(
            fixture: fixture, openArgsURL: fixture.url("open-args"),
            launchedAppURL: fixture.url("launched-app"), stateFile: stateFile
        )
        environment.removeValue(forKey: "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW")
        environment.removeValue(forKey: "AGENTSTUDIO_IPC_UNSAFE_NO_AUTH")
        environment["AGENTSTUDIO_OBSERVABILITY_TEST_LAUNCH_CLOCK_BIN"] = try fixture.executable(
            "manual-launch-clock", "#!/bin/bash\ncat '\(healthCount.path)'\n"
        ).path
        environment["AGENTSTUDIO_PID_WAIT_ATTEMPTS"] = "20"
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"], environment: environment
        )
        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE=authenticated"))
        #expect((try? String(contentsOf: healthReply, encoding: .utf8)) == "healthy")
    }

    @Test(
        "running requires successful IPC health within the shared launch deadline",
        arguments: [(3, false), (4, false), (0, false), (3, true)]
    )
    func debugLauncherWaitsForIPCHealth(successAttempt: Int, pidUsesBudget: Bool) async throws {
        let healthSucceeds = successAttempt == 3 && !pidUsesBudget
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let healthCount = fixture.url("health-count")
        let healthCalls = fixture.url("health-calls")
        let escrow = try fixture.makeDebugEscrow()
        let pidObserved = fixture.url("pid-observed")
        try "0".write(to: healthCount, atomically: true, encoding: .utf8)
        let buildPath = try fixture.makeDebugBuildExecutable("#!/bin/bash\nexit 0\n")
        try fixture.makeDebugBuildCLI(
            """
            #!/bin/bash
            set -eu
            count=$(cat "\(healthCount.path)")
            count=$((count + 1))
            printf '%s' "$count" > "\(healthCount.path)"
            printf 'attempt-%s\\n' "$count" >> "\(healthCalls.path)"
            [ "$*" = "system.ping" ] || exit 71
            [ "${AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW:-}" = "\(escrow.path)" ] || exit 72
            for variable in AGENTSTUDIO_PANE_TOKEN AGENTSTUDIO_IPC_SOCKET AGENTSTUDIO_PANE_ID AGENTSTUDIO_WORKSPACE_ID; do
              [ -z "${!variable:-}" ] || exit 73
            done
            if [ -f "\(stateFile.path)" ] && /usr/bin/grep -q '^AGENTSTUDIO_OBSERVABILITY_STATUS=running$' "\(stateFile.path)"; then
              printf 'premature-running\\n' >> "\(healthCalls.path)"
              exit 74
            fi
            if [ "$count" -eq \(successAttempt) ]; then
              printf 'health-succeeded\\n' >> "\(healthCalls.path)"
              exit 0
            fi
            exit 1
            """
        )
        var environment = try launchServicesDiagnosticEnvironment(
            fixture: fixture, openArgsURL: fixture.url("open-args"),
            launchedAppURL: fixture.url("launched-app"), stateFile: stateFile
        )
        environment["AGENTSTUDIO_PGREP_BIN"] = try fixture.executable(
            "pgrep",
            """
            #!/bin/bash
            [ -f '\(fixture.url("launched-app").path)' ] || exit 1
            touch '\(pidObserved.path)'
            echo 42424
            """
        ).path
        environment["AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW"] = escrow.path
        // The clock advances only when health completes. Machine speed cannot expire the test's deadline.
        environment["AGENTSTUDIO_OBSERVABILITY_TEST_LAUNCH_CLOCK_BIN"] = try fixture.executable(
            "launch-clock",
            """
            #!/bin/bash
            pid_elapsed=0
            if [ -f '\(pidObserved.path)' ]; then pid_elapsed=\(pidUsesBudget ? 30 : 0); fi
            printf '%s' "$(($(cat '\(healthCount.path)') * 10 + pid_elapsed))"
            """
        ).path
        environment["AGENTSTUDIO_PID_WAIT_ATTEMPTS"] = "400"
        environment["AGENTSTUDIO_PANE_TOKEN"] = "unrelated-pane-credential"
        environment["AGENTSTUDIO_IPC_SOCKET"] = "/unrelated/socket"
        environment["AGENTSTUDIO_PANE_ID"] = "unrelated-pane"
        environment["AGENTSTUDIO_WORKSPACE_ID"] = "unrelated-workspace"

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"], environment: environment
        )

        #expect(result.exitCode == (healthSucceeds ? 0 : 1), "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let calls = (try? String(contentsOf: healthCalls, encoding: .utf8)) ?? ""
        let expectedAttempts = pidUsesBudget ? 1 : (healthSucceeds ? 3 : 4)
        #expect(calls.split(separator: "\n").filter { $0.hasPrefix("attempt-") }.count == expectedAttempts)
        #expect(!calls.contains("premature-running"))
        #expect(calls.contains("health-succeeded") == (successAttempt != 0 && !pidUsesBudget))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        if healthSucceeds {
            #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running"))
        } else {
            #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
            #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=ipc_health_timeout"))
            #expect(!state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running"))
        }
    }
}
