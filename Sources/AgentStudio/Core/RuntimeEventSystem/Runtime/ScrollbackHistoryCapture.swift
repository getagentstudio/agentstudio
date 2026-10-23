import Darwin
import Dispatch
import Foundation
import Synchronization

/// A separate byte contract from ProcessExecutor's trimmed strings. Pipe and
/// child lifecycle callbacks serialize on one queue, never on MainActor.
final class ScrollbackHistoryCapture: @unchecked Sendable {
    private typealias CaptureCompletion = (ScrollbackCaptureResult, Task<Void, Never>?)

    private let process = Process()
    private let outputPipe = Pipe()
    private let byteCeiling: Int
    private let queue = DispatchQueue(label: "com.agentstudio.scrollback-capture", qos: .utility)
    private let launchCancelled = Mutex(false)

    // Queue-owned state. The launch lock is the only cross-queue mutation.
    private var continuation: CheckedContinuation<CaptureCompletion, Never>?
    private var outputSource: DispatchSourceRead?
    private var deadlineTask: Task<Void, Never>?
    private var standardOutput = Data()
    private var rejection: ScrollbackCaptureResult?
    private var processExited = false
    private var outputClosed = false
    private var completed = false
    private var exitStatus: Int32 = 0
    private var deadlineHasPassed: @Sendable () -> Bool = { false }

    init(executablePath: String, zmxDirectory: String, sessionID: ZmxSessionID, byteCeiling: Int) {
        self.byteCeiling = max(0, byteCeiling)
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["history", sessionID.rawValue, "--vt"]
        process.environment = ProcessInfo.processInfo.environment.merging(["ZMX_DIR": zmxDirectory]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        // No snapshot bytes, stderr, executable path or session id are logged.
        process.standardError = FileHandle.nullDevice
    }

    @concurrent
    nonisolated
        func run<CaptureClock: Clock>(clock: CaptureClock, deadline: Duration) async -> ScrollbackCaptureResult
    where CaptureClock.Duration == Duration {
        // Starts before launch, independently of zmx's internal 5s timeout.
        let expiration = clock.now.advanced(by: deadline)
        let completion: CaptureCompletion = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.deadlineHasPassed = { clock.now >= expiration }
                    self.start(continuation, clock: clock, expiration: expiration)
                }
            }
        } onCancel: {
            self.launchCancelled.withLock { $0 = true }
            // Cancellation has no accepted bytes; the existing total result
            // vocabulary classifies this aborted read as readFailed.
            self.stop(with: .readFailed)
        }
        // A result also means the clock task has ended, not merely been asked
        // to stop. Quit/retirement can then join this capture without leaks.
        await completion.1?.value
        return completion.0
    }

    private func start<CaptureClock: Clock>(
        _ continuation: CheckedContinuation<CaptureCompletion, Never>, clock: CaptureClock,
        expiration: CaptureClock.Instant
    ) where CaptureClock.Duration == Duration {
        self.continuation = continuation
        do {
            let launched = try launchCancelled.withLock { cancelled in
                guard !cancelled else { return false }
                try process.run()
                return true
            }
            guard launched else {
                closeUnlaunchedPipe()
                complete(.readFailed)
                return
            }
            try? outputPipe.fileHandleForWriting.close()
        } catch {
            closeUnlaunchedPipe()
            complete(.launchFailed(errno: Self.launchErrno(for: error)))
            return
        }

        process.terminationHandler = { [weak self] child in
            guard let self else { return }
            let status = child.terminationStatus
            self.queue.async {
                self.processExited = true
                self.exitStatus = status
                self.completeIfSettled()
            }
        }
        // Register-then-check: a tiny child can exit before the handler is
        // installed. Foundation owns reaping and the termination status.
        if !process.isRunning {
            processExited = true
            exitStatus = process.terminationStatus
        }

        configureOutputSource()
        deadlineTask = Task { [weak self] in
            do { try await clock.sleep(until: expiration, tolerance: nil) } catch { return }
            guard !Task.isCancelled else { return }
            self?.stop(with: .deadlineExceeded)
        }
        completeIfSettled()
    }

    private func configureOutputSource() {
        let descriptor = outputPipe.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        outputSource = source
        source.setEventHandler { [self] in readAvailableOutput(descriptor: descriptor) }
        source.setCancelHandler { [self] in
            try? outputPipe.fileHandleForReading.close()
            outputClosed = true
            completeIfSettled()
        }
        source.resume()
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            rejectOnQueue(.readFailed)
            return
        }
    }

    private func readAvailableOutput(descriptor: Int32) {
        guard !outputClosed, rejection == nil else { return }
        // Read at most the remaining ceiling plus one detection byte. The
        // accumulated Data never exceeds the ceiling, even for a huge pipe.
        let remaining = byteCeiling - standardOutput.count
        let chunkSize = remaining < 16_384 ? remaining + 1 : 16_384
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while rejection == nil {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard count <= byteCeiling - standardOutput.count else {
                    rejectOnQueue(.exceededCeiling)
                    return
                }
                standardOutput.append(contentsOf: chunk.prefix(count))
                // One bounded drain per callback lets deadline/cancellation
                // work run even while a producer continuously fills stdout.
                return
            } else if count == 0 {
                outputSource?.cancel()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                rejectOnQueue(.readFailed)
                return
            }
        }
    }

    private func stop(with outcome: ScrollbackCaptureResult) {
        queue.async { self.rejectOnQueue(outcome) }
    }

    private func rejectOnQueue(_ outcome: ScrollbackCaptureResult) {
        guard !completed, rejection == nil else { return }
        rejection = outcome
        outputSource?.cancel()
        // history is a read-only client, not the pane's daemon. Kill only
        // this owned child, then await Foundation's exit/reap callback. There
        // is no extra grace clock extending the capture's absolute deadline.
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        completeIfSettled()
    }

    private func completeIfSettled() {
        guard processExited, outputClosed, !completed else { return }
        let result =
            rejection
            ?? (deadlineHasPassed()
                ? .deadlineExceeded
                : ScrollbackCaptureResult.classify(
                    standardOutput: standardOutput, exitStatus: exitStatus, readFailed: false))
        complete(result)
    }

    private func complete(_ result: ScrollbackCaptureResult) {
        guard !completed else { return }
        completed = true
        process.terminationHandler = nil
        deadlineTask?.cancel()
        let completion = (result, deadlineTask)
        deadlineTask = nil
        outputSource = nil
        let reply = continuation
        continuation = nil
        reply?.resume(returning: completion)
    }

    private func closeUnlaunchedPipe() {
        try? outputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
    }

    private static func launchErrno(for error: any Error) -> Int32 {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return Int32(failure.code) }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError { return launchErrno(for: underlying) }
        return failure.domain == NSCocoaErrorDomain && failure.code == NSFileNoSuchFileError ? ENOENT : EIO
    }
}
