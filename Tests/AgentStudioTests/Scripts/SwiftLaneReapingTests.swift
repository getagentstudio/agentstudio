import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Swift lane process-group reaping")
struct SwiftLaneReapingTests {
    @Test("a timed out child that ignores TERM is still reaped, and the report is still written")
    func timedOutChildThatIgnoresTermIsStillReaped() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-s2e-reap-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        let laneOutput = try await runBashAllowingFailure(
            "mkdir -p '\(workDirectory)/bin'; "
                + "printf '#!/bin/sh\\nexit 126\\n' >'\(workDirectory)/bin/ps'; "
                + "printf '#!/bin/sh\\nexit 3\\n' >'\(workDirectory)/bin/pgrep'; "
                + "chmod +x '\(workDirectory)/bin/ps' '\(workDirectory)/bin/pgrep'; "
                + "mkfifo '\(workDirectory)/child.release'; "
                + "PATH='\(workDirectory)/bin':\"$PATH\"; export PATH; "
                + "LOG_PREFIX=lane; TIMEOUT_SECONDS=2; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'reap probe' 2 /usr/bin/perl -MFcntl=:flock -e "
                + #"'$SIG{TERM} = "IGNORE"; $| = 1; "#
                + #"open(my $lock, ">>", shift) or die $!; flock($lock, LOCK_EX) or die $!; "#
                + #"open(my $pid_file, ">", shift) or die $!; print {$pid_file} "$$\n"; close($pid_file); "#
                + #"print "LOCK_HELD\n"; open(my $release, "<", shift) or die $!; <$release>;' "#
                + "'\(workDirectory)/child.lock' '\(workDirectory)/child.pid' "
                + "'\(workDirectory)/child.release' "
                + "|| returned=$?; echo \"RETURNED=${returned:-0}\"; "
                + "child_pid=$(cat '\(workDirectory)/child.pid' 2>/dev/null || echo 0); "
                + "echo \"CHILD_PID=${child_pid:-0}\"; "
                + "if [ \"$child_pid\" -gt 0 ] && kill -0 \"$child_pid\" 2>/dev/null; then "
                + "echo CHILD_ALIVE=yes; child_alive=yes; "
                + "else echo CHILD_ALIVE=no; child_alive=no; fi; "
                + "if /usr/bin/perl -MFcntl=:flock -e "
                + #"'open(my $lock, ">>", shift) or die $!; flock($lock, LOCK_EX|LOCK_NB) or exit 7; print "LOCK_ACQUIRED\n";' "#
                + "'\(workDirectory)/child.lock'; then echo LOCK_AVAILABLE=yes; "
                + "else echo LOCK_AVAILABLE=no; fi; "
                + "if [ \"$child_alive\" = yes ]; then kill -9 \"$child_pid\" 2>/dev/null || true; fi"
        )

