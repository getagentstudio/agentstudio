import AgentStudioInfrastructure
import Foundation
import Testing

@Suite("Swift lane watchdog-state cleanup")
struct SwiftLaneWatchdogStateTests {
    @Test(
        "watchdog-state failure reaps its child before publishing the timing sidecar",
        arguments: [false, true])
    func watchdogStateFailureReapsBeforeSidecar(holdBeforeIdentity: Bool) async throws {
        let evidenceDirectory = NSTemporaryDirectory() + "agentstudio-watchdog-state-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: evidenceDirectory) }
        let childPIDFile = evidenceDirectory + "/child.pid"
        let blockedFIFO = evidenceDirectory + "/blocked.fifo"
        let startupFIFO = evidenceDirectory + "/startup.fifo"
        let startupReady = evidenceDirectory + "/startup.ready"
        let watchdogArm = evidenceDirectory + "/watchdog.arm"
        let command = #"""
            mkdir -p '__EVIDENCE__'
            mkfifo '__FIFO__'
            mkfifo '__STARTUP_FIFO__'
            LOG_PREFIX=watchdog-state
            LANE_EVENT_STREAM_DIR='__EVIDENCE__'
            export LANE_WATCHDOG_ARM_PATH='__ARM__'
            source scripts/swift-test-helpers.sh
            # The runner calls this before its inactivity-arm check. Only inject
            # failure after the child has closed its PID write and announced it.
            swift_test_watchdog_state() {
              if [ ! -e "$LANE_WATCHDOG_ARM_PATH" ]; then
                if [ '__HOLD__' = 1 ] && [ -e '__STARTUP_READY__' ] && \
                    [ ! -e '__STARTUP_READY__.released' ]; then
                  printf 'start\n' > '__STARTUP_FIFO__'
                  : > '__STARTUP_READY__.released'
                fi
                printf '%s %s\n' "$2" "$4"
                return 0
              fi
              return 1
            }
            status=0
            run_swift_with_timeout 'watchdog state probe' 60 /bin/bash -c \
              'if [ "$3" = 1 ]; then
                 : > "$4"
                 read -r startup < "$5"
               fi
               echo "$$" > "$1"
               : > "$LANE_WATCHDOG_ARM_PATH"
               read -r blocked < "$2"' \
              bash '__PID__' '__FIFO__' '__HOLD__' '__STARTUP_READY__' '__STARTUP_FIFO__' || status=$?
            echo STATUS=$status
            if read -r child_pid < '__PID__' && ! kill -0 "$child_pid" 2>/dev/null; then
              echo CHILD_REAPED
            else
              echo CHILD_SURVIVED
              kill -KILL "$child_pid" 2>/dev/null || true
              for job_pid in $(jobs -pr); do
                terminate_lane_child_tree KILL "$job_pid"
                wait "$job_pid" 2>/dev/null || true
              done
            fi
            """#
            .replacingOccurrences(of: "__EVIDENCE__", with: evidenceDirectory)
            .replacingOccurrences(of: "__PID__", with: childPIDFile)
            .replacingOccurrences(of: "__FIFO__", with: blockedFIFO)
            .replacingOccurrences(of: "__STARTUP_FIFO__", with: startupFIFO)
            .replacingOccurrences(of: "__STARTUP_READY__", with: startupReady)
            .replacingOccurrences(of: "__ARM__", with: watchdogArm)
            .replacingOccurrences(of: "__HOLD__", with: holdBeforeIdentity ? "1" : "0")
        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("STATUS=1"))
        #expect(result.output.contains("CHILD_REAPED"))
        #expect(FileManager.default.fileExists(atPath: watchdogArm))
        if holdBeforeIdentity {
            #expect(FileManager.default.fileExists(atPath: startupReady + ".released"))
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory)
        let sidecarName = try #require(files.first { $0.hasSuffix(".timing.json") })
        let sidecarURL = URL(fileURLWithPath: evidenceDirectory + "/" + sidecarName)
        let data = try Data(contentsOf: sidecarURL)
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wrapperComplete = try #require(record["wrapper_complete_ms"] as? Int)
        if let commandExit = record["command_exit_ms"] as? Int {
            #expect(wrapperComplete >= commandExit)
        } else {
            #expect(record["command_exit_ms"] is NSNull)
        }
    }
}
