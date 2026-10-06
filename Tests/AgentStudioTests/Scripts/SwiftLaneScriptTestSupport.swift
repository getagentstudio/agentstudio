import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

/// The outcome of one bash command run by a Swift lane runner test.
struct LaneScriptBashResult: Sendable {
    let exitCode: Int32
    let output: String
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
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    for name in ["TMPDIR", "DEVELOPER_DIR"] {
        if let value = ProcessInfo.processInfo.environment[name] {
            environment[name] = value
        }
    }
    return environment
}

/// Runs one bash command from the repository root with stdout and stderr merged.
///
/// The child is awaited off the cooperative pool: on a 3-core CI runner a
/// blocking wait here would starve every other suite's tasks.
func runLaneScriptBash(_ command: String, environment: [String: String]? = nil) async throws -> LaneScriptBashResult {
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
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let environment {
            process.environment = environment
        }
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
func laneBash(_ command: String, environment: [String: String]? = nil) async throws -> String {
    let result = try await runLaneScriptBash(command, environment: environment)
    #expect(result.exitCode == 0, Comment(rawValue: result.output))
    return result.output
}

/// For scripts that deliberately fail: these tests drive crashing and hung
/// children, so a non-zero status is the expected outcome.
func laneBashAllowingFailure(_ command: String, environment: [String: String]? = nil) async throws -> String {
    (try await runLaneScriptBash(command, environment: environment)).output
}
