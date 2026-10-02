import AgentStudioInfrastructure
import Foundation
import Testing

@Suite("Swift lane receipts and hang evidence")
struct SwiftLaneReceiptTests {
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

    @Test("bundle identity names the exact executable: path, size and modification time")
    func bundleIdentityNamesBundleAndModificationTime() async throws {
        let buildDirectory = NSTemporaryDirectory() + "agentstudio-receipt-bundle-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: buildDirectory) }
        let bundlePath =
            buildDirectory
            + "/arm64-apple-macosx/debug/AgentStudioPackageTests.xctest/Contents/MacOS/AgentStudioPackageTests"

        let identities = try await laneBash(
            "source scripts/swift-test-helpers.sh; BUILD_PATH='\(buildDirectory)'; "
                + "echo \"before=$(lane_receipt_bundle_identity)\"; "
                + "mkdir -p \"$(dirname '\(bundlePath)')\"; : > '\(bundlePath)'; "
                + "touch -t 202609230102.03 '\(bundlePath)'; "
                + "echo \"after=$(lane_receipt_bundle_identity)\"; "
                + "echo \"epoch=$(date -j -f %Y%m%d%H%M.%S 202609230102.03 +%s)\""
                + "; printf 'seven b' > '\(bundlePath)'; touch -t 202609230102.03 '\(bundlePath)'; "
                + "echo \"resized=$(lane_receipt_bundle_identity)\""
        )
        let identityLines = laneOutputLines(identities)
        let epoch = try #require(identityLines.dropFirst(2).first?.split(separator: "=").last.map(String.init))

        #expect(identityLines.first == "before=missing")
        #expect(identityLines.dropFirst().first == "after=\(bundlePath)@0@\(epoch)")
        // Same path, same mtime, different executable: the size tells them apart.
        #expect(identityLines.dropFirst(3).first == "resized=\(bundlePath)@7@\(epoch)")
    }

    @Test("the receipt is printed on every exit, prebuild included, and only a finished prebuild is fresh")
    func receiptIsPrintedOnEveryExitAndOnlyFinishedPrebuildIsFresh() throws {
        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
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
        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
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
        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
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

    @Test("a reused bundle is linked only to a clean, successful build of this commit and this executable")
    func reusedBundleIsLinkedOnlyToCleanSuccessfulBuildOfThisCommit() async throws {
        let helperPath = FileManager.default.currentDirectoryPath + "/scripts/swift-test-helpers.sh"
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-link-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        let bundleSuffix =
            "/arm64-apple-macosx/debug/AgentStudioPackageTests.xctest/Contents/MacOS/AgentStudioPackageTests"

        // prebuild_swift_tests is replaced by a fake that writes the executable or
        // fails; everything else is the real receipt code.
        let scenarios = try await laneBash(
            "source '\(helperPath)'; LOG_PREFIX=lane; BUILD_PATH='\(workDirectory)/build'; "
                + "bundle=\"$BUILD_PATH\(bundleSuffix)\"; receipt=$(lane_build_receipt_path); "
                + "prebuild_swift_tests() { [ \"${FAKE_BUILD_FAILS:-0}\" = 1 ] && return 1; "
                + "mkdir -p \"$(dirname \"$bundle\")\"; printf v1 > \"$bundle\"; }; "
                + "link() { lane_build_receipt_link_reason \"$receipt\" \"$(lane_receipt_head_sha)\" "
                + "\"$(lane_receipt_bundle_identity)\"; }; "
                + "mkdir -p '\(workDirectory)/repo'; cd '\(workDirectory)/repo'; git init -q . 2>/dev/null; "
                + "commit() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "
                + "-c core.hooksPath=/dev/null commit -q --allow-empty -m \"$1\"; }; commit one; "
                + "prebuild_swift_tests_with_build_receipt; echo \"clean_reuse=[$(link)]\"; "
                + "echo \"linked_head=$([ \"$(lane_build_receipt_field \"$receipt\" head_sha)\" = "
                + "\"$(git rev-parse HEAD)\" ] && echo current)\"; "
                + "printf 'rebuilt elsewhere' > \"$bundle\"; echo \"mismatched_artifact=[$(link)]\"; "
                + "prebuild_swift_tests_with_build_receipt; commit two; echo \"moved_head=[$(link)]\"; "
                + "echo edit > untracked.txt; prebuild_swift_tests_with_build_receipt; rm untracked.txt; "
                + "echo \"dirty_build_then_clean_tree=[$(link)]\"; "
                + "prebuild_swift_tests_with_build_receipt; echo \"rebuilt=[$(link)]\"; "
                + "FAKE_BUILD_FAILS=1 prebuild_swift_tests_with_build_receipt; echo \"failed_status=$?\"; "
                + "echo \"receipt_after_failure=$([ -e \"$receipt\" ] && echo present || echo absent)\"; "
                + "echo \"failed_rebuild=[$(link)]\"; "
                + "printf 'garbage\\n' > \"$receipt\"; echo \"malformed=[$(link)]\"; "
                + "printf 'bundle_identity=\\nhead_sha=x\\ntree_dirty=false\\n' > \"$receipt\"; "
                + "echo \"empty_field=[$(link)]\"; rm -f \"$receipt\"; echo \"absent=[$(link)]\"; "
                + "echo \"staged_leftovers=$(ls \"$BUILD_PATH\" | grep -c 'agentstudio-test-build-receipt\\.' || true)\""
        )

        #expect(
            laneOutputLines(scenarios) == [
                "clean_reuse=[]",
                "linked_head=current",
                "mismatched_artifact=[reused_bundle_unlinked]",
                "moved_head=[bundle_head_mismatch]",
                "dirty_build_then_clean_tree=[built_from_dirty_tree]",
                "rebuilt=[]",
                // The failed build deleted the receipt before compiling, so the
                // previous (good) receipt cannot vouch for what the failure left.
                "failed_status=1",
                "receipt_after_failure=absent",
                "failed_rebuild=[reused_bundle_unlinked]",
                "malformed=[reused_bundle_unlinked]",
                "empty_field=[reused_bundle_unlinked]",
                "absent=[reused_bundle_unlinked]",
                // Published by rename: no staged receipt is left behind.
                "staged_leftovers=0",
            ]
        )
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
                + "LOG_PREFIX=webkit; TIMEOUT_SECONDS=60; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "swift_testing_bundle_path() { echo '\(workDirectory)/fake-bundle'; }; "
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
        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
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

        let retained = try await laneBash(
            "LOG_PREFIX=lane; TIMEOUT_SECONDS=60; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)'; LANE_EVENT_STREAM_RETAIN_ALWAYS=1; "
                + "source scripts/swift-test-helpers.sh; "
                + "run_swift_with_timeout 'clean half' 60 /bin/bash -c 'echo CLEAN_RUN_OK'; "
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
        #expect(comparison.contains("-bundle-${bundle_identity##*@}"))
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