        #expect(!laneOutput.contains("CHILD_PID=0"))
        #expect(laneOutput.contains("LOCK_HELD"))
        #expect(
            laneOutput.contains("process listing unavailable in this environment; reaping by process group")
        )
        #expect(laneOutput.contains("CHILD_ALIVE=no"))
        // One immediate nonblocking probe checks the same flock primitive SwiftPM uses.
        #expect(laneOutput.contains("LOCK_AVAILABLE=yes"))
        #expect(laneOutput.contains("timeout_reap=killed"))
        #expect(laneOutput.contains("ERROR: no output progress from 'reap probe'"))
        #expect(laneOutput.contains("RETURNED=124"))
    }

    @Test("a grandchild that outlives its parent is still reaped")
    func grandchildThatOutlivesItsParentIsStillReaped() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-s2e-orphan-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        let laneOutput = try await runBashAllowingFailure(
            "mkdir -p '\(workDirectory)'; mkfifo '\(workDirectory)/orphan.release'; "
                + "LOG_PREFIX=lane; TIMEOUT_SECONDS=2; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'orphan probe' 2 /bin/bash -c "
                + #"'( exec /usr/bin/perl -e "\$SIG{TERM} = q{IGNORE}; open(my \$release, q{<}, shift) or die \$!; <\$release>;" "\#(workDirectory)/orphan.release" ) & "#
                + "echo $! > '\(workDirectory)/orphan.pid'; exit 0' "
                + "|| returned=$?; echo \"RETURNED=${returned:-0}\"; "
                + "orphan_pid=$(cat '\(workDirectory)/orphan.pid' 2>/dev/null || echo 0); "
                + "echo \"ORPHAN_PID=${orphan_pid:-0}\"; "
                + "if [ \"${orphan_pid:-0}\" -gt 0 ] && kill -0 \"$orphan_pid\" 2>/dev/null; then "
                + "echo ORPHAN_ALIVE=yes; kill -9 \"$orphan_pid\" 2>/dev/null; "
                + "else echo ORPHAN_ALIVE=no; fi"
        )

        #expect(!laneOutput.contains("ORPHAN_PID=0"))
        #expect(laneOutput.contains("ORPHAN_ALIVE=no"))
        #expect(laneOutput.contains("timeout_reap=killed"))
        #expect(laneOutput.contains("RETURNED=124"))
    }

    @Test("a wedged run keeps its event-stream ledger, and a clean run does not")
    func wedgedRunKeepsItsEventStreamLedger() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-s2e-ledger-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        let ledgerDirectory = workDirectory + "/ci-runs"
        let ledgerWorkerPIDFile = workDirectory + "/ledger-worker.pid"
        let wedgedOutput = try await runBashAllowingFailure(
            "mkdir -p '\(workDirectory)'; mkfifo '\(ledgerWorkerPIDFile).release'; "
                + "LOG_PREFIX=lane; TIMEOUT_SECONDS=2; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(ledgerDirectory)'; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + "run_swift_with_timeout 'ledger probe' 2 /bin/bash -c "
                + #"'printf "%s\\n" "$$" > "$0"; "#
                + #"while [ "$#" -gt 0 ]; do if [ "$1" = "--event-stream-output-path" ]; "#
                + #"then printf "%s\\n" LEDGER_RECORD_ONE LEDGER_RECORD_TWO > "$2"; fi; shift; done; "#
                + #"read -r release < "$0.release"' "#
                + "'\(ledgerWorkerPIDFile)' "
                + "|| returned=$?; echo \"RETURNED=${returned:-0}\"; "
                + "for ledger in '\(ledgerDirectory)'/*.events.jsonl; do "
                + "echo \"LEDGER_AT=$ledger\"; cat \"$ledger\"; done; "
                + "ledger_worker_pid=$(cat '\(ledgerWorkerPIDFile)' 2>/dev/null || echo 0); "
                + "echo \"LEDGER_WORKER_PID=${ledger_worker_pid:-0}\"; "
                + "if [ \"${ledger_worker_pid:-0}\" -gt 0 ] && kill -0 \"$ledger_worker_pid\" 2>/dev/null; then "
                + "echo LEDGER_WORKER_ALIVE=yes; kill -KILL \"$ledger_worker_pid\" 2>/dev/null; "
                + "else echo LEDGER_WORKER_ALIVE=no; fi"
        )

        #expect(!wedgedOutput.contains("LEDGER_WORKER_PID=0"))
        #expect(wedgedOutput.contains("RETURNED=124"))
        #expect(wedgedOutput.contains("lane-report event_stream=\(ledgerDirectory)/lane-ledger-probe-"))
        #expect(wedgedOutput.contains("LEDGER_RECORD_ONE"))
        #expect(wedgedOutput.contains("LEDGER_RECORD_TWO"))
        #expect(wedgedOutput.contains("LEDGER_WORKER_ALIVE=no"))

        let cleanDirectory = workDirectory + "/clean-runs"
        let cleanOutput = try await runBash(
            "LOG_PREFIX=lane; TIMEOUT_SECONDS=60; BUILD_PATH=.build-agent-1; "
                + "export LANE_EVENT_STREAM_DIR='\(cleanDirectory)' LANE_EVENT_STREAM_RETAIN_ALWAYS=0; "
                + "source scripts/swift-test-helpers.sh; "
                + "run_swift_with_timeout 'clean probe' 60 /bin/bash -c 'echo CLEAN_RUN_OK'; "
                + "echo \"LEDGERS=$(find '\(cleanDirectory)' -name '*.events.jsonl' | wc -l | tr -d '[:space:]')\"; "
                + "echo \"TIMINGS=$(find '\(cleanDirectory)' -name '*.timing.json' | wc -l | tr -d '[:space:]')\""
        )

        #expect(cleanOutput.contains("CLEAN_RUN_OK"))
        #expect(cleanOutput.contains("LEDGERS=0"))
        #expect(cleanOutput.contains("TIMINGS=1"))
    }

    @Test("the lane INT trap reaches an active command group")
    func laneINTTrapReachesAnActiveCommandGroup() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-lane-int-group-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let signalTrap = try shellFunction(named: "trap_lane_termination_signals", in: laneRunnerScript)
        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            \#(signalTrap)
            }
            fixture_dir='\#(workDirectory)'
            mkdir -p "$fixture_dir/groups"
            mkfifo "$fixture_dir/ready" "$fixture_dir/release"
            exec 8<>"$fixture_dir/ready"
            exec 9<>"$fixture_dir/release"
            export SWIFT_TEST_ACTIVE_COMMAND_GROUPS_DIR="$fixture_dir/groups"
            group_pid=""
            cleanup_int_fixture() {
              printf 'RELEASE\n' >&9 || true
              if [ -n "$group_pid" ]; then
                wait "$group_pid" 2>/dev/null || true
                swift_test_unregister_active_command_group "$group_pid"
              fi
              if [ -f "$fixture_dir/int-received" ]; then
                echo INT_FORWARDED=yes
              else
                echo INT_FORWARDED=no
              fi
            }
            trap cleanup_int_fixture EXIT
            trap_lane_termination_signals
            LOG_PREFIX=int-forward-probe
            swift_test_launch_command_group /usr/bin/perl -e '
                $| = 1;
                my ($marker, $ready_path, $release_path) = @ARGV;
                $SIG{INT} = sub {
                  open(my $marker_file, ">", $marker) or die $!;
                  print {$marker_file} "INT\n";
                  close($marker_file);
                  exit 0;
                };
                open(my $ready_file, ">", $ready_path) or die $!;
                print {$ready_file} "READY\n";
                close($ready_file);
                open(my $release_file, "<", $release_path) or die $!;
                <$release_file>;
              ' "$fixture_dir/int-received" "$fixture_dir/ready" "$fixture_dir/release"
            group_pid="$SWIFT_TEST_STARTED_COMMAND_GROUP_PID"
            read -r ready <&8
            [ "$ready" = READY ] || { echo CHILD_NOT_READY=yes; exit 97; }
            kill -INT "$$"
            """#

        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 130, Comment(rawValue: result.output))
        #expect(result.output.contains("INT_FORWARDED=yes"), Comment(rawValue: result.output))
    }

    @Test("a grouped child signal trap cannot signal its caller's active groups")
    func groupedChildSignalTrapCannotSignalCallerGroups() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-signal-group-boundary-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)

        let laneRunnerScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let signalTrap = try shellFunction(named: "trap_lane_termination_signals", in: laneRunnerScript)
        let childScriptPath = workDirectory + "/signal-child.sh"
        let childScript = """
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            \(signalTrap)
            }
            trap_lane_termination_signals
            ( kill -TERM "$$" ) &
            wait
            """
        try childScript.write(toFile: childScriptPath, atomically: true, encoding: .utf8)

        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            fixture_dir='\#(workDirectory)'
            mkdir -p "$fixture_dir/events"
            mkfifo "$fixture_dir/survivor.ready" "$fixture_dir/survivor.release"
            survivor_lock="$fixture_dir/survivor.lock"
            swift_test_begin_active_command_groups
            LOG_PREFIX=signal-group-boundary
            TIMEOUT_SECONDS=60
            BUILD_PATH=.build-agent-1
            export LANE_EVENT_STREAM_DIR="$fixture_dir/events"
            probe_survivor_lock() {
              /usr/bin/perl -MFcntl=:flock -e 'open(my $lock, ">>", shift) or die $!; flock($lock, LOCK_EX|LOCK_NB) or exit 7' "$survivor_lock"
            }
            release_survivor_group() {
              if [ -n "${survivor_pid:-}" ]; then
                lock_status=0
                probe_survivor_lock || lock_status=$?
                if [ "$lock_status" -eq 7 ]; then
                  printf 'RELEASE\n' >"$fixture_dir/survivor.release" || true
                fi
                wait "$survivor_pid" 2>/dev/null || true
                swift_test_unregister_active_command_group "$survivor_pid"
              fi
            }
            trap release_survivor_group EXIT
            swift_test_launch_command_group /usr/bin/perl -MFcntl=:flock -e '
              $| = 1;
              $SIG{HUP} = "IGNORE";
              my ($lock_path, $ready_path, $release_path) = @ARGV;
              open(my $lock, ">>", $lock_path) or die $!;
              flock($lock, LOCK_EX) or die $!;
              open(my $ready, ">", $ready_path) or die $!;
              print {$ready} "READY\n";
              close($ready);
              open(my $release, "<", $release_path) or die $!;
              <$release>;
            ' "$survivor_lock" "$fixture_dir/survivor.ready" "$fixture_dir/survivor.release"
            survivor_pid="$SWIFT_TEST_STARTED_COMMAND_GROUP_PID"
            IFS= read -r survivor_ready <"$fixture_dir/survivor.ready"
            [ "$survivor_ready" = READY ] || { echo SURVIVOR_NOT_READY=yes; exit 40; }

            signal_child_status=0
            run_swift_with_timeout 'grouped signal child' "$TIMEOUT_SECONDS" /bin/bash "$fixture_dir/signal-child.sh" || signal_child_status=$?
            echo "SIGNAL_CHILD_STATUS=$signal_child_status"
            [ "$signal_child_status" -eq 143 ] || { echo UNEXPECTED_SIGNAL_STATUS=yes; exit 41; }

            lock_status=0
            probe_survivor_lock || lock_status=$?
            if [ "$lock_status" -eq 7 ]; then
              echo OUTER_GROUP_SURVIVED=yes
              printf 'RELEASE\n' >"$fixture_dir/survivor.release"
              wait "$survivor_pid"
              swift_test_unregister_active_command_group "$survivor_pid"
              survivor_pid=""
            else
              echo OUTER_GROUP_SURVIVED=no
              exit 42
            fi
            """#

        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("SIGNAL_CHILD_STATUS=143"), Comment(rawValue: result.output))
        #expect(result.output.contains("OUTER_GROUP_SURVIVED=yes"), Comment(rawValue: result.output))
    }
}

private func shellFunction(named functionName: String, in script: String) throws -> String {
    let startMarker = "\(functionName)() {"
    guard let startRange = script.range(of: startMarker) else {
        throw SwiftLaneReapingTestError.missingFunction(startMarker)
    }
    let tail = script[startRange.lowerBound...]
    guard let endRange = tail.range(of: "\n}\n", range: tail.index(after: startRange.lowerBound)..<tail.endIndex)
    else {
        throw SwiftLaneReapingTestError.missingFunctionTerminator(functionName)
    }
    return String(tail[..<endRange.lowerBound])
}

private func runBash(_ command: String) async throws -> String {
    let result = try await runLaneScriptBash(command)
    #expect(result.exitCode == 0, Comment(rawValue: result.output))
    return result.output
}

private func runBashAllowingFailure(_ command: String) async throws -> String {
    (try await runLaneScriptBash(command)).output
}

private enum SwiftLaneReapingTestError: Error {
    case missingFunction(String)
    case missingFunctionTerminator(String)
}
