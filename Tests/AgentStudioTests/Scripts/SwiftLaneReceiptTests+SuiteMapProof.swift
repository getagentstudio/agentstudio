import AgentStudioInfrastructure
import Foundation
import Testing

extension SwiftLaneReceiptTests {
    @Test(
        "coverage publishes fresh metadata and rejects changed reused maps before dispatch",
        arguments: ["fresh", "map", "listing"])
    func coverageTaskChecksItsBuildContract(scenario: String) async throws {
        let fixture = try SuiteMapProofFixture()
        defer { fixture.remove() }
        let configuration = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let task = try laneScriptNamedBlock(
            startingWith: "[tasks.\"test:swift:coverage\"]", endingBefore: "\n[tasks.", in: configuration)
        let bodyStart = try #require(task.range(of: "source scripts/swift-test-helpers.sh\n"))
        let body = String(task[bodyStart.upperBound...]).components(separatedBy: "\n\"\"\"")[0]
        let reusedSetup =
            scenario == "fresh"
            ? ""
            : """
            prebuild_swift_tests_with_build_receipt || exit 1
            export SWIFT_TEST_SKIP_PREBUILD=1
            printf 'changed\\n' >> "$BUILD_PATH/agentstudio-test-\(scenario == "map" ? "suite-map" : "list")"
            """
        let output = try await fixture.run(
            """
            TIMEOUT_SECONDS=60; PREBUILD_TIMEOUT_SECONDS=1200
            EXTRA_SWIFT_TEST_ARGS=--enable-code-coverage
            swift_test_lane_mandatory_selectors() { printf '%s\\n' WebKitSerializedTests/BridgePaneControllerTests; }
            run_fast_non_webkit_swift_tests() {
              echo FAST_PHASE
              swift_test_bundle_for_suite WebKitSerializedTests/BridgePaneControllerTests || return 1
              [ "$(swift_test_invocation_expected_runs swift test)" = 2 ] || return 1
            }
            run_large_non_webkit_swift_tests() { echo LARGE_PHASE; }
            run_webkit_suites() { echo WEBKIT_PHASE; }
            run_swift_with_timeout() { : > "$CODECOV_TMPFILE"; }
            \(reusedSetup)
            (set -e; \(body))
            echo TASK_STATUS=$?
            """
        )
        if scenario == "fresh" {
            #expect(output.contains("TASK_STATUS=0"), Comment(rawValue: output))
            for phase in ["FAST_PHASE", "LARGE_PHASE", "WEBKIT_PHASE"] {
                #expect(output.contains(phase), Comment(rawValue: output))
            }
        } else {
            #expect(output.contains("TASK_STATUS=1"), Comment(rawValue: output))
            #expect(output.contains("reason=suite_map_unlinked"), Comment(rawValue: output))
            #expect(!output.contains("FAST_PHASE"), Comment(rawValue: output))
        }
        #expect(task.contains("EXTRA_SWIFT_TEST_ARGS=\"--enable-code-coverage\""))
        #expect(task.contains("SWIFT_TEST_TIMEOUT_SECONDS:-60"))
    }

