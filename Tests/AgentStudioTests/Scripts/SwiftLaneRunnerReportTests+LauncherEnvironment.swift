import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

private enum RelayFixtureLauncher: String, CaseIterable, Sendable {
    case laneScript
    case subprocess
    case command
}

extension SwiftLaneRunnerReportTests {
    @Test(
        "shared test launchers isolate relay paths without dropping caller environment",
        arguments: RelayFixtureLauncher.allCases)
    private func sharedTestLaunchersIsolateRelayPaths(launcher: RelayFixtureLauncher) async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-launcher-relay-scope-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        var environment = swiftTaskFixtureEnvironment()
        environment["SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH"] = fixtureDirectory.appending(path: "parent.lock").path
        environment["SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH"] = "/parent/relay.pl"
        environment["FIXTURE_ENVIRONMENT_SENTINEL"] = "caller-value"
        let command = #"""
            [ "${SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH+x}" != x ] || { echo PARENT_LOCK_INHERITED; exit 61; }
            [ "${SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH+x}" != x ] || { echo PARENT_SCRIPT_INHERITED; exit 62; }
            [ "$FIXTURE_ENVIRONMENT_SENTINEL" = caller-value ] || exit 63
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=launcher-relay-scope
            BUILD_PATH='\#(fixtureDirectory.appending(path: "build").path)'
            swift_test_output_relay_prepare_paths
            printf 'LOCAL_LOCK=%s\n' "$SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH"
            """#
        let result: LaneScriptBashResult
        switch launcher {
        case .laneScript:
            result = try await runLaneScriptBash(command, environment: environment)
        case .subprocess:
            let output = try await runProcessToExit(
                executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", command], environment: environment)
            let standardOutput = try #require(String(bytes: output.standardOutput, encoding: .utf8))
            let standardError = try #require(String(bytes: output.standardError, encoding: .utf8))
            result = LaneScriptBashResult(exitCode: output.terminationStatus, output: standardOutput + standardError)
        case .command:
            let output = try await runCommandToExit(
                command: "/bin/bash", arguments: ["-c", command], environment: environment)
            result = LaneScriptBashResult(exitCode: Int32(output.exitCode), output: output.stdout + output.stderr)
        }
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        // realpath(3), like the script's `pwd -P`; resolvingSymlinksInPath strips /private from /private/var.
        let buildDirectory = try #require(realpath(fixtureDirectory.appending(path: "build").path, nil))
        defer { free(buildDirectory) }
        let expectedLock = String(cString: buildDirectory) + "/.swift-test-output.lock"
        #expect(result.output.contains("LOCAL_LOCK=\(expectedLock)"))
        #expect(!result.output.contains("PARENT_LOCK_INHERITED"))
        #expect(!result.output.contains("PARENT_SCRIPT_INHERITED"))
    }
}
