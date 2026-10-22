import AgentStudioTestSupport
import Foundation
import Testing

struct CLIProcessResult {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

func cliExecutableURL() throws -> URL {
    let buildDirectory = try #require(ProcessInfo.processInfo.environment["SWIFT_BUILD_DIR"])
    let testFileURL = URL(fileURLWithPath: #filePath)
    let projectRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resolvedBuildDirectory =
        buildDirectory.hasPrefix("/")
        ? URL(fileURLWithPath: buildDirectory)
        : projectRoot.appending(path: buildDirectory)
    return resolvedBuildDirectory.appending(path: "debug/agentstudio-cli")
}

/// Runs the built CLI to exit through `runProcessToExit`.
///
/// The CLI talks to an in-process `AgentStudioAppIPCServer` that answers every
/// connection from a `Task` on the cooperative pool, so the wait must not park
/// a pool thread; `runProcessToExit` suspends until the exit is delivered and
/// writes both streams to files, because `command.list` returns more than a
/// pipe buffer holds. There is no per-test time limit: the lane's hang bound is
/// the only elapsed-time bound on the child.
func runCLI(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL? = nil
) async throws -> CLIProcessResult {
    let output = try await runProcessToExit(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL,
        environment: environment
    )
    return CLIProcessResult(
        exitCode: output.terminationStatus,
        standardOutput: output.standardOutput,
        standardError: output.standardError
    )
}
