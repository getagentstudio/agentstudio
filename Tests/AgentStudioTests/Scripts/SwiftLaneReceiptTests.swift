import AgentStudioInfrastructure
import Foundation
import Testing

@Suite("Swift lane receipts and hang evidence")
struct SwiftLaneReceiptTests {
    @Test("real Xcode 27 listing produces nested suite map and resolves the test bundle")
    func realListingProducesNestedSuiteMapAndResolvesBundle() async throws {
        let buildDirectory = NSTemporaryDirectory() + "agentstudio-suite-map-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: buildDirectory) }
        let listing =
            FileManager.default.currentDirectoryPath
            + "/Tests/AgentStudioTests/Scripts/Fixtures/xcode27-swift-test-list.txt"
        let map = buildDirectory + "/agentstudio-test-suite-map"
        let executable = buildDirectory + "/out/Products/Debug/AgentStudioTests.xctest/Contents/MacOS/AgentStudioTests"

        let output = try await laneBashAllowingFailure(
            "source scripts/swift-test-helpers.sh; BUILD_PATH='\(buildDirectory)'; "
                + "mkdir -p \"$(dirname '\(executable)')\"; : > '\(executable)'; chmod +x '\(executable)'; "
                + "cp '\(listing)' \"$BUILD_PATH/agentstudio-test-list\"; "
                + "swift_test_suite_map_build_from_listing \"$BUILD_PATH/agentstudio-test-list\" '\(map)'; "
                + "echo MAP; cat '\(map)'; "
                + "echo RESOLVED=$(swift_test_bundle_for_suite 'WebKitSerializedTests/BridgePaneControllerTests' 2>/dev/null || true)"
        )

        #expect(
            output.contains("WebKitSerializedTests/BridgePaneControllerTests\tAgentStudioTests"),
            Comment(rawValue: output))
        #expect(
            output.contains("RESOLVED=\(executable)"), Comment(rawValue: output))
    }

    @Test("a receipt is valid only for a fresh or linked bundle and a clean tree")
    func receiptIsValidOnlyForFreshOrLinkedBundleAndCleanTree() async throws {
        let reasons = try await laneBash(
            "source scripts/swift-test-helpers.sh; "
                + "for case in 'fresh false -' 'reused false -' 'reused false reused_bundle_unlinked' "
                + "'not_built false -' 'fresh true -' 'reused true built_from_dirty_tree' 'fresh unknown -'; do "
                + "set -- $case; link=$3; [ \"$link\" = - ] && link=''; "
                + "echo \"$1/$2/$3=[$(lane_receipt_invalid_reasons \"$1\" \"$2\" \"$link\")]\"; done"
        )

        #expect(
            laneOutputLines(reasons) == [
                "fresh/false/-=[]",
                // A reused bundle linked to a clean build of this commit is evidence.
                "reused/false/-=[]",
                "reused/false/reused_bundle_unlinked=[reused_bundle_unlinked]",
                "not_built/false/-=[unbuilt_bundle]",
                "fresh/true/-=[dirty_tree]",
                "reused/true/built_from_dirty_tree=[built_from_dirty_tree,dirty_tree]",
                "fresh/unknown/-=[unknown_tree]",
            ]
        )
    }

    @Test("only a valid receipt carries a verdict, and an invalid one is never a pass")
    func onlyValidReceiptCarriesVerdict() async throws {
        let validPass = try await laneBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; print_lane_receipt_verdict 0 fresh false"
        )
        let validFail = try await laneBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; print_lane_receipt_verdict 1 fresh false"
        )
        let unlinkedPass = try await laneBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; "
                + "print_lane_receipt_verdict 0 reused false reused_bundle_unlinked"
        )
        let linkedPass = try await laneBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; print_lane_receipt_verdict 0 reused false ''"
        )
        let dirtyPass = try await laneBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; print_lane_receipt_verdict 0 fresh true"
        )

        #expect(
            laneOutputLines(validPass) == ["[lane] lane-report receipt_valid=true", "[lane] lane-report verdict=pass"])
        #expect(
            laneOutputLines(validFail) == ["[lane] lane-report receipt_valid=true", "[lane] lane-report verdict=fail"])
        // An unlinked bundle or a dirty tree passing is not evidence about the commit.
        #expect(
            laneOutputLines(unlinkedPass) == [
                "[lane] lane-report receipt_valid=false reason=reused_bundle_unlinked",
                "[lane] lane-report verdict=unverified",
            ]
        )
        #expect(
            laneOutputLines(linkedPass) == ["[lane] lane-report receipt_valid=true", "[lane] lane-report verdict=pass"])
        #expect(
            laneOutputLines(dirtyPass) == [
                "[lane] lane-report receipt_valid=false reason=dirty_tree",
                "[lane] lane-report verdict=unverified",
            ]
        )
    }

    @Test("the closing tree state catches edits and commits made while the lane ran")
    func closingTreeStateCatchesChangesDuringTheLane() async throws {
        let repositoryDirectory = NSTemporaryDirectory() + "agentstudio-receipt-tree-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: repositoryDirectory) }
        let helperPath = FileManager.default.currentDirectoryPath + "/scripts/swift-test-helpers.sh"

        let states = try await laneBash(
            "source '\(helperPath)'; mkdir -p '\(repositoryDirectory)'; cd '\(repositoryDirectory)'; "
                + "git init -q . 2>/dev/null; "
                + "commit() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "
                + "-c core.hooksPath=/dev/null commit -q --allow-empty -m \"$1\"; }; commit one; "
                + "opening=$(lane_receipt_head_sha); "
                + "echo \"clean=$(lane_receipt_tree_dirty)\"; "
                + "echo \"clean_since=$(lane_receipt_tree_dirty_since \"$opening\" false)\"; "
                + "echo edit > untracked.txt; "
                + "echo \"edited_since=$(lane_receipt_tree_dirty_since \"$opening\" false)\"; "
                + "rm untracked.txt; "
                + "commit two; "
                + "echo \"moved_since=$(lane_receipt_tree_dirty_since \"$opening\" false)\"; "
                + "echo \"opened_dirty=$(lane_receipt_tree_dirty_since \"$opening\" true)\"; "
                + "cd /; echo \"outside=$(lane_receipt_tree_dirty) head=$(lane_receipt_head_sha)\""
        )

        #expect(
            laneOutputLines(states) == [
                "clean=false",
                "clean_since=false",
                "edited_since=true",
                "moved_since=true",
                "opened_dirty=true",
                "outside=unknown head=unknown",
            ]
        )
    }

    @Test("bundle receipt set names every target executable")
    func bundleIdentityNamesBundleAndModificationTime() async throws {
        let buildDirectory = NSTemporaryDirectory() + "agentstudio-receipt-bundle-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: buildDirectory) }
        let bundlePath = buildDirectory + "/out/Products/Debug/AgentStudioTests.xctest/Contents/MacOS/AgentStudioTests"

        let identities = try await laneBash(
            "source scripts/swift-test-helpers.sh; BUILD_PATH='\(buildDirectory)'; "
                + "mkdir -p \"$(dirname '\(bundlePath)')\"; : > '\(bundlePath)'; "
                + "chmod +x '\(bundlePath)'; echo \"count=$(swift_test_bundle_count)\"; "
                + "echo \"set=$(swift_test_bundle_set)\""
        )
        let identityLines = laneOutputLines(identities)
        #expect(identityLines.contains("count=1"))
        #expect(identityLines.contains(where: { $0.hasPrefix("set=") && $0.count == 20 }))
    }

    @Test("the receipt is printed on every exit, prebuild included, and only a finished prebuild is fresh")
    func receiptIsPrintedOnEveryExitAndOnlyFinishedPrebuildIsFresh() throws {
        let laneRunnerScript = try loadSwiftLaneRunnerReportingSource()
        let trapRange = try #require(laneRunnerScript.range(of: "trap finish_lane_invocation EXIT"))
        let prebuildCallRange = try #require(
            laneRunnerScript.range(of: "  prebuild_swift_tests_with_build_receipt\n  LANE_BUNDLE_STATE=fresh\n")
        )
        let prebuildExitRange = try #require(
            laneRunnerScript.range(of: "if [ \"$mode\" = \"test-prebuild\" ]; then\n  exit 0\nfi")
        )
        let freshAssignments = laneRunnerScript.components(separatedBy: "LANE_BUNDLE_STATE=fresh").count - 1

        // The trap is armed before anything can build or exit, so test-prebuild
        // and a failing prebuild both still print a closing receipt.
        #expect(trapRange.upperBound < prebuildCallRange.lowerBound)
        #expect(prebuildCallRange.upperBound < prebuildExitRange.lowerBound)
        #expect(laneRunnerScript.contains("LANE_BUNDLE_STATE=not_built\ntrap finish_lane_invocation EXIT"))
        // `fresh` is written in exactly one place: right after this invocation's
        // own prebuild returned successfully under `set -e`.
        #expect(freshAssignments == 1)
        #expect(laneRunnerScript.contains("  LANE_BUNDLE_STATE=reused\n"))
        // test-prebuild always builds: only the other modes may skip the prebuild.
        #expect(
            laneRunnerScript.contains(
                "if [ \"$mode\" != \"test-prebuild\" ] && [ \"${SWIFT_TEST_SKIP_PREBUILD:-0}\" = \"1\" ]; then"
            )
        )
        #expect(
            laneRunnerScript.contains("test|test-fast|test-large|test-prebuild|test-webkit|test-width-comparison)")
        )
    }

    @Test("a lane ended by a signal reports that status and never a pass")
    func laneEndedBySignalNeverReportsPass() async throws {
        // Observed in a real `mise run test`: the lane was SIGTERMed mid-phase and
        // its receipt said exit_status=0 verdict=pass, because bash runs the EXIT
        // trap with `$?` from the last completed command.
        let laneRunnerScript = try loadSwiftLaneRunnerReportingSource()
        let terminationTraps = try laneScriptShellFunction(
            named: "trap_lane_termination_signals",
            in: laneRunnerScript
        )
        let scriptDirectory = NSTemporaryDirectory() + "agentstudio-receipt-signal-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: scriptDirectory) }
        func signalledLane(installingTerminationTraps: Bool) -> String {
            [
                terminationTraps + "\n}",
                "LOG_PREFIX=lane",
                "source scripts/swift-test-helpers.sh",
                "report() { local status=$?; print_lane_receipt_verdict \"$status\" fresh false; }",
                "trap report EXIT",
                installingTerminationTraps ? "trap_lane_termination_signals" : ":",
                "true",
                "( kill -TERM $$ ) &",
                "wait",
            ].joined(separator: "\n") + "\n"
        }
        try FileManager.default.createDirectory(atPath: scriptDirectory, withIntermediateDirectories: true)
        try signalledLane(installingTerminationTraps: true)
            .write(toFile: scriptDirectory + "/trapped.sh", atomically: true, encoding: .utf8)
        try signalledLane(installingTerminationTraps: false)
            .write(toFile: scriptDirectory + "/untrapped.sh", atomically: true, encoding: .utf8)

        let trapped = try await laneBashAllowingFailure("bash '\(scriptDirectory)/trapped.sh'; echo \"STATUS=$?\"")
        let untrapped = try await laneBashAllowingFailure("bash '\(scriptDirectory)/untrapped.sh'; echo \"STATUS=$?\"")

        #expect(laneRunnerScript.contains("trap finish_lane_invocation EXIT\ntrap_lane_termination_signals\n"))
        #expect(trapped.contains("[lane] lane-report verdict=fail"))
        #expect(trapped.contains("STATUS=143"))
        // The control is the defect itself: same signal, a pass verdict.
        #expect(untrapped.contains("[lane] lane-report verdict=pass"))
        #expect(untrapped.contains("STATUS=143"))
    }

    @Test("a lane's build-slot claim is released when the lane exits")
    func laneBuildSlotClaimIsReleasedWhenTheLaneExits() async throws {
        let laneRunnerScript = try loadSwiftLaneRunnerReportingSource()
        let invocationExit = try laneScriptShellFunction(named: "finish_lane_invocation", in: laneRunnerScript)
        let repositoryRoot = FileManager.default.currentDirectoryPath
        let slotRoot = NSTemporaryDirectory() + "agentstudio-receipt-slot-\(UUIDv7.generate())"
        try FileManager.default.createDirectory(atPath: slotRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: slotRoot) }
        let output = try await laneBash(
            "set -euo pipefail\n"
                + "unset SWIFT_BUILD_DIR CI GITHUB_ACTIONS\n"
                + "source '\(repositoryRoot)/scripts/swift-build-slot.sh'\n"
                // The running lane holds this worktree's one slot. Claim a slot in a
                // private root so the proof cannot wait on its own parent lane.
                + "cd '\(slotRoot)'\n"
                + "swift_build_slot_acquire build \"receipt-test\"\n"
                + "print_closing_lane_report() { echo CLOSING_RECEIPT; }\n"
                + "swift_test_terminate_active_isolated_suites() { :; }\n"
                + invocationExit + "\n}\n"
                + "trap finish_lane_invocation EXIT\n"
                + "[ -d \"$SWIFT_BUILD_SLOT_CLAIM_DIRECTORY\" ] && echo CLAIM_HELD\n"
        )

        #expect(invocationExit.contains("print_closing_lane_report \"$exit_status\""))
        #expect(invocationExit.contains("swift_build_slot_release || true"))
        #expect(output.contains("CLAIM_HELD"))
        #expect(output.contains("CLOSING_RECEIPT"))
        #expect(output.contains("released slot=build task=receipt-test"))
        #expect(!output.contains("LANE_SLOT_RELEASE_COMMAND"))
    }

    @Test("a reused bundle is linked only to a matching bundle set and clean build")
    func reusedBundleIsLinkedOnlyToCleanSuccessfulBuildOfThisCommit() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-link-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        let scenarios = try await laneBash(
            "source scripts/swift-test-helpers.sh; BUILD_PATH='\(workDirectory)'; mkdir -p \"$BUILD_PATH\"; "
                + "receipt=$(lane_build_receipt_path); "
                + "head=$(git rev-parse HEAD); "
                + "printf 'bundle_set=set\\nbundle_count=1\\nhead_sha=%s\\ntree_dirty=false\\n' \"$head\" > \"$receipt\"; "
                + "echo clean=[$(lane_build_receipt_link_reason \"$receipt\" \"$head\" set)]; "
                + "printf 'bundle_set=other\\nbundle_count=1\\nhead_sha=%s\\ntree_dirty=false\\n' \"$head\" > \"$receipt\"; "
                + "echo mismatch=[$(lane_build_receipt_link_reason \"$receipt\" \"$head\" set)]; "
                + "printf 'bundle_set=set\\nbundle_count=1\\nhead_sha=%s\\ntree_dirty=true\\n' \"$head\" > \"$receipt\"; "
                + "echo dirty=[$(lane_build_receipt_link_reason \"$receipt\" \"$head\" set)]"
        )
        #expect(
            laneOutputLines(scenarios) == [
                "clean=[]", "mismatch=[reused_bundle_unlinked]", "dirty=[built_from_dirty_tree]",
            ])
    }

    @Test("all crashed WebKit suites fail the lane, are tallied, and are never retried")
    func crashedWebKitSuiteFailsTheLaneWithoutRetry() async throws {
        // Two crashes must both be recorded while the healthy filter still runs.
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-webkit-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }

        let laneOutput = try await laneBashAllowingFailure(
            "mkdir -p '\(workDirectory)/bin'; "
                + "printf '#!/bin/bash\\necho started >> \"\(workDirectory)/invocations\"\\n"
                + "if [[ \"$*\" == *CrashingSuite* || \"$*\" == *SecondCrashingSuite* ]]; then "
                + "echo \"error: Exited with unexpected signal code 11\"; exit 1; fi\\n"
                + "echo HEALTHY_WEBKIT_RAN\\n' > '\(workDirectory)/bin/fake-helper'; "
                + "chmod +x '\(workDirectory)/bin/fake-helper'; "
                + "export SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE='\(workDirectory)/tally'; "
                + ": > \"$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE\"; "
                + "LOG_PREFIX=webkit; TIMEOUT_SECONDS=60; BUILD_PATH='\(workDirectory)/build'; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                // Starve the runner as on a loaded host; every crash must still be named.
                + laneRunnerStarvedDrainHook(fifoDirectory: workDirectory)
                + "swift_test_bundle_for_suite() { echo '\(workDirectory)/fake-bundle'; }; "
                + "swift_testing_helper_path() { echo '\(workDirectory)/bin/fake-helper'; }; "
                + "swift_testing_framework_path() { echo '\(workDirectory)'; }; "
                + "webkit_suite_filters() { printf 'WebKitSerializedTests/CrashingSuite\\n"
                + "WebKitSerializedTests/SecondCrashingSuite\\n"
                + "WebKitSerializedTests/HealthySuite\\n'; }; "
                + "run_webkit_suites; echo \"LANE_STATUS=$?\"; "
                + "echo \"INVOCATIONS=$(wc -l < '\(workDirectory)/invocations' | tr -d '[:space:]')\"; "
                + "cat \"$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE\""
        )

        #expect(laneOutput.contains("LANE_STATUS=1"))
        #expect(laneOutput.contains("INVOCATIONS=3"))
        #expect(laneOutput.contains("WebKit process-global concurrency: 1"))
        #expect(laneOutput.contains("HEALTHY_WEBKIT_RAN"))
        #expect(
            laneOutput.contains("WebKit suite failed: WebKitSerializedTests/CrashingSuite status=1 signal=SEGV")
        )
        #expect(laneOutput.contains("WebKitSerializedTests/CrashingSuite\t1\tSEGV"))
        #expect(
            laneOutput.contains("WebKit suite failed: WebKitSerializedTests/SecondCrashingSuite status=1 signal=SEGV")
        )
        #expect(laneOutput.contains("WebKitSerializedTests/SecondCrashingSuite\t1\tSEGV"))
        #expect(!laneOutput.contains("retrying"))
    }

    @Test("crash signals are read from the status or from swift test's own report")
    func crashSignalsAreReadFromStatusOrSwiftTestReport() async throws {
        let names = try await laneBash(
            "source scripts/swift-test-helpers.sh; "
                + "swift_test_crash_signal_name 139 ''; "
                + "swift_test_crash_signal_name 1 'error: Exited with unexpected signal code 5'; "
                + "swift_test_crash_signal_name 1 'Test run with 2 tests failed'; "
                + "swift_test_crash_signal_name 124 ''"
        )

        #expect(laneOutputLines(names) == ["SEGV", "TRAP", "none", "none"])
    }

    @Test("the width comparison runs both halves on one bundle and keeps every ledger")
    func widthComparisonRunsBothHalvesOnOneBundleAndKeepsEveryLedger() async throws {
        let laneRunnerScript = try loadSwiftLaneRunnerReportingSource()
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let comparison = try laneScriptShellFunction(named: "run_width_comparison", in: laneRunnerScript)
        let half = try laneScriptShellFunction(named: "run_width_comparison_half", in: laneRunnerScript)
        let comparisonTask = try laneScriptNamedBlock(
            startingWith: "[tasks.\"test:swift:width-comparison\"]",
            endingBefore: "\n[tasks.",
            in: miseConfig
        )
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-retain-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }

        let eventFixture = try InvocationReceiptFixture()
        defer { eventFixture.remove() }
        try writeCapturedInvocation(eventFixture, selecting: "recordsPass()")
        let retained = try await laneBash(
            "LOG_PREFIX=lane; TIMEOUT_SECONDS=60; BUILD_PATH='\(workDirectory)/build'; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)'; LANE_EVENT_STREAM_RETAIN_ALWAYS=1; "
                + "source scripts/swift-test-helpers.sh; "
                + "run_swift_with_timeout 'clean half' 60 /bin/bash -c 'echo CLEAN_RUN_OK; cp \"$1\" \"${@: -1}\"' fixture '\(eventFixture.events.path)' swiftpm-testing-helper; "
                + "echo \"LEDGERS=$(find '\(workDirectory)' -name '*.events.jsonl' | wc -l | tr -d '[:space:]')\"; "
                + "echo \"TIMINGS=$(find '\(workDirectory)' -name '*.timing.json' | wc -l | tr -d '[:space:]')\""
        )

        #expect(comparisonTask.contains("run = \"/bin/bash scripts/run-swift-test-task.sh test-width-comparison\""))
        // Width 3 is the CI runner's core count; the other half leaves it unset.
        #expect(comparison.contains("run_width_comparison_half 3 \"$comparison_directory/width-3\""))
        #expect(comparison.contains("run_width_comparison_half \"\" \"$comparison_directory/width-unlimited\""))
        // One bundle for both halves: the comparison never builds, and its
        // directory is named for the bundle both halves share.
        #expect(!comparison.contains("prebuild_swift_tests"))
        #expect(!half.contains("prebuild_swift_tests"))
        #expect(comparison.contains("-bundle-${bundle_set}"))
        // Each half is a lane of its own: opening receipt, closing receipt on
        // EXIT, forced ledger retention, and its whole output kept.
        #expect(
            half.contains(
                "print_opening_lane_report\n    begin_lane_accounting\n    trap print_closing_lane_report EXIT"
            )
        )
        #expect(half.contains("trap print_closing_lane_report EXIT\n    trap_lane_termination_signals\n"))
        #expect(half.contains("LANE_EVENT_STREAM_RETAIN_ALWAYS=1"))
        // Each half reuses the parent's bundle, so its receipt says `reused` and is
        // valid only when linked to the build receipt that prebuild published.
        #expect(half.contains("    LANE_BUNDLE_STATE=reused\n"))
        #expect(half.contains("unset SWIFT_TEST_PARALLELIZATION_WIDTH"))
        #expect(half.contains("tee \"$ledger_directory/lane-output.log\""))
        // A passing run keeps its ledger when retention is forced.
        #expect(retained.contains("CLEAN_RUN_OK"))
        #expect(retained.contains("lane-report event_stream=\(workDirectory)/lane-clean-half-"))
        #expect(retained.contains("LEDGERS=1"))
        #expect(retained.contains("TIMINGS=1"))
    }
}
