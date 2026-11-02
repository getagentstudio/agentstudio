import Darwin
import Foundation
import Testing

@Suite("Observability debug IPC launch script verifier")
struct ObservabilityDebugIPCLaunchScriptTests {
    @Test("debug observability verifier requires requested IPC terminal smoke telemetry")
    func debugObservabilityVerifierRequiresRequestedIPCTerminalSmokeTelemetry() async throws {
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
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=ipc-terminal-smoke
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
                    "curl-missing-ipc-terminal-smoke",
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

    @Test("debug observability verifier accepts completed IPC terminal smoke telemetry")
    func debugObservabilityVerifierAcceptsCompletedIPCTerminalSmokeTelemetry() async throws {
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
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=ipc-terminal-smoke
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
                    "curl-ipc-terminal-smoke",
                    """
                    #!/bin/bash
                    printf '%s\\n' "$*" >> "\(curlArguments.path)"
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action.command_exercised"* ]]; then
                      printf '{"_msg":"app.startup_diagnostic_action.command_exercised","agentstudio.startup_diagnostic.action":"ipc-terminal-smoke","agentstudio.startup_diagnostic.created_pane.count":1,"agentstudio.startup_diagnostic.pane.id":"019ECB5A-7A66-7109-B45E-ED52BC59DA78","agentstudio.startup_diagnostic.expected_visible_pane.count":1,"agentstudio.startup_diagnostic.fixture.terminal_view.count":1,"agentstudio.startup_diagnostic.fixture.surface_reference.count":1,"agentstudio.startup_diagnostic.fixture.surface.count":1,"agentstudio.startup_diagnostic.fixture.valid_geometry.count":1,"agentstudio.startup_diagnostic.render_proof.succeeded":true}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action.completed"* ]]; then
                      printf '{"_msg":"app.startup_diagnostic_action.completed","agentstudio.startup_diagnostic.action":"ipc-terminal-smoke","agentstudio.startup_diagnostic.created_pane.count":1,"agentstudio.startup_diagnostic.pane.id":"019ECB5A-7A66-7109-B45E-ED52BC59DA78","agentstudio.startup_diagnostic.expected_visible_pane.count":1,"agentstudio.startup_diagnostic.fixture.terminal_view.count":1,"agentstudio.startup_diagnostic.fixture.surface_reference.count":1,"agentstudio.startup_diagnostic.fixture.surface.count":1,"agentstudio.startup_diagnostic.fixture.valid_geometry.count":1,"agentstudio.startup_diagnostic.render_proof.succeeded":true}\\n'
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
        let expectedDiagnosticFilter = "agentstudio.startup_diagnostic.action:=\"ipc-terminal-smoke\""
        #expect(curlArgumentText.contains("app.startup_diagnostic_action.command_exercised"))
        #expect(curlArgumentText.contains("app.startup_diagnostic_action.completed"))
        #expect(curlArgumentText.contains(expectedDiagnosticFilter))
        #expect(curlArgumentText.contains("agentstudio.startup_diagnostic.render_proof.succeeded"))
    }

    @Test("debug observability verifier rejects IPC smoke with extra created panes")
    func debugObservabilityVerifierRejectsIPCSmokeWithExtraCreatedPanes() async throws {
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
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=ipc-terminal-smoke
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
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-ipc-terminal-smoke-extra-pane",
                    """
                    #!/bin/bash
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action.command_exercised"* ]]; then
                      printf '{"_msg":"app.startup_diagnostic_action.command_exercised","agentstudio.startup_diagnostic.action":"ipc-terminal-smoke","agentstudio.startup_diagnostic.created_pane.count":10}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action.completed"* ]]; then
                      printf '{"_msg":"app.startup_diagnostic_action.completed","agentstudio.startup_diagnostic.action":"ipc-terminal-smoke","agentstudio.startup_diagnostic.created_pane.count":10}\\n'
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
        #expect(result.stderr.contains("startup diagnostic completed without creating one IPC smoke pane"))
    }

    @Test("debug observability verifier rejects IPC smoke without render proof")
    func debugObservabilityVerifierRejectsIPCSmokeWithoutRenderProof() async throws {
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
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=ipc-terminal-smoke
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
                "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                    "curl-ipc-terminal-smoke-missing-render-proof",
                    """
                    #!/bin/bash
                    if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                      printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action.command_exercised"* ]]; then
                      printf '{"_msg":"app.startup_diagnostic_action.command_exercised","agentstudio.startup_diagnostic.action":"ipc-terminal-smoke","agentstudio.startup_diagnostic.created_pane.count":1}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"app.startup_diagnostic_action.completed"* ]]; then
                      printf '{"_msg":"app.startup_diagnostic_action.completed","agentstudio.startup_diagnostic.action":"ipc-terminal-smoke","agentstudio.startup_diagnostic.created_pane.count":1}\\n'
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
        #expect(result.stderr.contains("startup diagnostic completed without successful IPC terminal render proof"))
    }
}