    @Test("exact selectors, sealed maps, and bundle membership fail with named reasons")
    func suiteMapPreflightRejectsBrokenBuildContracts() async throws {
        let fixture = try SuiteMapProofFixture()
        defer { fixture.remove() }
        let output = try await fixture.run(
            """
            prebuild_swift_tests_with_build_receipt || exit 1
            selector=WebKitSerializedTests/BridgeTransportIntegrationTests/test_bridgeReady_gatesAndIsIdempotent
            echo "TEST_PATH=$(swift_test_bundle_for_suite "$selector")"
            swift_test_suite_map_preflight "$selector"; echo VALID=$?
            swift_test_suite_map_preflight WebKitSerializedTests/MissingChild; echo CHILD=$?
            cp "$BUILD_PATH/agentstudio-test-suite-map" "$BUILD_PATH/original-map"
            awk -F '\t' '$1 != "WebKitSerializedTests/BridgeTransportIntegrationTests"' "$BUILD_PATH/original-map" > "$BUILD_PATH/agentstudio-test-suite-map"
            swift_test_bundle_for_suite "$selector"; echo MISSING_CONTAINER=$?
            cp "$BUILD_PATH/original-map" "$BUILD_PATH/agentstudio-test-suite-map"
            printf 'WebKitSerializedTests/BridgePaneControllerTests\tOtherTests\n' >> "$BUILD_PATH/agentstudio-test-suite-map"
            seal_map
            swift_test_suite_map_preflight; echo DUPLICATE=$?
            cp "$BUILD_PATH/original-map" "$BUILD_PATH/agentstudio-test-suite-map"
            seal_map
            printf 'AgentStudioTests.AddedTests/test_added()\n' >> "$BUILD_PATH/agentstudio-test-list"
            swift_test_suite_map_preflight; echo LIST_MUTATION=$?
            cp "$FIXTURE_LIST" "$BUILD_PATH/agentstudio-test-list"
            printf 'AddedMapRow\tAgentStudioTests\n' >> "$BUILD_PATH/agentstudio-test-suite-map"
            swift_test_suite_map_preflight; echo MAP_MUTATION=$?
            cp "$BUILD_PATH/original-map" "$BUILD_PATH/agentstudio-test-suite-map"
            printf 'UnreceiptedTests\tUnreceiptedTarget\n' >> "$BUILD_PATH/agentstudio-test-suite-map"
            seal_map
            swift_test_suite_map_preflight; echo UNRECEIPTED=$?
            cp "$BUILD_PATH/original-map" "$BUILD_PATH/agentstudio-test-suite-map"
            seal_map
            chmod -x "$BUILD_PATH/out/Products/Debug/AgentStudioTests.xctest/Contents/MacOS/AgentStudioTests"
            swift_test_suite_map_preflight WebKitSerializedTests/BridgePaneControllerTests; echo MISSING_BUNDLE=$?
            cat "$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
            """
        )
        #expect(output.contains("TEST_PATH=\(fixture.executable)"), Comment(rawValue: output))
        for line in [
            "VALID=0", "CHILD=1", "MISSING_CONTAINER=1", "DUPLICATE=1", "LIST_MUTATION=1", "MAP_MUTATION=1",
            "UNRECEIPTED=1",
            "MISSING_BUNDLE=1",
        ] {
            #expect(output.contains(line), Comment(rawValue: output))
        }
        for reason in [
            "not_in_any_bundle", "duplicate_bundles=AgentStudioTests,OtherTests", "suite_map_unlinked",
            "bundle_missing=AgentStudioTests",
        ] {
            #expect(output.contains(reason), Comment(rawValue: output))
        }
        #expect(
            output.contains("WebKitSerializedTests/MissingChild\t1\tnone\tnot_in_any_bundle"), Comment(rawValue: output)
        )
        #expect(
            output.contains(
                "WebKitSerializedTests/BridgePaneControllerTests\t1\tnone\tduplicate_bundles=AgentStudioTests,OtherTests"
            ), Comment(rawValue: output))
    }

    @Test("prebuild invalidates failed builds and seals the complete artifact set atomically")
    func prebuildReceiptTracksWholeArtifactSet() async throws {
        let fixture = try SuiteMapProofFixture()
        defer { fixture.remove() }
        let output = try await fixture.run(
            """
            prebuild_swift_tests_with_build_receipt || exit 1
            receipt=$(lane_build_receipt_path)
            echo "COUNT=$(lane_build_receipt_field "$receipt" bundle_count)"
            echo "CLEAN=[$(lane_build_receipt_link_reason "$receipt" fixture-head "$(swift_test_bundle_set)")]"
            echo "HEAD=[$(lane_build_receipt_link_reason "$receipt" other-head "$(swift_test_bundle_set)")]"
            printf changed >> "$BUILD_PATH/out/Products/Debug/AgentStudioTests.xctest/Contents/MacOS/AgentStudioTests"
            echo "REBUILT=[$(lane_build_receipt_link_reason "$receipt" fixture-head "$(swift_test_bundle_set)")]"
            create_bundle AddedTests
            echo "ADDED=[$(lane_build_receipt_link_reason "$receipt" fixture-head "$(swift_test_bundle_set)")]"
            rm -f "$BUILD_PATH/out/Products/Debug/OtherTests.xctest/Contents/MacOS/OtherTests"
            echo "REMOVED=[$(lane_build_receipt_link_reason "$receipt" fixture-head "$(swift_test_bundle_set)")]"
            lane_receipt_tree_dirty() { echo true; }
            prebuild_swift_tests_with_build_receipt || exit 1
            echo "DIRTY=[$(lane_build_receipt_link_reason "$receipt" fixture-head "$(swift_test_bundle_set)")]"
            prebuild_swift_tests() { return 7; }
            prebuild_swift_tests_with_build_receipt; echo BUILD_FAILED=$?
            [ ! -e "$receipt" ] && echo NO_FAILED_RECEIPT
            [ ! -e "$BUILD_PATH/agentstudio-test-suite-map" ] && echo NO_FAILED_MAP
            prebuild_swift_tests() { create_bundle AgentStudioTests; }
            swift() { return 8; }
            prebuild_swift_tests_with_build_receipt; echo LIST_FAILED=$?
            [ ! -e "$receipt" ] && echo NO_LIST_RECEIPT
            """
        )
        for line in [
            "COUNT=2", "CLEAN=[]", "HEAD=[bundle_head_mismatch]", "REBUILT=[reused_bundle_unlinked]",
            "ADDED=[reused_bundle_unlinked]", "REMOVED=[reused_bundle_unlinked]", "DIRTY=[built_from_dirty_tree]",
            "BUILD_FAILED=7", "NO_FAILED_RECEIPT", "NO_FAILED_MAP", "NO_LIST_RECEIPT",
        ] {
            #expect(output.contains(line), Comment(rawValue: output))
        }
    }

    @Test("requested preflight executes under Bash 3.2 with an empty selector array")
    func requestedPreflightDoesNotAbortBeforeTests() async throws {
        let fixture = try SuiteMapProofFixture()
        defer { fixture.remove() }
        let runner = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let preflight = try laneScriptNamedBlock(
            startingWith: "mandatory_selectors=()", endingBefore: "\nif [ \"$#\" -gt 0 ]; then", in: runner)
        let output = try await fixture.run(
            "prebuild_swift_tests_with_build_receipt || exit 1\n"
                + "mode=test; set -- --filter SwiftLaneReceiptTests; set -u\n"
                + preflight + "\necho REQUESTED_PREFLIGHT_FINISHED\n")
        #expect(output.contains("REQUESTED_PREFLIGHT_FINISHED"), Comment(rawValue: output))
        #expect(!output.contains("unbound variable"), Comment(rawValue: output))
    }

    @Test("direct helper launch preserves toolchain paths with spaces")
    func helperEnvironmentPreservesToolchainPaths() async throws {
        let fixture = try SuiteMapProofFixture()
        defer { fixture.remove() }
        let output = try await fixture.run(
            """
            prebuild_swift_tests_with_build_receipt || exit 1
            framework="$BUILD_PATH/Xcode With Spaces.platform/Developer/Library/Frameworks"
            printf '#!%s\nimport os\nprint("FRAMEWORK=" + os.environ["DYLD_FRAMEWORK_PATH"])\nprint("LIBRARY=" + os.environ["DYLD_LIBRARY_PATH"])\n' "$(command -v python3)" > "$BUILD_PATH/print-helper"
            chmod +x "$BUILD_PATH/print-helper"
            swift_testing_helper_path() { echo "$BUILD_PATH/print-helper"; }
            swift_testing_framework_path() { echo "$framework"; }
            run_swift_with_timeout() { shift 2; "$@"; }
            TIMEOUT_SECONDS=60
            run_selected_isolated_suite fast WebKitSerializedTests/BridgePaneControllerTests
            """
        )
        #expect(
            output.contains("FRAMEWORK=\(fixture.root)/Xcode With Spaces.platform/Developer/Library/Frameworks"),
            Comment(rawValue: output))
        #expect(
            output.contains("LIBRARY=\(fixture.root)/Xcode With Spaces.platform/Developer/usr/lib"),
            Comment(rawValue: output))
    }

    @Test("retention cannot turn build and list commands into event-stream invocations")
    func commandKindsUseReceiptCountAndPreserveBuildExitStatus() async throws {
        let fixture = try SuiteMapProofFixture()
        defer { fixture.remove() }
        let output = try await fixture.run(
            """
            prebuild_swift_tests_with_build_receipt || exit 1
            export LANE_EVENT_STREAM_RETAIN_ALWAYS=1
            swift_test_command_accepts_event_stream swift build --build-tests; echo BUILD_STREAM=$?
            swift_test_command_accepts_event_stream swift test list --skip-build; echo LIST_STREAM=$?
            swift_test_command_accepts_event_stream swift test --skip-build; echo TEST_STREAM=$?
            swift_test_command_accepts_event_stream swift test --filter list; echo LIST_FILTER_STREAM=$?
            swift_test_command_accepts_event_stream swift test --filter build; echo BUILD_FILTER_STREAM=$?
            echo "SWIFTPM_RUNS=$(swift_test_invocation_expected_runs swift test --skip-build)"
            echo "DIRECT_RUNS=$(swift_test_invocation_expected_runs /tool/swiftpm-testing-helper)"
            """
        )
        for line in [
            "BUILD_STREAM=1", "LIST_STREAM=1", "TEST_STREAM=0", "LIST_FILTER_STREAM=0", "BUILD_FILTER_STREAM=0",
            "SWIFTPM_RUNS=2", "DIRECT_RUNS=1",
        ] {
            #expect(output.contains(line), Comment(rawValue: output))
        }
    }
}

