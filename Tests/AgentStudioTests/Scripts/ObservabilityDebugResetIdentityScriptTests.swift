import Foundation
import Testing

@Suite("Debug workload reset identity")
struct ObservabilityDebugResetIdentityScriptTests {
    @Test(
        "each reset rejects a foreign code or data root under the shared bundle ID",
        arguments: ["startup", "sidebar", "title"], ["valid", "code", "root"])
    func resetAdmissionBindsCodeAndRoot(workload: String, mismatch: String) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let root = FileManager.default.currentDirectoryPath
        let scriptPath = "scripts/verify-\(workload == "title" ? "title-pane" : workload)-performance-workload.sh"
        let source = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let app = try fixture.makeAppBundle(
            name: "apps/AgentStudio Debug t3st.app", releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug", debugCode: mismatch == "code" ? "othr" : "t3st")
        let expectedData = fixture.url(workload == "sidebar" ? "proof/data" : ".agentstudio-db/t3st")
        let data = mismatch == "root" ? fixture.url(".agentstudio-db/othr") : expectedData
        let identity = """
            AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=t3st
            AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER=com.agentstudio.app.debug
            AGENTSTUDIO_OBSERVABILITY_DATA_DIR=\(shellEscapedStateValue(data.path))
            AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(app.path))
            AGENTSTUDIO_OBSERVABILITY_EXECUTABLE=\(shellEscapedStateValue(app.appending(path: "Contents/MacOS/AgentStudio").path))
            """
        try FileManager.default.createDirectory(at: fixture.url("scripts"), withIntermediateDirectories: false)
        let runner = try fixture.executable(
            "scripts/run-debug-observability.sh", "#!/bin/bash\nprintf '%s\\n' \"$TEST_IDENTITY\"\n")
        let parts = try admissionParts(workload: workload, source: source)
        // Run the real reset admission, stopping before its live preflight and destructive phase.
        let script = try fixture.executable(
            "reset-admission",
            """
            #!/bin/bash
            set -euo pipefail
            source '\(root)/scripts/debug-app-identity.sh'
            \(parts.helpers)
            \(parts.admission)
            \(workload == "startup" ? "validate_isolated_debug_root \"$TEST_IDENTITY\"" : "reset_disposable_debug_root")
            """)

        let result = try await fixture.runScript(
            script.path, arguments: [],
            environment: [
                "PROJECT_ROOT": fixture.root.path,
                "DEBUG_RUNNER": runner.path,
                "STRICT_DISPOSABLE_DATA_ROOT": expectedData.path,
                "ARTIFACT": fixture.url("proof").path,
                "TEST_IDENTITY": identity,
            ])

        #expect(result.exitCode == (mismatch == "valid" ? 0 : 1), "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stderr.contains("refusing") == (mismatch != "valid"), "stderr: \(result.stderr)")
    }

    private func admissionParts(workload: String, source: String) throws -> (helpers: String, admission: String) {
        if workload == "startup" {
            return (
                try section(source, from: "decode_assignment() {", to: "state_value() {"),
                try section(source, from: "validate_isolated_debug_root() {", to: "write_restored_fixture_json() {")
            )
        }
        let helpers = try section(
            source,
            from: workload == "sidebar" ? "canonical_path() {" : "decode_identity() {",
            to: workload == "sidebar" ? "stop_pid() {" : "reset_disposable_debug_root() {")
        let admission = try section(
            source, from: "reset_disposable_debug_root() {",
            to: workload == "sidebar"
                ? "  if ! AGENTSTUDIO_DEBUG_DATA_DIR=\"$STRICT_DISPOSABLE_DATA_ROOT\""
                : "  \"$PROJECT_ROOT/scripts/run-debug-observability.sh\" --preflight-idle")
        return (helpers, admission + "\n  return 0\n}\n")
    }

    private func section(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try #require(source.range(of: start))
        let upper = try #require(source.range(of: end, range: lower.upperBound..<source.endIndex))
        return String(source[lower.lowerBound..<upper.lowerBound])
    }
}
