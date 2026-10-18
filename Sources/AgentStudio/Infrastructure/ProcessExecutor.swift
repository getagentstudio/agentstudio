import Darwin
import Dispatch
import Foundation
import os

private let processLogger = Logger(subsystem: "com.agentstudio", category: "ProcessExecutor")

// MARK: - ProcessExecutor Protocol

/// Testable wrapper for CLI execution. In production, runs Process.
/// In tests, returns canned responses.
package protocol ProcessExecutor: Sendable {
    func execute(
        command: String,
        args: [String],
        cwd: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult
}

/// Result of a CLI command execution.
package struct ProcessResult: Sendable {
    package let exitCode: Int
    package let stdout: String
    package let stderr: String

    package var succeeded: Bool { exitCode == 0 }

    package init(exitCode: Int, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

// MARK: - ProcessError

/// `package` so callers outside this module (`ZmxBackend.discoverSessionInventory()`
/// in `AgentStudioCore`) can distinguish a timeout from every other execution
/// failure without re-deriving it from `localizedDescription` text.
package enum ProcessError: Error, LocalizedError {
    case timedOut(command: String, seconds: TimeInterval)

    package var errorDescription: String? {
        switch self {
        case .timedOut(let command, let seconds):
            return "Process '\(command)' timed out after \(Int(seconds))s"
        }
    }
}

// MARK: - DefaultProcessExecutor

/// Production executor that spawns real processes and reports completion asynchronously.
///
/// The implementation keeps process lifecycle out of `AsyncStream` and task-group races.
/// Dispatch sources/handlers drive pipe reads, process exit, and cancellation;
/// a clock task drives timeout. One checked continuation is resumed exactly once.
package struct DefaultProcessExecutor: ProcessExecutor {
    /// Default timeout for process execution.
    package let timeout: TimeInterval
    private let clock: any Clock<Duration>
    private let beforeLaunch: @Sendable () -> Void

    package init(timeout: TimeInterval = 15, clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        self.clock = clock
        beforeLaunch = {}
    }

    /// Internal launch seam for deterministic lifecycle tests. Production execution uses
    /// the standard package initializer above and never pauses before the launch decision.
    init(
        timeout: TimeInterval,
        clock: any Clock<Duration> = ContinuousClock(),
        beforeLaunch: @escaping @Sendable () -> Void
    ) {
        self.timeout = timeout
        self.clock = clock
        self.beforeLaunch = beforeLaunch
    }

    private static let defaultSystemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    private static let toolchainPathPrefix = "/opt/homebrew/bin:/usr/local/bin"

    private static func normalizedEnvironment(from environment: [String: String]) -> [String: String] {
        var env = environment

        let inheritedPath = env["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePath =
            (inheritedPath?.isEmpty == false) ? inheritedPath! : Self.defaultSystemPath
        env["PATH"] = "\(Self.toolchainPathPrefix):\(basePath)"

        let inheritedHome = env["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if inheritedHome?.isEmpty != false {
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }

        return env
    }

    package func execute(
        command: String,
        args: [String],
        cwd: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args

        if let cwd {
            process.currentDirectoryURL = cwd
        }

        // Merge provided environment with inherited, ensuring brew paths
        // and HOME are available for CLI tools (gh auth config lookup).
        var env = ProcessInfo.processInfo.environment
        if let override = environment {
            env.merge(override) { _, new in new }
        }
        process.environment = Self.normalizedEnvironment(from: env)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let execution = ProcessExecution(
            command: command,
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            timeoutSeconds: timeout,
            hardKillGraceSeconds: 0.2,
            beforeLaunch: beforeLaunch
        )
        return try await execution.run(clock: clock)
    }

    fileprivate static func decodeAndTrim(_ data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `ProcessExecution` crosses Swift cancellation and Dispatch callback boundaries.
/// All mutable state below is owned by `queue`; external callbacks only enqueue work
/// onto that queue, so the unchecked Sendable boundary is limited to queue handoff.
private final class ProcessExecution: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<ProcessResult, Error>

    private enum TerminationCause {
        case timeout
        case cancellation
    }

    private enum PipeKind {
        case stdout
        case stderr
    }

    private let command: String
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let timeoutSeconds: TimeInterval
    private let hardKillGraceSeconds: TimeInterval
    private let beforeLaunch: @Sendable () -> Void
    private let queue: DispatchQueue
    private let launchDecision = ProcessLaunchDecision()

    private var continuation: Continuation?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var processExited = false
    private var stdoutFinished = false
    private var stderrFinished = false
    private var terminationStatus: Int32 = 0
    private var terminationCause: TerminationCause?
    private var completed = false
    private var processSource: DispatchSourceProcess?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var timeoutTask: Task<Void, Never>?

    init(
        command: String,
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeoutSeconds: TimeInterval,
        hardKillGraceSeconds: TimeInterval,
        beforeLaunch: @escaping @Sendable () -> Void
    ) {
        self.command = command
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.timeoutSeconds = timeoutSeconds
        self.hardKillGraceSeconds = hardKillGraceSeconds
        self.beforeLaunch = beforeLaunch
        queue = DispatchQueue(label: "com.agentstudio.process-executor.\(UUID().uuidString)", qos: .userInitiated)
    }

    func run(clock: any Clock<Duration>) async throws -> ProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.start(continuation, clock: clock)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(_ continuation: Continuation, clock: any Clock<Duration>) {
        self.continuation = continuation
        guard terminationCause != .cancellation else {
            complete(.failure(CancellationError()))
            return
        }

        configureTerminationHandler()
        beforeLaunch()

        do {
            guard try launchDecision.runUnlessCancelled({ try process.run() }) else {
                terminationCause = .cancellation
                complete(.failure(CancellationError()))
                return
            }
        } catch {
            complete(.failure(error))
            return
        }

        configurePipeSources()
        configureProcessSource()
        configureTimeoutTask(using: clock)
        stdoutSource?.resume()
        stderrSource?.resume()
        processSource?.resume()
    }

    private func configurePipeSources() {
        stdoutSource = makeReadSource(pipe: stdoutPipe, kind: .stdout)
        stderrSource = makeReadSource(pipe: stderrPipe, kind: .stderr)
    }

    private func makeReadSource(pipe: Pipe, kind: PipeKind) -> DispatchSourceRead {
        let fileHandle = pipe.fileHandleForReading
        let source = DispatchSource.makeReadSource(fileDescriptor: fileHandle.fileDescriptor, queue: queue)
        source.setEventHandler { [self, fileHandle] in
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                markPipeFinished(kind)
            } else {
                append(chunk, from: kind)
            }
        }
        source.setCancelHandler { [fileHandle] in
            try? fileHandle.close()
        }
        return source
    }

    private func configureTerminationHandler() {
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let execution = self else { return }
            let status = terminatedProcess.terminationStatus
            execution.queue.async {
                execution.markProcessExited(status: status)
            }
        }
    }

    private func configureProcessSource() {
        let source = DispatchSource.makeProcessSource(
            identifier: process.processIdentifier,
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [self] in
            // DispatchSourceProcess is a wakeup/backstop; Foundation's
            // terminationHandler owns the status because terminationStatus can
            // still throw if the source fires before Process marks itself exited.
            guard !process.isRunning else { return }
            markProcessExited(status: process.terminationStatus)
        }
        processSource = source
    }

    private func configureTimeoutTask<TimeoutClock: Clock>(using clock: TimeoutClock)
    where TimeoutClock.Duration == Duration {
        // Capture the deadline at configuration, so scheduling the task later
        // does not extend the child's timeout.
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        timeoutTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.queue.async {
                self.markTimedOut()
            }
        }
    }

    private func append(_ data: Data, from kind: PipeKind) {
        switch kind {
        case .stdout:
            stdoutData.append(data)
        case .stderr:
            stderrData.append(data)
        }
    }

    private func markPipeFinished(_ kind: PipeKind) {
        switch kind {
        case .stdout:
            stdoutSource?.cancel()
        case .stderr:
            stderrSource?.cancel()
        }

        switch kind {
        case .stdout:
            stdoutFinished = true
        case .stderr:
            stderrFinished = true
        }
        let completion = completionIfReady()
        if let completion {
            complete(completion)
        }
    }

    private func markProcessExited(status: Int32) {
        processExited = true
        terminationStatus = status
        let completion = completionIfReady()
        if let completion {
            complete(completion)
        }
    }

    private func markTimedOut() {
        if completed || terminationCause != nil {
            return
        }
        terminationCause = .timeout

        processLogger.warning(
            "Process '\(self.command, privacy: .public)' exceeded \(Int(self.timeoutSeconds))s timeout - terminating"
        )
        if self.process.isRunning {
            self.process.terminate()
        }
        queue.asyncAfter(deadline: .now() + self.hardKillGraceSeconds) { [self] in
            forceKillIfStillRunning()
        }
    }

    private func forceKillIfStillRunning() {
        guard self.process.isRunning else { return }
        processLogger.warning(
            "Process '\(self.command, privacy: .public)' ignored terminate() after \(self.hardKillGraceSeconds, privacy: .public)s - forcing SIGKILL"
        )
        let pid = self.process.processIdentifier
        if pid > 0 {
            _ = kill(pid, SIGKILL)
        }
    }

    private func completionIfReady() -> Result<ProcessResult, Error>? {
        guard processExited, stdoutFinished, stderrFinished else {
            return nil
        }
        switch terminationCause {
        case .timeout:
            return .failure(ProcessError.timedOut(command: command, seconds: timeoutSeconds))
        case .cancellation:
            return .failure(CancellationError())
        case nil:
            break
        }
        let result = ProcessResult(
            exitCode: Int(terminationStatus),
            stdout: DefaultProcessExecutor.decodeAndTrim(stdoutData),
            stderr: DefaultProcessExecutor.decodeAndTrim(stderrData)
        )
        return .success(result)
    }

    private func cancel() {
        launchDecision.cancelBeforeLaunch()
        queue.async {
            self.cancelOnQueue()
        }
    }

    private func cancelOnQueue() {
        guard !completed, terminationCause == nil else { return }
        terminationCause = .cancellation
        guard continuation != nil else { return }
        terminateForCancellation()
    }

    private func terminateForCancellation() {
        guard process.isRunning else { return }
        process.terminate()
        queue.asyncAfter(deadline: .now() + hardKillGraceSeconds) { [self] in
            forceKillIfStillRunning()
        }
    }

    private func complete(_ result: Result<ProcessResult, Error>) {
        if completed {
            return
        }
        completed = true
        let continuationToResume = continuation
        continuation = nil

        cleanupSources()
        continuationToResume?.resume(with: result)
    }

    private func cleanupSources() {
        process.terminationHandler = nil
        timeoutTask?.cancel()
        processSource?.cancel()
        stdoutSource?.cancel()
        stderrSource?.cancel()
        timeoutTask = nil
        processSource = nil
        stdoutSource = nil
        stderrSource = nil
    }
}

/// Linearizes task cancellation against the child launch decision. Queue ordering still
/// owns the launched child's lifecycle, while this lock closes the interval immediately
/// before `Process.run()` where cancellation must be able to prevent launch altogether.
private final class ProcessLaunchDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func runUnlessCancelled(_ launch: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isCancelled {
            return false
        }
        try launch()
        return true
    }

    func cancelBeforeLaunch() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
    }
}
