import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

extension SwiftLaneRunnerReportTests {
    @Test("fixture overrides survive inherited lane-state filtering", arguments: OuterStateFixtureLauncher.allCases)
    private func fixtureOverridesSurviveParentFiltering(launcher: OuterStateFixtureLauncher) async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-launcher-owned-values-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let overrides = [
            "BUILD_PATH": fixtureDirectory.appending(path: "build").path,
            "LANE_EVENT_STREAM_DIR": fixtureDirectory.appending(path: "events").path,
            "LANE_TIMES_FILE": fixtureDirectory.appending(path: "times").path,
            "SWIFT_BUILD_DIR": fixtureDirectory.appending(path: "build").path,
            "SWIFT_BUILD_STATS_DIR": fixtureDirectory.appending(path: "statistics").path,
            "SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH": fixtureDirectory.appending(path: "relay.lock").path,
            "SWIFT_TEST_ACTIVE_COMMAND_GROUPS_DIR": fixtureDirectory.appending(path: "groups").path,
            "AGENTSTUDIO_HELD_STEP_LOG": fixtureDirectory.appending(path: "held.jsonl").path,
        ]
        var parentEnvironment = swiftTaskFixtureEnvironment()
        for name in overrides.keys { parentEnvironment[name] = "/outer-lane/parent-value" }
        parentEnvironment["SWIFT_TEST_UNRECOGNIZED_PARENT_KEY"] = "must-be-stripped"
        parentEnvironment["FIXTURE_INHERITED_VALUE"] = "ordinary-parent-value"
        let result = try await launcher.run(
            #"""
            set -euo pipefail
            [ "${SWIFT_TEST_UNRECOGNIZED_PARENT_KEY+x}" != x ]
            [ "$FIXTURE_INHERITED_VALUE" = ordinary-parent-value ]
            for fixture_key in \#(overrides.keys.sorted().joined(separator: " ")); do
              printf '%s=%s\n' "$fixture_key" "${!fixture_key}"
            done
            """#, environment: overrides, inheritedEnvironment: parentEnvironment)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        for (name, value) in overrides {
            #expect(laneOutputLines(result.output).contains("\(name)=\(value)"))
        }
    }

    @Test(
        "shared test launchers isolate relay paths without dropping caller environment",
        arguments: OuterStateFixtureLauncher.allCases)
    private func sharedTestLaunchersIsolateRelayPaths(launcher: OuterStateFixtureLauncher) async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-launcher-relay-scope-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        var environment = swiftTaskFixtureEnvironment()
        environment["SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH"] = fixtureDirectory.appending(path: "parent.lock").path
        environment["SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH"] = "/parent/relay.pl"
        let helperPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "scripts/swift-test-helpers.sh").path
        let command = #"""
            [ "${SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH+x}" != x ] || { echo PARENT_LOCK_INHERITED; exit 61; }
            [ "${SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH+x}" != x ] || { echo PARENT_SCRIPT_INHERITED; exit 62; }
            [ "$FIXTURE_ENVIRONMENT_SENTINEL" = caller-value ] || exit 63
            source '\#(helperPath)'
            LOG_PREFIX=launcher-relay-scope
            BUILD_PATH='\#(fixtureDirectory.appending(path: "build").path)'
            swift_test_output_relay_prepare_paths
            printf 'LOCAL_LOCK=%s\n' "$SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH"
            """#
        let result = try await launcher.run(
            command, environment: ["FIXTURE_ENVIRONMENT_SENTINEL": "caller-value"], inheritedEnvironment: environment)
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
