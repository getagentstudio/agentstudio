import AgentStudioInfrastructure
import Darwin
import Foundation
import Testing

/// What a hung lane leaves behind before it is terminated: a concurrency task
/// dump per stuck test process, the held steps never reached, and the event
/// ledger, all side by side where the CI failure upload selects them.
@Suite("Swift lane hang evidence")
struct SwiftLaneHangEvidenceTests {
    @Test("receipt metadata and a cancelled settlement preserve the existing parser's payload pairing")
    func receiptMetadataPreservesExistingParserPairing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-parser-receipts-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRecords = [
            "waiting\tstep-1\tstill missing\tSuite.swift pending()",
            "waiting\tstep-2\tcancelled then arrived\tSuite.swift closed()",
            "arrived\tstep-2\tcancelled then arrived",
            "expecting\texpectation-1\trefreshClosed\tscope\tSuite.swift pending()\tSuite.swift:4 pending()",
            "expecting\texpectation-2\talreadyClosed\tscope\tSuite.swift closed()\tSuite.swift:5 closed()",
            "settled\texpectation-2\tmatched",
        ]
        var receiptRecords = legacyRecords
        // A cancelled waiter can be followed by a later producer arrival, as
        // HeldStepTests.eventLogRecordsWaitingAndFirstArrival exercises.
        receiptRecords.insert("wait_settled\tstep-2\t8\tcancelled", at: 2)
        let metadata =
            #"{"clockDomain":"CLOCK_UPTIME_RAW","seconds":100,"nanoseconds":42,"testID":"Module.Suite/test()","caseID":null,"parameterized":true,"waiterID":8}"#
        let oldURL = root.appendingPathComponent("old.log")
        let newURL = root.appendingPathComponent("new.log")
        try (legacyRecords.joined(separator: "\n") + "\n").write(to: oldURL, atomically: true, encoding: .utf8)
        try (receiptRecords.map { $0 + "\t" + metadata }.joined(separator: "\n") + "\n")
            .write(to: newURL, atomically: true, encoding: .utf8)

