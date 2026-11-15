import Foundation
import Testing

extension ObservabilityDebugLaunchScriptsTests {
    @Test("a foreign responsive escrow cannot certify this launch", arguments: [false, true])
    func debugLauncherRequiresMatchingEscrowEndpoint(replaceWithMatchingEscrow: Bool) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let stateFile = fixture.url("latest.env")
        let matchingEscrow = try fixture.makeDebugEscrow(name: "matching-escrow.json")
        let escrow = try fixture.makeDebugEscrow(
            name: "caller-owned-escrow.json", socketPath: fixture.url("another-debug-app/agentstudio.sock").path
        )
        let originalEscrow = try Data(contentsOf: escrow)
        let healthCalls = fixture.url("endpoint-health-calls")
        let clockCount = fixture.url("endpoint-clock-count")
        let buildPath = try fixture.makeDebugBuildExecutable("#!/bin/bash\nexit 0\n")
        let cli = try fixture.makeDebugBuildCLI(
            """
            #!/bin/bash
            set -eu
            [ "$*" = system.ping ] || exit 71
            [ "${AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW:-}" = '\(escrow.path)' ] || exit 72
            if /usr/bin/cmp -s "$AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW" '\(matchingEscrow.path)'; then
              echo expected >> '\(healthCalls.path)'
            else
              echo foreign >> '\(healthCalls.path)'
            fi
            exit 0
            """
        )
        // Control: the foreign endpoint responds. Readiness must still reject its identity.
        let control = try await fixture.runScript(
            cli.path, arguments: ["system.ping"],
            environment: ["AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW": escrow.path]
        )
        try #require(control.exitCode == 0)
        #expect(try String(contentsOf: healthCalls, encoding: .utf8) == "foreign\n")
        var environment = try launchServicesDiagnosticEnvironment(
            fixture: fixture, openArgsURL: fixture.url("open-args"),
            launchedAppURL: fixture.url("launched-app"), stateFile: stateFile
        )
        environment["AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW"] = escrow.path
        environment["AGENTSTUDIO_PID_WAIT_ATTEMPTS"] = "100"
        environment["AGENTSTUDIO_OBSERVABILITY_TEST_LAUNCH_CLOCK_BIN"] = try fixture.executable(
            "endpoint-clock",
            """
            #!/bin/bash
            set -eu
            count=0
            [ ! -f '\(clockCount.path)' ] || count=$(cat '\(clockCount.path)')
            count=$((count + 1))
            printf '%s' "$count" > '\(clockCount.path)'
            if [ "$count" -eq 4 ] && [ '\(replaceWithMatchingEscrow ? "yes" : "no")' = yes ]; then
              cp '\(matchingEscrow.path)' '\(escrow.path)'
            fi
            printf '%s' "$count"
            """
        ).path

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--build-path", buildPath.path, "--skip-build", "--detach"], environment: environment
        )

        #expect(
            result.exitCode == (replaceWithMatchingEscrow ? 0 : 1), "stdout: \(result.stdout)\nstderr: \(result.stderr)"
        )
        let calls = try String(contentsOf: healthCalls, encoding: .utf8)
        #expect(calls == (replaceWithMatchingEscrow ? "foreign\nexpected\n" : "foreign\n"))
        let state = try String(contentsOf: stateFile, encoding: .utf8)
        #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running") == replaceWithMatchingEscrow)
        if replaceWithMatchingEscrow {
            #expect(try Data(contentsOf: escrow) == Data(contentsOf: matchingEscrow))
        } else {
            #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_REASON=ipc_health_timeout"))
            #expect(try Data(contentsOf: escrow) == originalEscrow)
        }
    }
}
