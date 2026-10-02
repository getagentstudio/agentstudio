import AgentStudioTestHarness
import Foundation

/// What a subprocess left behind once it exited: its status and both streams,
/// untrimmed.
package struct ExitedProcessOutput: Sendable {
    package let terminationStatus: Int32
    package let standardOutput: Data
    package let standardError: Data
}

/// Runs a subprocess to exit with no per-test elapsed-time budget.
///
/// A test's verdict must not depend on how fast the runner is. A subprocess
/// timeout picked on a sixteen-core Mac expires on a three-core CI runner while
/// the child is still doing correct work, so the only bound left on these waits
/// is the runner-owned lane hang bound
/// (`docs/architecture/testing/testing_architecture.md#how-a-test-may-wait`).
///
/// Three hazards shape the wait itself:
///
/// - Blocking on the child parks a thread. The caller instead suspends until
///   `Process.terminationHandler` reports the exit, so no cooperative thread the
///   code under test needs is held.
/// - Do not replace the handler with `Process.waitUntilExit()`: it spins the
///   calling thread's run loop, and exit delivery goes to the launching
///   thread's run loop. Called on a libdispatch worker for a child launched
///   from another thread it never wakes: a sample of the first version of this
///   helper showed three such workers parked in `-[NSConcreteTask waitUntilExit]`
///   after their children had exited.
/// - A pipe holds 64 KB. Reading it only after the child exits deadlocks once
///   the child fills it, so both streams go to temporary files.
///
/// Cancelling the awaiting task terminates the child, so a product owner that
/// cancels its own work still ends the process it started.
package func runProcessToExit(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    environment: [String: String]? = nil
) async throws -> ExitedProcessOutput {
    let captureDirectory = try FileManager.default.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: FileManager.default.temporaryDirectory,
        create: true
    )
    defer { try? FileManager.default.removeItem(at: captureDirectory) }

    let standardOutputURL = captureDirectory.appending(path: "stdout")
    let standardErrorURL = captureDirectory.appending(path: "stderr")
    FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
    FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
    let standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
    let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
    defer {
        try? standardOutputHandle.close()
        try? standardErrorHandle.close()
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    if let currentDirectoryURL {
        process.currentDirectoryURL = currentDirectoryURL
    }
    if let environment {
        process.environment = environment
    }
    process.standardOutput = standardOutputHandle
    process.standardError = standardErrorHandle

    let terminationStatus = try await awaitProcessExit(process)
    try Task.checkCancellation()

    return ExitedProcessOutput(
        terminationStatus: terminationStatus,
        standardOutput: try Data(contentsOf: standardOutputURL),
        standardError: try Data(contentsOf: standardErrorURL)
    )
}

/// What a command left behind once it exited, in `DefaultProcessExecutor`'s
/// result shape: the exit code and both streams decoded and trimmed.
package struct CommandRunResult: Sendable {
    package let exitCode: Int
    package let stdout: String
    package let stderr: String

    package var succeeded: Bool { exitCode == 0 }
}

/// Runs `command` to exit under `DefaultProcessExecutor`'s command contract,
/// with no timeout.
///
/// Git and Python use the cached developer-tool resolver; other commands resolve
/// through `/usr/bin/env`. `environment` merges over the
/// inherited one with the Homebrew toolchain prefixed to `PATH`, and both
/// streams come back trimmed, so a converted test sees the results it saw
/// before, only without the elapsed-time budget. See `runProcessToExit` for how
/// the wait works.
package func runCommandToExit(
    command: String,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    environment: [String: String]? = nil
) async throws -> CommandRunResult {
    var mergedEnvironment = ProcessInfo.processInfo.environment
    if let environment {
        mergedEnvironment.merge(environment) { _, callerValue in callerValue }
    }
    let output = try await runProcessToExit(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [try await TestToolResolver.resolveCommand(command)] + arguments,
        currentDirectoryURL: currentDirectoryURL,
        environment: CommandEnvironment.normalized(mergedEnvironment)
    )
    return CommandRunResult(
        exitCode: Int(output.terminationStatus),
        stdout: CommandEnvironment.decodeAndTrim(output.standardOutput),
        stderr: CommandEnvironment.decodeAndTrim(output.standardError)
    )
}

/// The environment and output conventions `DefaultProcessExecutor` applies,
/// mirrored here because this target cannot import the executor's module.
private enum CommandEnvironment {
    private static let defaultSystemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    private static let toolchainPathPrefix = "/opt/homebrew/bin:/usr/local/bin"

    static func normalized(_ environment: [String: String]) -> [String: String] {
        var normalized = environment
        let inheritedPath = normalized["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let basePath = inheritedPath.isEmpty ? defaultSystemPath : inheritedPath
        normalized["PATH"] = "\(toolchainPathPrefix):\(basePath)"
        let inheritedHome = normalized["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if inheritedHome.isEmpty {
            normalized["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return normalized
    }

    static func decodeAndTrim(_ data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
