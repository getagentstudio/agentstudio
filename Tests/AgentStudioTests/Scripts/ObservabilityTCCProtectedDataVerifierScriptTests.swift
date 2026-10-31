import Foundation
import Testing

@Suite("Observability TCC protected-data verifier scripts")
struct ObservabilityTCCProtectedDataVerifierScriptTests {
    @Test("debug and beta verifiers can require protected data grant")
    func verifiersCanRequireProtectedDataGrant() throws {
        let debugScript = try String(contentsOfFile: "scripts/verify-debug-observability.sh", encoding: .utf8)
        let betaScript = try String(contentsOfFile: "scripts/verify-beta-observability.sh", encoding: .utf8)

        for script in [debugScript, betaScript] {
            #expect(script.contains("AGENTSTUDIO_TCC_REQUIRE_PROTECTED_DATA_GRANT"))
            #expect(script.contains("agentstudio.tcc.access.target messages_data"))
            #expect(script.contains("agentstudio.tcc.access.result granted"))
            #expect(script.contains("TCC protected-data grant was required"))
        }
    }

    @Test("strict protected data grant fails on mixed grant and denial sequences")
    func strictProtectedDataGrantFailsOnMixedSequences() async throws {
        try await assertStrictVerifierFailsOnMixedSequences(
            scriptPath: "scripts/verify-debug-observability.sh",
            stateFileBody: debugStateFileBody(appPath:),
            environment: debugVerifierEnvironment(fixture:app:)
        )
    }

    private func assertStrictVerifierFailsOnMixedSequences(
        scriptPath: String,
        stateFileBody: (String) -> String,
        environment: (LauncherScriptFixture, URL) throws -> [String: String]
    ) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let app = try fixture.makeAppBundle(
            name: scriptPath.contains("debug") ? "Agent Studio Debug testcode.app" : "AgentStudioBeta.app",
            releaseChannel: scriptPath.contains("debug") ? "stable" : "beta",
            bundleIdentifier: scriptPath.contains("debug")
                ? "com.agentstudio.app.debug" : "com.agentstudio.app.beta",
            debugCode: scriptPath.contains("debug") ? "testcode" : nil
        )
        try stateFileBody(app.path).write(to: stateFile, atomically: true, encoding: .utf8)

        var verifierEnvironment = try environment(fixture, app)
        verifierEnvironment["AGENTSTUDIO_OBSERVABILITY_STATE_FILE"] = stateFile.path
        verifierEnvironment["AGENTSTUDIO_TCC_REQUIRE_PROTECTED_DATA_GRANT"] = "1"
        let result = try await fixture.runVerifier(
            scriptPath: scriptPath,
            stateFile: stateFile,
            environment: verifierEnvironment
        )

        #expect(result.exitCode == 1, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stderr.contains("non-granted result"))
    }

    private func debugStateFileBody(appPath: String) -> String {
        """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=debug-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=\(LauncherScriptFixture.currentProcessStartIdentity)
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=tcc-upgrade-probe
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(appPath))
        """
    }

    private func debugVerifierEnvironment(fixture: LauncherScriptFixture, app: URL) throws -> [String: String] {
        try commonVerifierEnvironment(fixture: fixture, app: app)
    }

    private func commonVerifierEnvironment(fixture: LauncherScriptFixture, app: URL) throws -> [String: String] {
        [
            "AGENTSTUDIO_CURL_BIN": try fixture.executable(
                "curl",
                """
                #!/bin/bash
                if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
                  printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
                  exit 0
                fi
                if [[ "$*" == *"terminal.tcc.access_probe"* && "$*" == *"denied_eacces"* ]]; then
                  exit 0
                fi
                if [[ "$*" == *"terminal.tcc.access_probe"* && "$*" == *"path_missing"* ]]; then
                  exit 0
                fi
                if [[ "$*" == *"terminal.tcc.access_probe"* && "$*" == *"timed_out"* ]]; then
                  exit 0
                fi
                if [[ "$*" == *"terminal.tcc.access_probe"* && "$*" == *"unknown_error"* ]]; then
                  exit 0
                fi
                if [[ "$*" == *"terminal.tcc.access_probe"* && "$*" == *"denied_eperm"* ]]; then
                  printf '{"_msg":"terminal.tcc.access_probe","agentstudio.tcc.phase":"startup_diagnostic","agentstudio.tcc.subject":"shell_child","agentstudio.tcc.access.target":"messages_data","agentstudio.tcc.access.result":"denied_eperm","agentstudio.tcc.responsible.kind":"agentstudio_debug","agentstudio.tcc.command.exit_class":"permission_denied","agentstudio.tcc.probe.sequence":1}\\n'
                  exit 0
                fi
                if [[ "$*" == *"terminal.tcc.access_probe"* ]]; then
                  printf '{"_msg":"terminal.tcc.access_probe","agentstudio.tcc.phase":"startup_diagnostic","agentstudio.tcc.subject":"shell_child","agentstudio.tcc.access.target":"messages_data","agentstudio.tcc.access.result":"granted","agentstudio.tcc.responsible.kind":"agentstudio_debug","agentstudio.tcc.command.exit_class":"ok","agentstudio.tcc.probe.sequence":0}\\n'
                  printf '{"_msg":"terminal.tcc.access_probe","agentstudio.tcc.phase":"startup_diagnostic","agentstudio.tcc.subject":"shell_child","agentstudio.tcc.access.target":"messages_data","agentstudio.tcc.access.result":"denied_eperm","agentstudio.tcc.responsible.kind":"agentstudio_debug","agentstudio.tcc.command.exit_class":"permission_denied","agentstudio.tcc.probe.sequence":1}\\n'
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
                echo "n\(app.path)/Contents/MacOS/AgentStudio"
                """
            ).path,
        ]
    }
}
