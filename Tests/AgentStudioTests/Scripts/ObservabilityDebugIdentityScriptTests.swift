import Darwin
import Foundation
import Testing

@Suite("Shared debug bundle identity")
struct ObservabilityDebugIdentityScriptTests {
    @Test("a shared bundle ID permits another code but refuses the same code", arguments: [false, true])
    func preflightDistinguishesCodes(sameCode: Bool) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let expectedCode = try await fixture.worktreeDebugCode()
        let otherCode = expectedCode == "othr" ? "diff" : "othr"
        let code = sameCode ? expectedCode : otherCode
        let app = try fixture.makeAppBundle(
            name: "external/AgentStudio Debug \(code).app", releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug", debugCode: code)
        let pgrep = try fixture.executable("pgrep", "#!/bin/bash\necho 4242\n")
        let lsof = try fixture.executable(
            "lsof", "#!/bin/bash\nprintf 'n%s/Contents/MacOS/AgentStudio\\n' '\(app.path)'\n")

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh", arguments: ["--preflight-idle"],
            environment: ["AGENTSTUDIO_PGREP_BIN": pgrep.path, "AGENTSTUDIO_LSOF_BIN": lsof.path])

        #expect(result.exitCode == (sameCode ? 1 : 0), "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stderr.contains("already running") == sameCode)
    }

    @Test(
        "the live verifier rejects a shared-ID process with another code, root or start",
        arguments: ["valid", "code", "root", "start"])
    func verifierBindsExactIncarnation(mismatch: String) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let app = try fixture.makeAppBundle(
            name: "AgentStudio Debug t3st.app", releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug", debugCode: mismatch == "code" ? "othr" : "t3st")
        let stateApp = mismatch == "root" ? fixture.url("other/AgentStudio Debug t3st.app") : app
        let state = fixture.url("latest.env")
        let start = mismatch == "start" ? "stale-start" : LauncherScriptFixture.currentProcessStartIdentity
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=debug-marker
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=t3st
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=\(start)
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(stateApp.path))
        """.write(to: state, atomically: true, encoding: .utf8)
        let lsof = try fixture.executable(
            "lsof", "#!/bin/bash\nprintf 'n%s/Contents/MacOS/AgentStudio\\n' '\(app.path)'\n")
        // Stop immediately after the real admission function. No telemetry collector is involved.
        let source = try String(contentsOfFile: "scripts/verify-debug-observability.sh", encoding: .utf8)
        let admissionEnd = try #require(source.range(of: "\nallow_completed_diagnostic_exit=false"))
        let script = try fixture.executable(
            "verifier-admission", String(source[..<admissionEnd.lowerBound]) + "\nrequire_live_debug_process\n")
        // The script's root resolver must still resolve the real shared helper.
        let patched = try String(contentsOf: script, encoding: .utf8)
            .replacingOccurrences(
                of: "PROJECT_ROOT=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")/..\" && pwd)\"",
                with: "PROJECT_ROOT='\(FileManager.default.currentDirectoryPath)'")
        try patched.write(to: script, atomically: true, encoding: .utf8)

        let result = try await fixture.runVerifier(
            scriptPath: script.path, stateFile: state, environment: ["AGENTSTUDIO_LSOF_BIN": lsof.path])

        #expect(result.exitCode == (mismatch == "valid" ? 0 : 1), "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stderr.contains("bundle identity mismatch") == (mismatch != "valid"))
    }

    @Test("bundle assembly writes shared identity, signed code and unchanged code names")
    func assembledBundleCarriesCode() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let code = try await fixture.worktreeDebugCode()
        let build = try fixture.makeDebugBuildExecutable("#!/bin/bash\nexit 0\n")
        let environment = try launchServicesDiagnosticEnvironment(
            fixture: fixture, openArgsURL: fixture.url("open-args"),
            launchedAppURL: fixture.url("launched-app"), stateFile: fixture.url("state.env"))

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh", arguments: ["--build-path", build.path, "--skip-build", "--detach"],
            environment: environment)

        try #require(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let plistData = try Data(
            contentsOf: fixture.url("debug-app-artifacts/AgentStudio Debug \(code).app/Contents/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == "com.agentstudio.app.debug")
        #expect(plist["AgentStudioDebugCode"] as? String == code)
        #expect(plist["CFBundleName"] as? String == "AgentStudio Debug \(code)")
        #expect(plist["CFBundleDisplayName"] as? String == "Agent Studio Debug \(code)")
        let arguments = try String(contentsOf: fixture.url("open-args"), encoding: .utf8).split(separator: "\n")
        #expect(arguments.contains("-g"))
        #expect(arguments.contains("-n"))
    }
}
