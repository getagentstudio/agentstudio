import Foundation
import Synchronization

/// Awaits a process's exit without parking a cooperative thread. Launch and
/// cancellation are serialized so cancellation either prevents launch or
/// terminates a child after `run()` returns.
package func awaitProcessExit(_ process: Process) async throws -> Int32 {
    let launchState = Mutex(ProcessExitLaunchState.notStarted)
    let pendingContinuation = Mutex<CheckedContinuation<Int32, any Error>?>(nil)

    let exitStatus = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        typealias ProcessExitContinuation = CheckedContinuation<Int32, any Error>
        let exitStatus = try await withCheckedThrowingContinuation { (continuation: ProcessExitContinuation) in
            pendingContinuation.withLock { $0 = continuation }
            process.terminationHandler = { exitedProcess in
                pendingContinuation.withLock { $0.take() }?.resume(returning: exitedProcess.terminationStatus)
            }
            do {
                try launchState.withLock { state in
                    guard state == .notStarted, !Task.isCancelled else {
                        state = .cancelled
                        throw CancellationError()
                    }
                    try TestToolResolver.launch(process)
                    state = .running
                    if Task.isCancelled {
                        state = .cancelled
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                }
            } catch {
                process.terminationHandler = nil
                launchState.withLock { state in
                    if state == .notStarted {
                        state = .cancelled
                    }
                }
                pendingContinuation.withLock { $0.take() }?.resume(throwing: error)
            }
        }
        return exitStatus
    } onCancel: {
        let processWasRunning = launchState.withLock { state -> Bool in
            switch state {
            case .notStarted:
                state = .cancelled
                return false
            case .cancelled:
                return false
            case .running:
                state = .cancelled
                return true
            }
        }
        if processWasRunning, process.isRunning {
            process.terminate()
        }
    }
    TestToolResolver.recordFailedExit(process)
    try Task.checkCancellation()
    return exitStatus
}

private enum ProcessExitLaunchState: Equatable, Sendable {
    case notStarted
    case cancelled
    case running
}