        let output = try await laneBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; "
                + "echo OLD; print_held_steps_unarrived_at_timeout '\(oldURL.path)'; "
                + "echo NEW; print_held_steps_unarrived_at_timeout '\(newURL.path)'"
        )
        let expected = [
            "[lane] lane-report held_step_unarrived name=still missing id=step-1 test=Suite.swift pending()",
            "[lane] lane-report fact_expected id=expectation-1 expected=refreshClosed scope=scope "
                + "test=Suite.swift pending() site=Suite.swift:4 pending()",
        ]
        #expect(laneOutputLines(output) == ["OLD"] + expected + ["NEW"] + expected)
    }

    @Test("long event stream labels keep a stable bounded slug and short labels keep their slug")
    func eventStreamLabelSlugBoundsLongLabelsWithoutChangingShortLabels() async throws {
        let output = try await laneBash(
            "source scripts/swift-test-helpers.sh; "
                + "long_filter=$(printf '%400s' '' | tr ' ' 'A'); "
                + "first_slug=$(lane_event_stream_label_slug \"$long_filter\"); "
                + "second_slug=$(lane_event_stream_label_slug \"$long_filter\"); "
                + "short_slug=$(lane_event_stream_label_slug 'Native concurrent fast non-WebKit suites'); "
                + "printf 'LONG_LENGTH=%s\\nLONG_STABLE=%s\\nSHORT=%s\\n' \"${#first_slug}\" "
                + "\"$([ \"$first_slug\" = \"$second_slug\" ] && echo yes || echo no)\" \"$short_slug\""
        )

        #expect(output.contains("LONG_LENGTH=91"))
        #expect(output.contains("LONG_STABLE=yes"))
        #expect(output.contains("SHORT=native-concurrent-fast-non-webkit-suites"))
    }

    @Test("a hung test process gets a concurrency task dump before it is terminated")
    func hungTestProcessGetsTaskDumpBeforeTermination() async throws {
        // The fake child carries the test-bundle name so the runner selects it
        // for stack capture, then stalls without output like a wedged suite.
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-dump-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }

        let laneOutput = try await laneBashAllowingFailure(
            "mkdir -p '\(workDirectory)'; "
                + "LOG_PREFIX=lane; TIMEOUT_SECONDS=0; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'dump probe' 0 /bin/bash -c "
                + "'while true; do sleep 1; done' AgentStudioPackageTests "
                + "|| returned=$?; echo \"RETURNED=${returned:-0}\""
        )
        let dumpRange = try #require(laneOutput.range(of: "lane-report task_dump="))
        let reapRange = try #require(laneOutput.range(of: "lane-report timeout_reap="))

        #expect(laneOutput.contains("RETURNED=124"))
        // bash is not a Swift process swift-inspect may attach to, so the dump
        // is refused, and the refusal is recorded instead of failing the lane.
        #expect(laneOutput.contains("lane-report task_dump=unavailable pid="))
        #expect(laneOutput.contains("reason="))
        // Taken while the process is still stuck, not after the reap.
        #expect(dumpRange.lowerBound < reapRange.lowerBound)
    }

    @Test("a forced hang keeps its task dump and held-step log beside its ledger, where the CI upload finds them")
    func forcedHangKeepsDumpAndHeldStepLogBesideLedger() async throws {
        // The child is a wedged test: it records two held-step waits, only one of
        // which arrives, then stalls. The fake swift-inspect attaches and dumps,
        // as it does for a real test process built with get-task-allow.
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-evidence-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        let evidenceDirectory = workDirectory + "/ci-runs"
        try FileManager.default.createDirectory(atPath: workDirectory + "/bin", withIntermediateDirectories: true)
        try """
        printf 'waiting\\tstep-1\\tgate A\\tSuite.swift first()\\nwaiting\\tstep-2\\tgate B\\tSuite.swift second()\\n' \
          >> "$AGENTSTUDIO_HELD_STEP_LOG"
        printf 'arrived\\tstep-1\\tgate A\\n' \
          >> "$AGENTSTUDIO_HELD_STEP_LOG"
        printf 'expecting\\tchild-1\\trefreshClosed\\tworktree-1\\tSuite.swift test()\\tSuite.swift:42 test()\\n' \
          >> "$AGENTSTUDIO_HELD_STEP_LOG"
        touch "$LANE_WATCHDOG_ARM_PATH"
        while true; do sleep 1; done

        """.write(toFile: workDirectory + "/wedged-test.sh", atomically: true, encoding: .utf8)
        try """
        #!/bin/bash
        echo TASKS; echo "  Task 1 async backtrace: parkForever()"

        """.write(toFile: workDirectory + "/bin/xcrun", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workDirectory + "/bin/xcrun")

        let laneOutput = try await laneBashAllowingFailure(
            "LOG_PREFIX=lane; TIMEOUT_SECONDS=0; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(evidenceDirectory)'; "
                + "export LANE_WATCHDOG_ARM_PATH='\(workDirectory)/watchdog-armed'; "
                + "export PATH='\(workDirectory)/bin':$PATH; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'evidence probe' 0 /bin/bash '\(workDirectory)/wedged-test.sh' "
                + "AgentStudioPackageTests || returned=$?; echo \"RETURNED=${returned:-0}\""
        )
        let evidenceFiles = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory).sorted()
        let ledger = try #require(evidenceFiles.first { $0.hasSuffix(".events.jsonl") })
        let evidenceStem = String(ledger.dropLast(".events.jsonl".count))
        let taskDumps = evidenceFiles.filter { $0.hasSuffix(".task-dump.txt") }
        let heldStepLog = evidenceStem + ".held-steps.log"
        let uploadGlobs = try ciUploadedEvidenceGlobs()
        let unarrivedRange = try #require(laneOutput.range(of: "lane-report held_step_unarrived "))
        let missingFactRange = try #require(laneOutput.range(of: "lane-report fact_expected "))
        let reapRange = try #require(laneOutput.range(of: "lane-report timeout_reap="))

        // The hang verdict is failed whatever evidence was gathered.
        #expect(laneOutput.contains("RETURNED=124"))
        // Only the wait that never arrived is named, before anything is reaped.
        #expect(
            laneOutput.contains("lane-report held_step_unarrived name=gate B id=step-2 test=Suite.swift second()")
        )
        #expect(!laneOutput.contains("held_step_unarrived name=gate A"))
        #expect(unarrivedRange.lowerBound < reapRange.lowerBound)
        #expect(laneOutput.contains("lane-report fact_expected id=child-1 expected=refreshClosed scope=worktree-1"))
        #expect(missingFactRange.lowerBound < reapRange.lowerBound)
        // Dump, held-step log and ledger share one stem, side by side.
        #expect(evidenceStem.hasPrefix("lane-evidence-probe-"))
        #expect(!taskDumps.isEmpty)
        #expect(taskDumps.allSatisfy { $0.hasPrefix(evidenceStem + "-pid") })
        #expect(evidenceFiles.contains(heldStepLog))
        #expect(evidenceFiles.contains(evidenceStem + ".timing.json"))
        let timingData = try Data(
            contentsOf: URL(fileURLWithPath: evidenceDirectory + "/" + evidenceStem + ".timing.json"))
        let timingRecord = try #require(JSONSerialization.jsonObject(with: timingData) as? [String: Any])
        #expect(timingRecord["timed_out"] as? Bool == true)
        #expect(laneOutput.contains("lane-report task_dump=\(evidenceDirectory)/\(evidenceStem)-pid"))
        let firstDump = try String(
            contentsOfFile: evidenceDirectory + "/" + (try #require(taskDumps.first)),
            encoding: .utf8
        )
        #expect(firstDump.contains("parkForever()"))
        // Every file the hang left is one the CI failure upload selects.
        #expect(uploadGlobs.count == 3)
        for evidenceFile in evidenceFiles where !evidenceFile.hasSuffix(".timing.json") {
            #expect(
                uploadGlobs.contains { fnmatch($0, evidenceFile, 0) == 0 },
                "\(evidenceFile) is not selected by the CI upload globs \(uploadGlobs)"
            )
        }
    }

    @Test("held-step waits are paired to arrivals by instance id, and a missing or empty log prints nothing")
    func heldStepWaitsArePairedToArrivalsByInstanceID() async throws {
        let logDirectory = NSTemporaryDirectory() + "agentstudio-receipt-held-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: logDirectory) }

        // TAB-separated, as the harness writes it; step names contain spaces.
        // step-2 arrives before its wait is even logged, and shares its name with
        // step-1, which never arrives: pairing by name would let step-2's arrival
        // settle step-1's wait and hide the one step that is actually stuck.
        let report = try await laneBash(
            "mkdir -p '\(logDirectory)'; "
                + "printf 'waiting\\tstep-1\\tsocket stop gate\\tListenerTests.swift one()\\n"
                + "arrived\\tstep-2\\tsocket stop gate\\n"
                + "waiting\\tstep-2\\tsocket stop gate\\tListenerTests.swift two()\\n"
                + "waiting\\tstep-3\\tpane focus\\tFocusTests.swift three()\\n"
                + "arrived\\tstep-3\\tpane focus\\n"
                + "waiting\\tstep-4\\tbridge retire\\tBridgeTests.swift four()\\n' > '\(logDirectory)/held.log'; "
                + ": > '\(logDirectory)/empty.log'; "
                + "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; "
                + "print_held_steps_unarrived_at_timeout '\(logDirectory)/held.log'; echo MISSING:; "
                + "print_held_steps_unarrived_at_timeout '\(logDirectory)/absent.log'; echo EMPTY:; "
                + "print_held_steps_unarrived_at_timeout '\(logDirectory)/empty.log'; echo UNSET:; "
                + "print_held_steps_unarrived_at_timeout ''"
        )

        #expect(
            laneOutputLines(report) == [
                "[lane] lane-report held_step_unarrived name=socket stop gate id=step-1 test=ListenerTests.swift one()",
                "[lane] lane-report held_step_unarrived name=bridge retire id=step-4 test=BridgeTests.swift four()",
                "MISSING:",
                "EMPTY:",
                "UNSET:",
            ]
        )
    }

    @Test("expectation parser handles early settlements, duplicate lines and a partial final record")
    func expectationParserIgnoresSettledAndPartialRecords() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-receipt-facts-\(UUIDv7.generate()).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        try """
        settled\tchild-2\tmatched
        expecting\tchild-2\talreadyClosed\tscope\tSuite.swift done()\tSuite.swift:3 done()
        expecting\tchild-1\trefreshClosed\tscope\tSuite.swift pending()\tSuite.swift:4 pending()
        expecting\tchild-1\trefreshClosed\tscope\tSuite.swift pending()\tSuite.swift:4 pending()
        """.appending("expecting\tchild-3\tpartial\tscope\tSuite.swift pending()\tFile:5")
            .write(to: logURL, atomically: true, encoding: .utf8)

        let report = try await laneBash(
            "LOG_PREFIX=lane; source scripts/swift-test-helpers.sh; "
                + "print_held_steps_unarrived_at_timeout '\(logURL.path)'"
        )

        #expect(
            laneOutputLines(report) == [
                "[lane] lane-report fact_expected id=child-1 expected=refreshClosed scope=scope "
                    + "test=Suite.swift pending() site=Suite.swift:4 pending()"
            ])
    }

    @Test("the timeout report names an unavailable log before reaping the child")
    func unavailableLogAppearsBeforeReap() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-unavailable-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)
        try """
        echo '[agentstudio-test-log] unavailable path=/missing/events.log errno=2' >&2
        touch "$LANE_WATCHDOG_ARM_PATH"
        while true; do sleep 1; done

        """.write(toFile: workDirectory + "/wedged-test.sh", atomically: true, encoding: .utf8)

        let report = try await laneBashAllowingFailure(
            "LOG_PREFIX=lane; TIMEOUT_SECONDS=0; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "export LANE_WATCHDOG_ARM_PATH='\(workDirectory)/armed'; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'unavailable probe' 0 /bin/bash '\(workDirectory)/wedged-test.sh' "
                + "AgentStudioPackageTests || returned=$?; echo \"RETURNED=${returned:-0}\""
        )
        let unavailableRange = try #require(report.range(of: "lane-report held_step_log_unavailable"))
        let reapRange = try #require(report.range(of: "lane-report timeout_reap="))
        #expect(report.contains("RETURNED=124"))
        #expect(unavailableRange.lowerBound < reapRange.lowerBound)
    }

    @Test("a missing stack sampler does not cost the task dump, and each missing tool says why")
    func missingStackSamplerDoesNotCostTheTaskDump() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-nosample-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        for (toolDirectory, fakeInspector) in [
            ("attaching", "echo TASKS; echo \"  Task 1 async backtrace: parkForever()\""),
            ("refusing", "echo \"unable to get task for pid $3: (os/kern) failure 0x5\" >&2"),
        ] {
            try FileManager.default.createDirectory(
                atPath: workDirectory + "/" + toolDirectory,
                withIntermediateDirectories: true
            )
            try "#!/bin/bash\n\(fakeInspector)\n"
                .write(toFile: workDirectory + "/\(toolDirectory)/xcrun", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: workDirectory + "/\(toolDirectory)/xcrun"
            )
        }
        func wedgedLane(inspectorDirectory: String) -> String {
            "LOG_PREFIX=lane; TIMEOUT_SECONDS=0; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/\(inspectorDirectory)-runs'; "
                + "export LANE_STACK_SAMPLE_TOOL='\(workDirectory)/no-such-sample'; "
                + "export PATH='\(workDirectory)/\(inspectorDirectory)':$PATH; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'no sample probe' 0 /bin/bash -c 'while true; do sleep 1; done' "
                + "AgentStudioPackageTests || returned=$?; echo \"RETURNED=${returned:-0}\"; "
                + "echo \"DUMPS=$(ls -1 '\(workDirectory)/\(inspectorDirectory)-runs' | grep -c task-dump || true)\""
        }

        let samplerMissing = try await laneBashAllowingFailure(wedgedLane(inspectorDirectory: "attaching"))
        let bothMissing = try await laneBashAllowingFailure(wedgedLane(inspectorDirectory: "refusing"))

        for laneOutput in [samplerMissing, bothMissing] {
            #expect(laneOutput.contains("RETURNED=124"))
            #expect(
                laneOutput.contains(
                    "lane-report stack_sample=unavailable pid="
                ) && laneOutput.contains("reason=\(workDirectory)/no-such-sample is not executable")
            )
        }
        // The sampler was missing, and the dump was still taken and kept.
        #expect(samplerMissing.contains("lane-report task_dump=\(workDirectory)/attaching-runs/lane-no-sample-probe-"))
        #expect(!samplerMissing.contains("DUMPS=0"))
        // With both tools unavailable, both say why, and the hang is still red.
        #expect(bothMissing.contains("lane-report task_dump=unavailable pid="))
        #expect(bothMissing.contains("reason=unable to get task for pid"))
        #expect(bothMissing.contains("DUMPS=0"))
    }

    @Test("retention keeps whole evidence stems, newest first, and an empty held-step log never holds a slot")
    func retentionKeepsWholeEvidenceStems() async throws {
        // Seven stems of one label. The newest real run (…000006) is a hang
        // that left a ledger, three task dumps and an empty held-step log;
        // the older runs left a ledger and one dump each, and …000002 also a
        // non-empty held-step log. …000007 is only an empty held-step log from
        // a run that never got further, so it is not evidence. Retention keeps
        // 5 stems: counted per kind, the three newest dumps would evict the
        // dumps of runs whose ledgers are kept, and the empty logs would count.
        let evidenceDirectory = NSTemporaryDirectory() + "agentstudio-receipt-retention-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: evidenceDirectory) }
        let stemPrefix = "lane-retention-probe-20260924T00000"
        var seededFiles: [(name: String, contents: String)] = []
        for stemNumber in 1...5 {
            seededFiles.append(("\(stemPrefix)\(stemNumber)-100.events.jsonl", "ledger"))
            seededFiles.append(("\(stemPrefix)\(stemNumber)-100.timing.json", "{}"))
            seededFiles.append(("\(stemPrefix)\(stemNumber)-100-pid\(stemNumber)0.task-dump.txt", "TASKS"))
        }
        seededFiles.append(("\(stemPrefix)2-100.held-steps.log", "waiting\tstep-1\tgate\tSuite.swift one()"))
        seededFiles.append(("\(stemPrefix)6-100.events.jsonl", "ledger"))
        seededFiles.append(("\(stemPrefix)6-100.timing.json", "{}"))
        for dumpedPid in [61, 62, 63] {
            seededFiles.append(("\(stemPrefix)6-100-pid\(dumpedPid).task-dump.txt", "TASKS"))
        }
        seededFiles.append(("\(stemPrefix)6-100.held-steps.log", ""))
        seededFiles.append(("\(stemPrefix)7-100.held-steps.log", ""))
        // Another label whose slug merely starts with this one is not this label's.
        seededFiles.append(("lane-retention-probe-extra-20260924T000009-100.events.jsonl", "ledger"))
        try FileManager.default.createDirectory(atPath: evidenceDirectory, withIntermediateDirectories: true)
        for seededFile in seededFiles {
            try seededFile.contents.write(
                toFile: evidenceDirectory + "/" + seededFile.name,
                atomically: true,
                encoding: .utf8
            )
        }

        // Modification times follow the timestamps in the names, as a real run's would.
        _ = try await laneBash(
            "for evidence_file in '\(evidenceDirectory)'/lane-*; do "
                + "stamp=$(basename \"$evidence_file\" | grep -Eo '20260924T[0-9]{6}'); "
                + "touch -t \"$(printf '%s' \"$stamp\" | sed -E 's/^(........)T(....)(..)$/\\1\\2.\\3/')\" "
                + "\"$evidence_file\"; done"
        )
        let pruned = try await laneBash(
            "export LANE_EVENT_STREAM_DIR='\(evidenceDirectory)' LANE_EVENT_STREAM_KEEP_PER_LABEL=5 "
                + "LANE_EVENT_STREAM_RETAIN_ALWAYS=0; "
                + "source scripts/swift-test-helpers.sh; set -euo pipefail; "
                + "prune_lane_event_streams retention-probe; echo PRUNE_STATUS=$?"
        )
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory).sorted()
        let expectedFiles =
            seededFiles.map(\.name)
            .filter { name in
                !name.hasPrefix("\(stemPrefix)1-") && !name.hasPrefix("\(stemPrefix)7-")
            }
            .sorted()

        #expect(pruned.contains("PRUNE_STATUS=0"))
        // Stems …2 through …6 survive whole: every ledger, every dump and the
        // non-empty held-step log. The oldest stem is gone, and so is the stem
        // made only of an empty held-step log, which never took a slot.
        #expect(remainingFiles == expectedFiles)
        _ = try await laneBash(
            "export LANE_EVENT_STREAM_DIR='\(evidenceDirectory)' LANE_EVENT_STREAM_KEEP_PER_LABEL=1 "
                + "LANE_EVENT_STREAM_RETAIN_ALWAYS=1; "
                + "source scripts/swift-test-helpers.sh; prune_lane_event_streams retention-probe"
        )
        let retainedFiles = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory).sorted()
        #expect(retainedFiles == expectedFiles)
    }

    @Test("a failed retention check cannot remove a member of any kept evidence stem", arguments: ["grep", "sort"])
    func failedRetentionCheckKeepsEveryStemMember(failingCommand: String) async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-retention-failure-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let evidenceDirectory = fixtureRoot.appendingPathComponent("evidence")
        let shimDirectory = fixtureRoot.appendingPathComponent("shims")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        var expectedFiles: [String] = []
        for stemNumber in 2...6 {
            let stem = "lane-retention-probe-20260924T00000\(stemNumber)-100"
            for suffix in [".events.jsonl", ".timing.json", "-pid\(stemNumber)0.task-dump.txt"] {
                let name = stem + suffix
                try "evidence".write(
                    to: evidenceDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                expectedFiles.append(name)
            }
        }
        // No discarded stem comes first: the third grep call checks kept stem2's timing file.
        let grepShim = """
            #!/bin/bash
            invocation=0
            if [[ -f "$GREP_INVOCATION_COUNTER" ]]; then
              IFS= read -r invocation < "$GREP_INVOCATION_COUNTER"
            fi
            invocation=$((invocation + 1))
            printf '%s\\n' "$invocation" > "$GREP_INVOCATION_COUNTER"
            if [[ "$invocation" -eq 3 ]]; then
              echo GREP_FAILURE=3 >&2
              exit 2
            fi
            exec /usr/bin/grep "$@"
            """
        // A pipeline may emit a plausible partial set and still fail; do not use that set to delete.
        let sortShim = """
            #!/bin/bash
            printf '%s\\n' 'lane-retention-probe-20260924T000006-100'
            exit 2
            """
        let shimURL = shimDirectory.appendingPathComponent(failingCommand)
        try (failingCommand == "grep" ? grepShim : sortShim).write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)
        let output = try await laneBash(
            "export LANE_EVENT_STREAM_DIR='\(evidenceDirectory.path)' LANE_EVENT_STREAM_KEEP_PER_LABEL=5 "
                + "LANE_EVENT_STREAM_RETAIN_ALWAYS=0 GREP_INVOCATION_COUNTER='\(fixtureRoot.path)/grep-counter'; "
                + "source scripts/swift-test-helpers.sh; set -euo pipefail; "
                + "PATH='\(shimDirectory.path)':$PATH prune_lane_event_streams retention-probe; echo PRUNE_STATUS=$?"
        )
        #expect(output.contains("PRUNE_STATUS=0"))
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory.path).sorted()
        #expect(remainingFiles == expectedFiles.sorted(), Comment(rawValue: output))
    }

    @Test("a task dump is kept beside the ledger, and a refused attach is recorded with its reason")
    func taskDumpIsKeptBesideLedgerAndRefusalIsRecorded() async throws {
        // swift-inspect exits 0 when it cannot attach, printing only to stderr, so
        // both fakes exit 0 and only the dump's content tells them apart.
        let workDirectory = NSTemporaryDirectory() + "agentstudio-receipt-inspect-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        let attachingTool = workDirectory + "/attaching"
        let refusingTool = workDirectory + "/refusing"
        let fakeInspectors =
            "mkdir -p '\(attachingTool)' '\(refusingTool)'; "
            + "printf '#!/bin/bash\\necho TASKS; echo \"  Task 1 async backtrace: parkForever()\"\\n' "
            + "> '\(attachingTool)/xcrun'; "
            + "printf '#!/bin/bash\\necho \"unable to get task for pid $3: (os/kern) failure 0x5\" >&2; "
            + "echo \"Failed to create inspector for process id $3\" >&2\\n' > '\(refusingTool)/xcrun'; "
            + "chmod +x '\(attachingTool)/xcrun' '\(refusingTool)/xcrun'; "

        let attached = try await laneBash(
            fakeInspectors
                + "LOG_PREFIX=lane; export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "source scripts/swift-test-helpers.sh; "
                + "PATH='\(attachingTool)':$PATH dump_stuck_swift_test_process_tasks 'dump probe' 4242; "
                + "for dump in '\(workDirectory)/ci-runs'/*.task-dump.txt; do cat \"$dump\"; done"
        )
        let refused = try await laneBash(
            fakeInspectors
                + "LOG_PREFIX=lane; export LANE_EVENT_STREAM_DIR='\(workDirectory)/refused-runs'; "
                + "source scripts/swift-test-helpers.sh; "
                + "PATH='\(refusingTool)':$PATH dump_stuck_swift_test_process_tasks 'dump probe' 4242; "
                + "echo \"DUMPS=$(ls -1 '\(workDirectory)/refused-runs' | wc -l | tr -d '[:space:]')\""
        )

        #expect(attached.contains("lane-report task_dump=\(workDirectory)/ci-runs/lane-dump-probe-"))
        #expect(attached.contains("-pid4242.task-dump.txt"))
        #expect(attached.contains("parkForever()"))
        #expect(
            refused.contains(
                "lane-report task_dump=unavailable pid=4242 reason=unable to get task for pid 4242: "
                    + "(os/kern) failure 0x5 Failed to create inspector for process id 4242"
            )
        )
        // A refused attach leaves no empty file posing as a dump.
        #expect(refused.contains("DUMPS=0"))
    }
}

/// The file-name globs the CI failure upload selects under the ledger directory.
private func ciUploadedEvidenceGlobs() throws -> [String] {
    let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
    let uploadStep = try laneScriptNamedBlock(
        startingWith: "      - name: Upload wedged-lane event-stream ledgers",
        endingBefore: "\n      - name: ",
        in: ciWorkflow
    )
    let ledgerDirectoryPrefix = "tmp/plan-workflows/ci-runs/"
    return uploadStep.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix(ledgerDirectoryPrefix) }
        .map { String($0.dropFirst(ledgerDirectoryPrefix.count)) }
}
