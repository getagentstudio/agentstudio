import Darwin
import Foundation
import Testing

@Suite
struct OTLPVerifierRecordedFieldScriptTests {
    struct ExposureCase: Sendable {
        enum Channel: String, Sendable {
            case debug
            case beta
        }
        enum Field: String, Sendable {
            case identity = "agentstudio.workspace.id"
            case path = "agentstudio.tcc.raw.probe_path"
            case secret
            case token
        }
        let channel: Channel
        let field: Field
        var expectedExit: Int32 { field == .secret || field == .token ? 1 : 0 }
        static let all: [Self] = [Channel.debug, .beta].flatMap { channel in
            [Field.identity, .path, .secret, .token].map { Self(channel: channel, field: $0) }
        }
    }

    @Test(arguments: ExposureCase.all)
    func verifierAcceptsRecordedIdentityAndPathButStillRejectsSecrets(exposure: ExposureCase) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let isDebug = exposure.channel == .debug
        let app = try fixture.makeAppBundle(
            name: isDebug ? "Agent Studio Debug testcode.app" : "AgentStudioBeta.app",
            releaseChannel: isDebug ? "stable" : "beta",
            bundleIdentifier: isDebug ? "com.agentstudio.app.debug.dtestcode" : "com.agentstudio.app.beta"
        )
        let version = isDebug ? "0.0.1-debug+testcode" : "0.0.54-beta.99"
        let flavor = isDebug ? "debug" : "release"
        let state = fixture.url("latest.env")
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_MARKER=recorded-field-proof
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
        AGENTSTUDIO_OBSERVABILITY_SERVICE_VERSION=\(version)
        AGENTSTUDIO_OBSERVABILITY_PID=\(getpid())
        AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-06-12T00:00:00Z
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(app.path))
        """.appending("\n").write(to: state, atomically: true, encoding: .utf8)
        let curl = try fixture.executable(
            "curl-recorded-fields",
            """
            #!/bin/bash
            if [[ "$*" == *" \(exposure.field.rawValue):*"* ]]; then
              printf '{"\(exposure.field.rawValue)":"fixture-value"}\\n'
              exit 0
            fi
            if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
              printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
              exit 0
            fi
            if [[ "$*" == *":*"* ]]; then exit 0; fi
            printf '{"service.name":"AgentStudio","service.version":"\(version)","dev.release.channel":"beta","dev.runtime.flavor":"\(flavor)","_msg":"app.process.start","\(exposure.field.rawValue)":"fixture-value"}\\n'
            """
        )
        let result = try await fixture.runVerifier(
            scriptPath: "scripts/verify-\(exposure.channel.rawValue)-observability.sh",
            stateFile: state,
            environment: [
                "AGENTSTUDIO_EXPECTED_BETA_APP": app.path,
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_ATTEMPTS": "1",
                "AGENTSTUDIO_OBSERVABILITY_VERIFY_RETRY_DELAY_SECONDS": "0",
                "AGENTSTUDIO_CURL_BIN": curl.path,
                "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
                    "lsof", "#!/bin/bash\necho 'n\(app.path)/Contents/MacOS/AgentStudio'\n"
                ).path,
            ]
        )
        #expect(result.exitCode == exposure.expectedExit, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        if exposure.expectedExit == 1 {
            #expect(result.stderr.contains("sensitive field survived"))
            #expect(result.stderr.contains(exposure.field.rawValue))
        }
    }

    @Test
    func sidebarEscrowAlreadyPresentCompletesWithoutWaiting() async throws {
        let source = try String(contentsOfFile: "scripts/verify-sidebar-performance-workload.sh", encoding: .utf8)
        let functionStart = source.range(of: "wait_for_debug_ipc_escrow() {")
        let start = try #require(functionStart, "Missing sidebar IPC escrow readiness helper")
        let functionEnd = source.range(of: "\n}", range: start.upperBound..<source.endIndex)
        let end = try #require(functionEnd, "Missing escrow readiness helper closing brace")
        let function = String(source[start.lowerBound..<end.upperBound])
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let escrow = fixture.url("escrow.json")
        try "fixture".write(to: escrow, atomically: true, encoding: .utf8)
        let script = try fixture.executable(
            "escrow-present.sh", "#!/bin/bash\nset -euo pipefail\n\(function)\nwait_for_debug_ipc_escrow\n"
        )
        let result = try await fixture.runScript(
            script.path, arguments: [],
            environment: ["IPC_DEBUG_ESCROW_PATH": escrow.path, "APP_PID": "999999999"]
        )
        #expect(result.exitCode == 0, "\(result.stderr)")
    }
}
