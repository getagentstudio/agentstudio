import Foundation
import Testing

extension SwiftLaneReceiptTests {
    @Test(
        "every standalone task classifies reused bundle linkage at close",
        arguments: ["coverage", "e2e", "zmx-e2e", "benchmark"],
        ["valid", "binary", "head", "dirty"])
    func standaloneTaskReportsReuseValidity(taskName: String, scenario: String) async throws {
        let fixture = try SuiteMapProofFixture()
        defer { fixture.remove() }
        let configuration = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let task = try laneScriptNamedBlock(
            startingWith: "[tasks.\"test:swift:\(taskName)\"]", endingBefore: "\n[tasks.", in: configuration)
        let sourceMarker =
            taskName == "coverage"
            ? "source scripts/swift-test-helpers.sh\n" : "source \"${PROJECT_ROOT}/scripts/swift-test-helpers.sh\"\n"
        let bodyStart = try #require(task.range(of: sourceMarker))
        let body = String(task[bodyStart.upperBound...]).components(separatedBy: "\n\"\"\"")[0]
        let output = try await fixture.run(
            """
            SWIFT_BUILD_DIR="$BUILD_PATH"
            LOG_PREFIX=standalone; TIMEOUT_SECONDS=60; PREBUILD_TIMEOUT_SECONDS=60
            export SWIFT_TEST_INCLUDE_E2E=0
            prebuild_swift_tests_with_build_receipt || exit 1
            before_seal=$(swift_test_suite_map_digest "$BUILD_PATH/agentstudio-test-suite-map" "$BUILD_PATH/agentstudio-test-list")
            case '\(scenario)' in
              binary) printf '\\n# changed' >> '\(fixture.executable)' ;;
              head|dirty)
                if [ '\(scenario)' = head ]; then mutation='s/^head_sha=.*/head_sha=another-head/'; else mutation='s/^tree_dirty=.*/tree_dirty=true/'; fi
                sed "$mutation" "$(lane_build_receipt_path)" > "$BUILD_PATH/receipt.stage"
                mv "$BUILD_PATH/receipt.stage" "$(lane_build_receipt_path)"
                ;;
            esac
            swift_build_slot_release() { :; }
            swift_test_lane_mandatory_selectors() { printf '%s\\n' WebKitSerializedTests/BridgePaneControllerTests; }
            run_fast_non_webkit_swift_tests() { echo CHILD_PASSED; }
            run_large_non_webkit_swift_tests() { echo CHILD_PASSED; }
            run_webkit_suites() { echo CHILD_PASSED; }
            run_swift_with_timeout() {
              if [ "$1" = show-codecov-path ]; then : > "$CODECOV_TMPFILE"; else echo CHILD_PASSED; fi
            }
            export SWIFT_TEST_SKIP_PREBUILD=1
            (set -e; \(body))
            echo TASK_STATUS=$?
            after_seal=$(swift_test_suite_map_digest "$BUILD_PATH/agentstudio-test-suite-map" "$BUILD_PATH/agentstudio-test-list")
            [ "$before_seal" != "$after_seal" ] || echo SEAL_UNCHANGED
            """
        )
        #expect(output.contains("TASK_STATUS=0"), Comment(rawValue: output))
        #expect(output.contains("CHILD_PASSED"), Comment(rawValue: output))
        #expect(output.contains("SEAL_UNCHANGED"), Comment(rawValue: output))
        if scenario == "valid" {
            #expect(output.contains("receipt_valid=true"), Comment(rawValue: output))
            #expect(output.contains("verdict=pass"), Comment(rawValue: output))
        } else {
            let reason =
                scenario == "binary"
                ? "reused_bundle_unlinked"
                : scenario == "head" ? "bundle_head_mismatch" : "built_from_dirty_tree"
            #expect(output.contains("receipt_valid=false reason=\(reason)"), Comment(rawValue: output))
            #expect(output.contains("verdict=unverified"), Comment(rawValue: output))
        }
    }
}
