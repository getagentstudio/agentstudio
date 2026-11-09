import Darwin
import Foundation
import Testing

@Suite("Observability debug launch scripts")
struct ObservabilityDebugLaunchScriptsTests {
    @Test("debug launcher uses four-character worktree code for socket path headroom")
    func debugLauncherUsesFourCharacterWorktreeCodeForSocketPathHeadroom() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--print-identity"],
            environment: [:]
        )
        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let codeMatch = result.stdout.firstMatch(of: /AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=([0-9a-z]+)/)
        let code = String(codeMatch?.1 ?? "")
        #expect(code.count == 4)
        #expect(code.wholeMatch(of: /[0-9a-z]{4}/) != nil)
        #expect(result.stdout.contains("Agent\\ Studio\\ Debug\\ \(code)"))
        #expect(result.stdout.contains("/.agentstudio-db/\(code)"))
    }

    @Test("debug launcher projects an explicit disposable data and zmx identity")
    func debugLauncherProjectsExplicitDisposableDataIdentity() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let disposableDataRoot = fixture.url("disposable-proof-data")
        let disposableZmxRoot = disposableDataRoot.appending(path: "z")
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--print-identity"],
            environment: ["AGENTSTUDIO_DEBUG_DATA_DIR": disposableDataRoot.path]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(
            result.stdout.contains(
                "AGENTSTUDIO_OBSERVABILITY_DATA_DIR=\(shellEscapedStateValue(disposableDataRoot.path))"
            )
        )
        #expect(
            result.stdout.contains(
                "AGENTSTUDIO_OBSERVABILITY_ZMX_DIR=\(shellEscapedStateValue(disposableZmxRoot.path))"
            )
        )
    }

    @Test("debug launcher allocates a shared swift build slot by default")
    func debugLauncherAllocatesSharedSwiftBuildSlotByDefault() throws {
        let script = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)
        #expect(script.contains("source \"$PROJECT_ROOT/scripts/swift-build-slot.sh\""))
        #expect(!script.contains("swift-build-slot.sh\" debug"))
        #expect(script.contains("mise run bridge-web-build"))
        #expect(script.contains("swift build $(swift_package_sandbox_arguments) --build-path \"$build_path\""))
    }

    @Test("debug launcher uses ai-tools observability stack contract")
    func debugLauncherUsesAiToolsObservabilityStackContract() throws {
        let script = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)
        #expect(script.contains("AI_TOOLS_OBSERVABILITY_STACK_HELPER"))
        #expect(script.contains("AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL"))
        #expect(script.contains("AGENTSTUDIO_TRACE_PROOF_TOKEN"))
        #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN"))
        #expect(script.contains("$HOME/dev/ai-tools/observability/observability-stack"))
        #expect(!script.contains("SHRAVAN_OBSERVABILITY"))
        #expect(!script.contains("$HOME/dev/devfiles/shared/observability/observability-stack"))
    }

    @Test("debug launcher prefers stable Developer ID signing when available")
    func debugLauncherPrefersStableDeveloperIDSigningWhenAvailable() throws {
        let script = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)
        #expect(script.contains("SECURITY_BIN=\"${AGENTSTUDIO_SECURITY_BIN:-/usr/bin/security}\""))
        #expect(script.contains("debug_signing_identity()"))
        #expect(script.contains("AGENTSTUDIO_DEBUG_SIGNING_IDENTITY"))
        #expect(script.contains("SIGNING_IDENTITY"))
        #expect(script.contains("\"$SECURITY_BIN\" find-identity -v -p codesigning"))
        #expect(script.contains("Developer ID Application"))
        #expect(script.contains("codesign_debug_item()"))
        #expect(script.contains("--options runtime"))
        #expect(script.contains("--entitlements \"$entitlements\""))
        #expect(script.contains("debug signing identity: $signing_identity"))
        #expect(script.contains("debug signing identity: ad-hoc"))
        #expect(script.contains("codesign_debug_item \"$app_dir/MacOS/zmx\" \"$signing_identity\" \"$entitlements\""))
        #expect(script.contains("codesign_debug_item \"$app_path\" \"$signing_identity\" \"$entitlements\""))
    }

    @Test("debug launcher rejects unsafe trace names before launch")
    func debugLauncherRejectsUnsafeTraceNamesBeforeLaunch() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let openMarker = fixture.url("open-called")
        let buildPath = try fixture.makeDebugBuildExecutable(
            """
            #!/bin/bash
            sleep 30
            """
        )
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"],
            environment: [
                "AGENTSTUDIO_TRACE_NAME": "../../bad",
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
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("invalid AGENTSTUDIO_TRACE_NAME"))
        #expect(!FileManager.default.fileExists(atPath: openMarker.path))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=invalid_trace_name"))
    }

    @Test("debug launcher refuses same worktree debug app outside default artifact root")
    func debugLauncherRefusesSameWorktreeDebugRuntimeByCodeAndPath() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let debugCode = try await fixture.worktreeDebugCode()
        let runningApp = try fixture.makeAppBundle(
            name: "external/AgentStudio Debug \(debugCode).app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug", debugCode: "\(debugCode)"
        )
        let openMarker = fixture.url("open-called")
        let stateFile = fixture.url("latest.env")

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: [
                "--build-path", fixture.url("unused-build").path,
                "--skip-build", "--detach",
            ],
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
                    echo 5252
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(runningApp.path)/Contents/MacOS/AgentStudio"
                    """
                ).path,
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: openMarker.path))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=already_running"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=\(debugCode)"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_PID=5252"))
    }

    @Test("debug launcher fails closed when running process attribution is unavailable")
    func debugLauncherFailsClosedWhenRunningProcessAttributionIsUnavailable() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: [
                "--build-path", fixture.url("unused-build").path,
                "--skip-build", "--detach",
            ],
            environment: [
                "AGENTSTUDIO_PGREP_BIN": try fixture.executable(
                    "pgrep",
                    """
                    #!/bin/bash
                    echo 5353
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    exit 1
                    """
                ).path,
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1)
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=duplicate_attribution_failed"))
    }

    @Test("debug launcher overwrites stale running state when collector health fails")
    func debugLauncherOverwritesStaleRunningStateWhenCollectorHealthFails() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=stale-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=stale
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=\(LauncherScriptFixture.currentProcessStartIdentity)
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: [
                "--build-path", fixture.url("unused-build").path,
                "--skip-build", "--detach",
            ],
            environment: [
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
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=otlp_collector_unhealthy"))
        #expect(!state.contains("stale-marker"))
    }

    @Test("debug launcher ignores stale state PID when bundle identity does not match")
    func debugLauncherIgnoresStaleStatePIDWhenBundleIdentityDoesNotMatch() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let debugCode = try await fixture.worktreeDebugCode()
        let unrelatedApp = try fixture.makeAppBundle(
            name: "Unrelated AgentStudio.app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app"
        )
        let stateFile = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=\(debugCode)
        AGENTSTUDIO_OBSERVABILITY_PID=5454
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)
        let buildPath = try fixture.makeDebugBuildExecutable(
            """
            #!/bin/bash
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
                    echo 5454
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(unrelatedApp.path)/Contents/MacOS/AgentStudio"
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
            ]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        defer {
            if let pid = state.firstMatch(of: /AGENTSTUDIO_OBSERVABILITY_PID=([0-9]+)/)?.1 {
                kill(pid_t(pid) ?? -1, SIGTERM)
            }
        }
        #expect(!state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=already_running"))
        try fixture.expectIPCHealthChecked()
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=direct_executable"))
    }

    @Test("debug launcher refuses running direct executable from state file")
    func debugLauncherRefusesRunningDirectExecutableFromStateFile() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let debugCode = try await fixture.worktreeDebugCode()
        let stateFile = fixture.url("latest.env")
        let openMarker = fixture.url("open-called")
        let buildPath = fixture.url("debug-build")
        let debugPath = buildPath.appending(path: "debug")
        try FileManager.default.createDirectory(at: debugPath, withIntermediateDirectories: true)
        let executableURL = debugPath.appending(path: "AgentStudio")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executableURL)
        chmod(executableURL.path, 0o755)
        let executablePath = buildPath.appending(path: "debug/AgentStudio").path
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=\(debugCode)
        AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=direct_executable
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=\(LauncherScriptFixture.currentProcessStartIdentity)
        AGENTSTUDIO_OBSERVABILITY_EXECUTABLE=\(executablePath)
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"],
            environment: [
                "AGENTSTUDIO_OPEN_BIN": try fixture.executable(
                    "open",
                    """
                    #!/bin/bash
                    echo called > "\(openMarker.path)"
                    exit 0
                    """
                ).path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof",
                    """
                    #!/bin/bash
                    echo "n\(executablePath)"
                    """
                ).path,
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            ]
        )

        #expect(result.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: openMarker.path))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=already_running"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())"))
    }

    @Test("debug launcher ignores stale direct executable state when PID attribution differs")
    func debugLauncherIgnoresStaleDirectExecutableStateWhenPIDAttributionDiffers() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let debugCode = try await fixture.worktreeDebugCode()
        let stateFile = fixture.url("latest.env")
        let buildPath = try fixture.makeDebugBuildExecutable(
            """
            #!/bin/bash
            sleep 30
            """
        )
        let executablePath = buildPath.appending(path: "debug/AgentStudio").path
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=\(debugCode)
        AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=direct_executable
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=\(LauncherScriptFixture.currentProcessStartIdentity)
        AGENTSTUDIO_OBSERVABILITY_EXECUTABLE=\(executablePath)
        """
        .appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)

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
                "AGENTSTUDIO_PID_WAIT_ATTEMPTS": "1",
            ]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        defer {
            if let pid = state.firstMatch(of: /AGENTSTUDIO_OBSERVABILITY_PID=([0-9]+)/)?.1 {
                kill(pid_t(pid) ?? -1, SIGTERM)
            }
        }
        #expect(!state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=already_running"))
        try fixture.expectIPCHealthChecked()
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running"))
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=direct_executable"))
    }
}
