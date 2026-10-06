import AgentStudioInfrastructure
import Foundation
import Testing

extension SwiftLaneReceiptTests {
    @Test(
        "standalone tasks enforce mandatory suites and facts before accepting a child",
        arguments: ["e2e", "zmx-e2e", "benchmark"],
        ["pass", "no-match", "missing-suite", "incomplete", "unreadable", "failure"])
    func standaloneTasksEnforceInvocationFacts(lane: String, scenario: String) async throws {
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        let configuration = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let task = try laneScriptNamedBlock(
            startingWith: "[tasks.\"test:swift:\(lane)\"]", endingBefore: "\n[tasks.", in: configuration)
        let bodyStart = try #require(task.range(of: "BUILD_PATH=\"$SWIFT_BUILD_DIR\"\n"))
        let body = String(task[bodyStart.upperBound...]).components(separatedBy: "\n\"\"\"")[0]
        let inventoryLane = lane == "zmx-e2e" ? "zmx" : lane
        let inventory = try await laneBash(
            "source scripts/swift-test-helpers.sh; swift_test_lane_suite_types '\(inventoryLane)'",
            environment: swiftTaskFixtureEnvironment())
        let selectors = laneOutputLines(inventory)
        let missingSelector = try #require(selectors.last)
        let listedSelectors = scenario == "missing-suite" ? selectors.dropLast() : selectors[...]
        let listingRows =
            listedSelectors.map { "AgentStudioTests.\($0)/fixture()" }
            + ["AgentStudioTests.UnrelatedFixtureTests/fixture()"]
        try listingRows.joined(separator: "\n")
            .write(to: fixture.root.appending(path: "listing"), atomically: true, encoding: .utf8)
        if scenario == "no-match" {
            try fixture.writeEvents([
                ["kind": "event", "payload": ["kind": "runStarted"]],
                ["kind": "event", "payload": ["kind": "runEnded"]],
            ])
        } else {
            try writeCapturedInvocation(
                fixture, selecting: scenario == "failure" ? "recordsFailure()" : "recordsPass()",
                closingRun: scenario != "incomplete")
        }
        if scenario == "unreadable" {
            let handle = try FileHandle(forWritingTo: fixture.events)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("invalid-record\n".utf8))
            try handle.close()
        }
        let toolDirectory = fixture.root.appending(path: "tools")
        try writeStandaloneTaskSwiftTool(in: toolDirectory)

        let result = try await runLaneScriptBash(
            """
            \(swiftTaskParentEnvironmentProbe)
            source scripts/swift-test-helpers.sh
            BUILD_PATH='\(fixture.root.path)'; SWIFT_BUILD_DIR="$BUILD_PATH"
            LOG_PREFIX=standalone; TIMEOUT_SECONDS=60; PREBUILD_TIMEOUT_SECONDS=60
            export PATH='\(toolDirectory.path)':"$PATH"
            export LANE_TASK_FIXTURE_ROOT="$BUILD_PATH"
            export LANE_EVENT_STREAM_DIR="$BUILD_PATH/evidence"
            export SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE="$BUILD_PATH/parent-failed-suites"
            \(lane == "benchmark" ? "export AGENT_STUDIO_BENCHMARK_MODE=benchmark" : "")
            (
              export SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE="$BUILD_PATH/failed-suites"
              export SWIFT_TEST_PEAK_ANNOUNCED_FILE="$BUILD_PATH/announced-peaks"
              export SWIFT_TEST_PEAK_RUNNING_FILE="$BUILD_PATH/running-peaks"
              export SWIFT_TEST_SKIP_PREBUILD=0
              set -e
              \(body)
            )
            task_status=$?
            if [ -e "$BUILD_PATH/parent-failed-suites" ]; then
              echo PARENT_LEDGER_MODIFIED
              exit 99
            fi
            exit "$task_status"
            """, environment: swiftTaskFixtureEnvironment()
        )
        #expect(result.exitCode == (scenario == "pass" ? 0 : 1), Comment(rawValue: result.output))
        #expect(!result.output.contains("PARENT_ENV_INHERITED="), Comment(rawValue: result.output))
        #expect(!result.output.contains("PARENT_LEDGER_MODIFIED"), Comment(rawValue: result.output))
        if scenario == "missing-suite" {
            #expect(
                result.output.contains("selector=\(missingSelector) reason=not_in_any_bundle"),
                Comment(rawValue: result.output))
            #expect(!result.output.contains("CHILD_INVOKED"), Comment(rawValue: result.output))
        } else {
            #expect(result.output.contains("--event-stream-version 6.3"), Comment(rawValue: result.output))
            #expect(
                result.output.contains("MODE=\(lane == "benchmark" ? "benchmark" : "off")"),
                Comment(rawValue: result.output))
        }
        switch scenario {
        case "no-match":
            #expect(result.output.contains("reason=no_matching_tests"), Comment(rawValue: result.output))
        case "incomplete":
            #expect(result.output.contains("stream=truncated"), Comment(rawValue: result.output))
        case "unreadable":
            #expect(result.output.contains("stream=unreadable"), Comment(rawValue: result.output))
        case "failure":
            #expect(
                result.output.contains(
                    "failing_test=AgentStudioTests.Xcode27EventStreamEvidenceScratchTests/recordsFailure()"),
                Comment(rawValue: result.output))
        default:
            break
        }
    }
}

private func writeStandaloneTaskSwiftTool(in toolDirectory: URL) throws {
    try FileManager.default.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
    let swiftTool = toolDirectory.appending(path: "swift")
    try """
    #!/bin/bash
    set -eu
    if [ "$1" = build ]; then
      bundle="$LANE_TASK_FIXTURE_ROOT/out/Products/Debug/AgentStudioTests.xctest/Contents/MacOS"
      mkdir -p "$bundle"
      printf '#!/bin/bash\\nexit 0\\n' > "$bundle/AgentStudioTests"
      chmod +x "$bundle/AgentStudioTests"
      exit 0
    fi
    if [ "$1" = test ] && [ "$2" = list ]; then
      cat "$LANE_TASK_FIXTURE_ROOT/listing"
      exit 0
    fi
    echo CHILD_INVOKED
    echo "MODE=${AGENT_STUDIO_BENCHMARK_MODE:-unset}"
    echo "CHILD_ARGS=$*"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --event-stream-output-path ]; then
        cp "$LANE_TASK_FIXTURE_ROOT/fixture.events" "$2"
        break
      fi
      shift
    done
    exit 0
    """.write(to: swiftTool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftTool.path)
}
