import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

private enum SwiftBuildSlotScriptTestFailure: Error {
    case expectedOperationFailure
}

@Suite("Swift build slot script")
struct SwiftBuildSlotScriptTests {
    @Test("a failed operation closes and reaps its blocked helper")
    func failedOperationClosesAndReapsBlockedHelper() async throws {
        let fixture = try SwiftBuildSlotFixture()

        await #expect(throws: SwiftBuildSlotScriptTestFailure.self) {
            try await fixture.withOwnedProcesses { fixture in
                let helper = fixture.makeProcess("printf 'HELPER_READY\\n'; IFS= read -r _")
                helper.start()
                _ = try await helper.readOutput(until: "HELPER_READY")
                throw SwiftBuildSlotScriptTestFailure.expectedOperationFailure
            }
        }

        let helperPID = try #require(fixture.ownedProcessIdentifiers.first)
        #expect(kill(helperPID, 0) == -1 && errno == ESRCH)
        #expect(!fixture.hasRunningHelpers)
    }

    @Test("cancellation closes and reaps its blocked helper")
    func cancellationClosesAndReapsBlockedHelper() async throws {
        let fixture = try SwiftBuildSlotFixture()
        let helperArrived = HeldStep<Void>("swift-build-slot-helper-blocked-on-stdin")
        let helperTask = Task {
            try await fixture.withOwnedProcesses { fixture in
                let helper = fixture.makeProcess("printf 'HELPER_READY\\n'; IFS= read -r _")
                helper.start()
                _ = try await helper.readOutput(until: "HELPER_READY")
                try await helperArrived.arrive(())
            }
        }

        _ = try await helperArrived.firstArrival()
        helperTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await helperTask.value
        }
        #expect(!fixture.hasRunningHelpers)
    }

    @Test("only named local slots and task labels are accepted")
    func onlyNamedSlotsAndTaskLabelsAreAccepted() async throws {
        let fixture = try SwiftBuildSlotFixture()

        let unknownSlot = try await fixture.run(
            "source scripts/swift-build-slot.sh\nswift_build_slot_acquire compile \"unknown\""
        )
        let missingTask = try await fixture.run(
            "source scripts/swift-build-slot.sh\nswift_build_slot_acquire build"
        )

        #expect(unknownSlot.exitCode != 0)
        #expect(unknownSlot.output.contains("expected slot 'build' or 'test'"))
        #expect(missingTask.exitCode != 0)
        #expect(missingTask.output.contains("task label is required"))
    }

    @Test("build and test share the worktree's one slot, wait for each other, and keep existing contents")
    func buildAndTestShareOneSlotAndPreserveExistingContents() async throws {
        let fixture = try SwiftBuildSlotFixture()
        let existingMarker = fixture.rootURL.appending(path: ".build-agent-1/existing-artifact")
        try FileManager.default.createDirectory(
            at: existingMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing-build".utf8).write(to: existingMarker)

        let result = try await fixture.withOwnedProcesses { fixture in
            let buildOwner = fixture.makeProcess(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire build \"build-owner\"\n"
                    + "printf 'BUILD_READY\\n'\n"
                    + "IFS= read -r _ || exit 0\n"
            )
            buildOwner.start()
            var output = try await buildOwner.readOutput(until: "BUILD_READY")

            let testWaiter = fixture.makeProcess(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire test \"test-waiter\"\n"
                    + "printf 'TEST_READY\\n'\n"
            )
            testWaiter.start()
            output += try await testWaiter.readOutput(until: "waiting slot=test holder_task=build-owner")

            try writeLine("release\n", to: buildOwner.standardInput)
            output += try await buildOwner.readOutputToEnd()
            let buildStatus = try await buildOwner.waitForExit()
            output += try await testWaiter.readOutputToEnd()
            return (buildStatus, try await testWaiter.waitForExit(), output)
        }

        #expect(result.0 == 0)
        #expect(result.1 == 0)
        #expect(result.2.contains("using slot=build path=.build-agent-1 task=build-owner"))
        #expect(result.2.contains("waiting slot=test holder_task=build-owner"))
        #expect(result.2.contains("using slot=test path=.build-agent-1 task=test-waiter"))
        #expect(result.2.contains("TEST_READY"))
        #expect(try String(contentsOf: existingMarker, encoding: .utf8) == "existing-build")
        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.appending(path: ".build-agent-2").path))
    }

    @Test("a same-slot claimant reports its holder once and runs after release")
    func secondBuildClaimWaitsWithOneHolderLineAndThenRuns() async throws {
        let fixture = try SwiftBuildSlotFixture()
        let result = try await fixture.withOwnedProcesses { fixture in
            let owner = fixture.makeProcess(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire build \"build-owner\"\n"
                    + "printf 'OWNER_READY\\n'\n"
                    + "IFS= read -r _ || exit 0\n"
            )
            owner.start()
            _ = try await owner.readOutput(until: "OWNER_READY")

            let waiter = fixture.makeProcess(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire build \"build-waiter\"\n"
                    + "printf 'WAITER_DONE\\n'\n"
            )
            waiter.start()
            var waiterLog = try await waiter.readOutput(
                until: "waiting slot=build holder_task=build-owner"
            )
            let activeHolderNote = fixture.rootURL.appending(path: ".build-agent-1/.slot.holder")
            let activeHolderExists = FileManager.default.fileExists(atPath: activeHolderNote.path)
            let activeHolderContents = try String(contentsOf: activeHolderNote, encoding: .utf8)

            try writeLine("release-owner\n", to: owner.standardInput)
            let ownerStatus = try await owner.waitForExit()
            waiterLog += try await waiter.readOutput(until: "WAITER_DONE")
            waiterLog += try await waiter.readOutputToEnd()

            return (ownerStatus, try await waiter.waitForExit(), waiterLog, activeHolderExists, activeHolderContents)
        }

        let waitingLines = result.2.components(separatedBy: .newlines).filter {
            $0.contains("[swift-build-slot] waiting slot=build")
        }
        #expect(result.0 == 0)
        #expect(result.1 == 0)
        #expect(waitingLines.count == 1)
        #expect(waitingLines.first?.contains("holder_task=build-owner") == true)
        #expect(waitingLines.first?.range(of: #"holder_pid=[0-9]+"#, options: .regularExpression) != nil)
        #expect(waitingLines.first?.contains("holder_start=") == true)
        #expect(result.3)
        #expect(result.4.contains("holder_task=build-owner"))
    }

    @Test("normal and nonzero exits both release a named slot")
    func normalAndNonzeroExitsReleaseClaim() async throws {
        let fixture = try SwiftBuildSlotFixture()

        for exitCode in [0, 23] {
            let result = try await fixture.run(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire test \"exit-$exitCode\"\n"
                    + "exit $exitCode"
                    .replacingOccurrences(of: "$exitCode", with: String(exitCode))
            )
            #expect(result.exitCode == exitCode)
            let next = try await fixture.run(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire test \"after-exit\""
            )
            #expect(next.exitCode == 0)
            #expect(next.output.contains("using slot=test path=.build-agent-1 task=after-exit"))
        }
    }

    @Test("a handled termination signal releases its named slot")
    func handledSignalReleasesClaim() async throws {
        let fixture = try SwiftBuildSlotFixture()
        let result = try await fixture.withOwnedProcesses { fixture in
            let process = fixture.makeProcess(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "trap 'exit 143' TERM\n"
                    + "swift_build_slot_acquire test \"signal-owner\"\n"
                    + "/bin/bash -c 'sleep 1' <&0 &\n"
                    + "sleep_child_pid=$!\n"
                    + "printf 'SIGNAL_READY\\n'\n"
                    + "wait \"$sleep_child_pid\"\n",
                environment: ["SWIFT_BUILD_SLOT_SLEEP_GATE": "stdin"]
            )
            process.start()
            let log = try await process.readOutput(until: "SIGNAL_READY")
            _ = kill(Int32(process.processIdentifier), SIGTERM)
            try writeLine("finish-sleep-child\n", to: process.standardInput)
            let outputTail = try await process.readOutputToEnd()
            return (try await process.waitForExit(), log + outputTail)
        }

        #expect(result.0 == 143)
        let next = try await fixture.run(
            "source scripts/swift-build-slot.sh\n"
                + "trap swift_build_slot_release EXIT\n"
                + "swift_build_slot_acquire test \"after-signal\""
        )
        #expect(next.exitCode == 0)
    }

    @Test("CI bypass is exact and local build directory overrides stay rejected")
    func ciBypassAndLocalOverrideContract() async throws {
        let fixture = try SwiftBuildSlotFixture()

        for environment in [
            ["CI": "true", "SWIFT_BUILD_DIR": ".build-ci"],
            ["GITHUB_ACTIONS": "true", "SWIFT_BUILD_DIR": ".build-ci"],
        ] {
            let result = try await fixture.run(
                "source scripts/swift-build-slot.sh\nswift_build_slot_acquire build \"ci-task\"",
                environment: environment
            )
            #expect(result.exitCode == 0)
            #expect(result.output.contains("using CI build path .build-ci"))
        }

        let localOverride = try await fixture.run(
            "source scripts/swift-build-slot.sh\nswift_build_slot_acquire build \"local-task\"",
            environment: ["SWIFT_BUILD_DIR": ".build-local"]
        )
        #expect(localOverride.exitCode != 0)
        #expect(localOverride.output.contains("local SWIFT_BUILD_DIR overrides are not supported"))
        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.appending(path: ".build-agent-1").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.appending(path: ".build-agent-2").path))
    }

    @Test("the test runner receipt handler releases the slot and preserves failure status")
    func runnerExitHandlerEmitsReceiptAndReleasesAfterFailure() async throws {
        let fixture = try SwiftBuildSlotFixture()
        let runnerSource = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let exitHandler = try swiftBuildSlotShellFunction(named: "finish_lane_invocation", in: runnerSource)
        let result = try await fixture.run(
            "source scripts/swift-build-slot.sh\n"
                + "swift_build_slot_acquire test \"runner-failure\"\n"
                + "print_closing_lane_report() { printf 'lane-receipt exit_status=%s\\n' \"$1\"; }\n"
                + exitHandler + "\n"
                + "trap finish_lane_invocation EXIT\n"
                + "exit 17"
        )

        #expect(result.exitCode == 17)
        #expect(result.output.contains("lane-receipt exit_status=17"))
        #expect(result.output.contains("released slot=test task=runner-failure"))
        #expect(result.output.components(separatedBy: "released slot=test task=runner-failure").count == 2)
        #expect(!runnerSource.contains("LANE_SLOT_RELEASE_COMMAND"))
        #expect(!runnerSource.contains("trap -p EXIT"))
        let next = try await fixture.run(
            "source scripts/swift-build-slot.sh\n"
                + "trap swift_build_slot_release EXIT\n"
                + "swift_build_slot_acquire test \"after-runner\""
        )
        #expect(next.exitCode == 0)
    }

    @Test("cleanup preserves leftovers while the slot is held and removes them once it is free")
    func cleanupPreservesHeldSlotAndRemovesFreeLeftovers() async throws {
        let fixture = try SwiftBuildSlotFixture()
        let legacyClaim = fixture.rootURL.appending(path: ".build-agent-1/.slot-claim")
        try FileManager.default.createDirectory(at: legacyClaim, withIntermediateDirectories: true)
        try Data().write(to: legacyClaim.appending(path: "holder"))

        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let cleanerBody = try miseTaskBody(named: "clean-agent-builds", in: miseConfig)
        let result = try await fixture.withOwnedProcesses { fixture in
            let owner = fixture.makeProcess(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire test \"held-owner\"\n"
                    + "printf 'OWNER_READY\\n'\n"
                    + "IFS= read -r _ || exit 0\n"
            )
            owner.start()
            _ = try await owner.readOutput(until: "OWNER_READY")
            let heldCleaner = fixture.makeProcess(cleanerBody, environment: ["PROJECT_ROOT": fixture.rootURL.path])
            heldCleaner.start()
            let heldOutput = try await heldCleaner.readOutputToEnd()
            let heldStatus = try await heldCleaner.waitForExit()
            let claimSurvivedWhileHeld = FileManager.default.fileExists(atPath: legacyClaim.path)

            try writeLine("release\n", to: owner.standardInput)
            _ = try await owner.readOutputToEnd()
            _ = try await owner.waitForExit()

            let freeCleaner = fixture.makeProcess(cleanerBody, environment: ["PROJECT_ROOT": fixture.rootURL.path])
            freeCleaner.start()
            let freeOutput = try await freeCleaner.readOutputToEnd()
            let freeStatus = try await freeCleaner.waitForExit()
            return (heldStatus, heldOutput, claimSurvivedWhileHeld, freeStatus, freeOutput)
        }

        #expect(result.0 == 0)
        #expect(result.1.contains("preserved held slot holder_task=held-owner"))
        #expect(result.2)
        #expect(result.3 == 0)
        #expect(result.4.contains("removed legacy claim"))
        #expect(!FileManager.default.fileExists(atPath: legacyClaim.path))
        #expect(
            FileManager.default.fileExists(atPath: fixture.rootURL.appending(path: ".build-agent-1/.slot.lock").path))
    }

    @Test("a holder killed with SIGKILL frees its slot through the kernel")
    func killedHolderFreesSlot() async throws {
        let fixture = try SwiftBuildSlotFixture()
        let result = try await fixture.withOwnedProcesses { fixture in
            let victim = fixture.makeProcess(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire build \"victim\"\n"
                    + "printf 'VICTIM_READY\\n'\n"
                    + "IFS= read -r _ || exit 0\n"
            )
            victim.start()
            _ = try await victim.readOutput(until: "VICTIM_READY")
            _ = kill(Int32(victim.processIdentifier), SIGKILL)
            let victimStatus = try await victim.waitForExit()
            let next = fixture.makeProcess(
                "source scripts/swift-build-slot.sh\n"
                    + "trap swift_build_slot_release EXIT\n"
                    + "swift_build_slot_acquire build \"after-kill\"\n"
            )
            next.start()
            let output = try await next.readOutputToEnd()
            return (victimStatus, try await next.waitForExit(), output)
        }

        #expect(result.0 == SIGKILL)
        #expect(result.1 == 0)
        #expect(result.2.contains("using slot=build path=.build-agent-1 task=after-kill"))
    }

    @Test("slots work when ps is unavailable, as in agent sandboxes")
    func slotsWorkWithoutProcessInspection() async throws {
        let fixture = try SwiftBuildSlotFixture()
        let deniedBin = fixture.rootURL.appending(path: "denied-bin")
        try FileManager.default.createDirectory(at: deniedBin, withIntermediateDirectories: true)
        for tool in ["ps", "lsof"] {
            let url = deniedBin.appending(path: tool)
            try Data("#!/bin/sh\necho \"$0: Operation not permitted\" >&2\nexit 126\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let result = try await fixture.run(
            "source scripts/swift-build-slot.sh\n"
                + "trap swift_build_slot_release EXIT\n"
                + "swift_build_slot_acquire test \"sandboxed\"\n"
                + "printf 'SANDBOXED_RAN\\n'\n",
            environment: ["PATH": "\(deniedBin.path):/usr/bin:/bin"]
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("SANDBOXED_RAN"))
        #expect(!result.output.contains("Operation not permitted"))
    }
}