private struct SuiteMapProofFixture {
    let root: String
    var executable: String { root + "/out/Products/Debug/AgentStudioTests.xctest/Contents/MacOS/AgentStudioTests" }

    init() throws {
        root = NSTemporaryDirectory() + "suite-map-proof-\(UUIDv7.generate())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    func run(_ commands: String) async throws -> String {
        try await laneBashAllowingFailure(
            """
            source scripts/swift-test-helpers.sh
            BUILD_PATH='\(root)'
            FIXTURE_LIST="$PWD/Tests/AgentStudioTests/Scripts/Fixtures/xcode27-swift-test-list.txt"
            SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE="$BUILD_PATH/failed-suites"
            create_bundle() {
              mkdir -p "$BUILD_PATH/out/Products/Debug/$1.xctest/Contents/MacOS"
              printf '#!/bin/bash\\nexit 0\\n' > "$BUILD_PATH/out/Products/Debug/$1.xctest/Contents/MacOS/$1"
              chmod +x "$BUILD_PATH/out/Products/Debug/$1.xctest/Contents/MacOS/$1"
            }
            prebuild_swift_tests() {
              [ ! -e "$(lane_build_receipt_path)" ] || return 9
              [ ! -e "$BUILD_PATH/agentstudio-test-suite-map" ] || return 9
              create_bundle AgentStudioTests
              create_bundle OtherTests
            }
            swift() {
              [ ! -e "$(lane_build_receipt_path)" ] || return 9
              cat "$FIXTURE_LIST"
            }
            lane_receipt_head_sha() { echo fixture-head; }
            lane_receipt_tree_dirty() { echo false; }
            seal_map() {
              receipt=$(lane_build_receipt_path)
              sed '/^suite_map_digest=/d' "$receipt" > "$receipt.stage"
              printf 'suite_map_digest=%s\\n' "$(swift_test_suite_map_digest "$BUILD_PATH/agentstudio-test-suite-map" "$BUILD_PATH/agentstudio-test-list")" >> "$receipt.stage"
              mv "$receipt.stage" "$receipt"
            }
            set +e
            \(commands)
            """
        )
    }
}
