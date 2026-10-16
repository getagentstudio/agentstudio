import AgentStudioIPCTransport
import Darwin
import Foundation

/// Readiness waits suspend in native poll until socket progress or an explicit
/// advance from the owning test. No elapsed-time correctness budget exists.
package final class ControlledCallDeadlineTiming: CallDeadlineTiming, @unchecked Sendable {
    private let lock = NSLock()
    private let readinessLock = NSLock()
    private var instant = ContinuousClock.now
    private let controlDescriptor: Int32
    private var pendingControl = Data()
    private var pendingAdvance: Int64?

    package init(controlDescriptor: Int32) { self.controlDescriptor = controlDescriptor }
    package func now() -> ContinuousClock.Instant { lock.withLock { instant } }

    package func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) throws
        -> CallDeadlineReadiness
    {
        try readinessLock.withLock { try waitForReplyStage(fileDescriptor: fileDescriptor, events: events) }
    }

    private func waitForReplyStage(fileDescriptor: Int32, events: Int16) throws -> CallDeadlineReadiness {
        while true {
            // Accept may precede client connect/send completion. Apply the
            // test's advance only at the actual client reply-read stage.
            if events & Int16(POLLIN) != 0, let advance = pendingAdvance {
                pendingAdvance = nil
                lock.withLock { instant = instant.advanced(by: .nanoseconds(advance)) }
                return .timedOut
            }
            var descriptors = [
                pollfd(fd: fileDescriptor, events: events, revents: 0),
                pollfd(fd: controlDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            let result = descriptors.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, 2, -1) }
            if result < 0 {
                if errno == EINTR { return .interrupted }
                throw UnixSocketTransportError(reason: .readinessFailed, errnoCode: errno)
            }
            if descriptors[1].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 64)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(controlDescriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { throw UnixSocketTransportError(reason: .connectionClosed, errnoCode: EPIPE) }
                pendingControl.append(contentsOf: bytes.prefix(count))
                if let newline = pendingControl.firstIndex(of: 10) {
                    guard let text = String(bytes: pendingControl[..<newline], encoding: .utf8) else {
                        throw UnixSocketTransportError(reason: .readinessFailed, errnoCode: EINVAL)
                    }
                    pendingControl.removeSubrange(...newline)
                    guard let nanoseconds = Int64(text), nanoseconds > 0 else {
                        throw UnixSocketTransportError(reason: .readinessFailed, errnoCode: EINVAL)
                    }
                    pendingAdvance = nanoseconds
                    if events & Int16(POLLIN) != 0 { continue }
                }
            }
            if descriptors[0].revents != 0 { return .ready(descriptors[0].revents) }
        }
    }
}

package final class ControlledDeadlineDriver: @unchecked Sendable {
    package let pipe = Pipe()
    package init() {}
    package var timing: ControlledCallDeadlineTiming {
        ControlledCallDeadlineTiming(controlDescriptor: pipe.fileHandleForReading.fileDescriptor)
    }
    package func advance(by duration: Duration) throws {
        let components = duration.components
        let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        try pipe.fileHandleForWriting.write(contentsOf: Data("\(nanoseconds)\n".utf8))
    }
    package func close() {
        cancel()
        try? pipe.fileHandleForReading.close()
    }

    // Keep the reader alive until its owner joins; writer EOF wakes native poll.
    package func cancel() { try? pipe.fileHandleForWriting.close() }
}
