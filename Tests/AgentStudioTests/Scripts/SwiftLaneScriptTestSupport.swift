import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

/// The outcome of one bash command run by a Swift lane runner test.
struct LaneScriptBashResult: Sendable {
    let exitCode: Int32
    let output: String
}

/// Whether a lane fixture's own `run_swift_with_timeout` watchdog may fire.
///
/// The outer lane owns the hang bound for every test. A fixture whose subject is
/// not inactivity runs unarmed, so a loaded host that starves the runner's own
/// work cannot turn a command that already exited into a timeout (TQ14). A test
/// whose subject is the watchdog, an inactivity timeout, a timeout reap or a
/// heartbeat passes `.armed` at its call site.
enum LaneFixtureInnerWatchdog: Sendable {
    case unarmed
    case armed

    /// Shell run before the fixture command. It reaches runner calls in the
    /// launched shell and its subshells; it is not exported, so a fixture that
    /// starts the runner in a separate bash process sets that process itself.
    var shellPreamble: String {
        switch self {
        case .unarmed:
            // An arm path that never exists: no process can add entries to /var/empty.
            "LANE_WATCHDOG_ARM_PATH=/var/empty/agentstudio-lane-fixture-watchdog-unarmed\n"
        case .armed:
            "unset LANE_WATCHDOG_ARM_PATH\n"
        }
    }
}

let swiftTaskParentEnvironmentProbe = """
    for inherited_variable in $(compgen -e); do
      case "$inherited_variable" in
        LANE_*|SWIFT_TEST_*|SWIFT_BUILD_*|AGENTSTUDIO_HELD_STEP_LOG)
          echo "PARENT_ENV_INHERITED=$inherited_variable"
          ;;
      esac
    done
    """

func swiftTaskFixtureEnvironment() -> [String: String] {
    var environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
    for name in ["TMPDIR", "DEVELOPER_DIR"] {
        if let value = ProcessInfo.processInfo.environment[name] {
            environment[name] = value
        }
    }
    return environment
}

func loadSwiftLaneRunnerReportingSource() throws -> String {
    try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        + "\n" + String(contentsOfFile: "scripts/swift-test-lane-report.sh", encoding: .utf8)
}

/// Runs one bash command from the repository root with stdout and stderr merged.
///
/// The child is awaited off the cooperative pool: on a 3-core CI runner a
/// blocking wait here would starve every other suite's tasks.
func runLaneScriptBash(
    _ command: String, environment: [String: String]? = nil, innerWatchdog: LaneFixtureInnerWatchdog = .unarmed
) async throws -> LaneScriptBashResult {
    try await withoutBlockingCooperativePool {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "swift-lane-runner-output-\(UUIDv7.generate().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", innerWatchdog.shellPreamble + command]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.environment = testProcessEnvironmentWithoutRelayPaths(environment)
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        return LaneScriptBashResult(
            exitCode: process.terminationStatus,
            output: try String(contentsOf: outputURL, encoding: .utf8)
        )
    }
}

/// Shell, sourced after the lane helpers, that replaces a loaded host's timing
/// with a handshake for a fixture that runs the real lane runner.
///
/// The watchdog takes its first sample only after the command's output has
/// reached EOF while the runner's own drain still holds the command's process
/// group open, and that sample reports the whole inactivity bound as elapsed.
/// A loaded host produced this ordering (TQ14): only runner-owned processes were
/// left in the group, so an armed inner watchdog read an exited command as a
/// timeout. Under the launchers' `.unarmed` default the verdict holds; an
/// `.armed` fixture reports the timeout. The next sample releases the drain.
func laneRunnerStarvedDrainHook(fifoDirectory: String) -> String {
    #"""
    mkfifo '\#(fifoDirectory)/starved-drain-held' '\#(fifoDirectory)/starved-drain-release'
    export LANE_STARVED_DRAIN_HELD='\#(fifoDirectory)/starved-drain-held'
    export LANE_STARVED_DRAIN_RELEASE='\#(fifoDirectory)/starved-drain-release'
    # Read-write opens return at once, so no side of the handshake blocks in open.
    exec 81<>"$LANE_STARVED_DRAIN_HELD" 82<>"$LANE_STARVED_DRAIN_RELEASE"
    lane_starved_drain() {
      _xcb_pipe
      printf 'DRAIN_HELD\n' >"$LANE_STARVED_DRAIN_HELD"
      local release_line
      IFS= read -r release_line <"$LANE_STARVED_DRAIN_RELEASE"
    }
    export -f lane_starved_drain
    _xcb_pipe_cmd() { echo lane_starved_drain; }
    swift_test_watchdog_timeout_status() { return 124; }
    lane_starved_sample=held
    sleep() {
      local handshake_line
      case "$lane_starved_sample" in
        held) IFS= read -r handshake_line <&81; lane_starved_sample=release ;;
        release) printf 'RELEASE\n' >&82; lane_starved_sample=runner ;;
        *) /bin/sleep "$@" ;;
      esac
    }

    """#
}

/// The body of one `name() {` shell function, up to its closing brace.
func laneScriptShellFunction(named functionName: String, in script: String) throws -> String {
    try laneScriptNamedBlock(startingWith: "\(functionName)() {", endingBefore: "\n}\n", in: script)
}

/// The text from `marker` up to (not including) the next `terminator`, or to the end.
func laneScriptNamedBlock(startingWith marker: String, endingBefore terminator: String, in text: String) throws
    -> String
{
    guard let startRange = text.range(of: marker) else {
        throw LaneScriptTestError.missingBlock(marker)
    }
    let tail = text[startRange.lowerBound...]
    guard let endRange = tail.range(of: terminator, range: tail.index(after: startRange.lowerBound)..<tail.endIndex)
    else {
        return String(tail)
    }
    return String(tail[..<endRange.lowerBound])
}

enum LaneScriptTestError: Error {
    case missingBlock(String)
}

/// The non-empty lines of a script's output.
func laneOutputLines(_ output: String) -> [String] {
    output.split(separator: "\n").map(String.init)
}

/// Runs a lane script command that must succeed, and returns its output.
func laneBash(
    _ command: String, environment: [String: String]? = nil, innerWatchdog: LaneFixtureInnerWatchdog = .unarmed
) async throws -> String {
    let result = try await runLaneScriptBash(command, environment: environment, innerWatchdog: innerWatchdog)
    #expect(result.exitCode == 0, Comment(rawValue: result.output))
    return result.output
}

/// For scripts that deliberately fail: these tests drive crashing and hung
/// children, so a non-zero status is the expected outcome.
func laneBashAllowingFailure(
    _ command: String, environment: [String: String]? = nil, innerWatchdog: LaneFixtureInnerWatchdog = .unarmed
) async throws -> String {
    (try await runLaneScriptBash(command, environment: environment, innerWatchdog: innerWatchdog)).output
}
