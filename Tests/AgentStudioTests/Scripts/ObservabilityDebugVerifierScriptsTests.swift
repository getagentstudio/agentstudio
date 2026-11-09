import Darwin
import Foundation
import Testing

@Suite("Observability debug verifier scripts")
struct ObservabilityDebugVerifierScriptsTests {
    @Test("debug observability verifier queries TCC upgrade probe telemetry when requested")
    func debugObservabilityVerifierQueriesTCCUpgradeProbeTelemetryWhenRequested() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let marker = "debug marker | fields process.pid"
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=\(shellEscapedStateValue(marker))
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=\(LauncherScriptFixture.currentProcessStartIdentity)
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=tcc-upgrade-probe
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
                    if [[ "$*" == *"terminal.tcc.access_probe"* ]]; then
                      printf '{"_msg":"terminal.tcc.access_probe","agentstudio.tcc.phase":"startup_diagnostic","agentstudio.tcc.subject":"shell_child","agentstudio.tcc.access.target":"documents","agentstudio.tcc.access.result":"granted","agentstudio.tcc.responsible.kind":"agentstudio_debug","agentstudio.tcc.command.exit_class":"ok","agentstudio.tcc.probe.sequence":0}\\n'
                      exit 0
                    fi
                    if [[ "$*" == *"terminal.tcc.app_identity_snapshot"* ]]; then
                      printf '{"_msg":"terminal.tcc.app_identity_snapshot","agentstudio.tcc.phase":"startup_diagnostic","agentstudio.tcc.bundle.kind":"debug","agentstudio.tcc.code_identity.kind":"same_disk_identity","agentstudio.tcc.bundle.changed":false,"agentstudio.tcc.bundle.executable.reachable":true,"agentstudio.tcc.probe.sequence":0}\\n'
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
        #expect(curlArgumentText.contains("terminal.tcc.access_probe"))
        #expect(curlArgumentText.contains("terminal.tcc.app_identity_snapshot"))
        #expect(curlArgumentText.contains("_msg:=\"terminal.tcc.access_probe\""))
        #expect(curlArgumentText.contains("_msg:=\"terminal.tcc.app_identity_snapshot\""))
        #expect(curlArgumentText.contains("agentstudio.startup_diagnostic.action:=\"tcc-upgrade-probe\""))
        #expect(curlArgumentText.contains("agent.proof.marker:=\"debug marker | fields process.pid\""))
    }
}
