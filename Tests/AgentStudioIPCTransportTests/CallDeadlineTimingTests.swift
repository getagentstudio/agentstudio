import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudioIPCTransport

@Suite("Absolute call deadline timing")
struct CallDeadlineTimingTests {
    @Test("one-byte progress never resets the original call expiration")
    func tricklingPeerCannotExtendDeadline() async throws {
        let observed = try await valueFromDedicatedThread {
            let pair = try DeadlineSocketPair()
            let timing = ScriptedDeadlineTiming(peerDescriptor: pair.peerDescriptor)
            let deadline = CallDeadline(limit: .seconds(3), timing: timing)
            let connection = UnixSocketConnection(fileDescriptor: pair.clientDescriptor, deadline: deadline)
            defer {
                connection.close()
                pair.closePeer()
            }
            let first = try connection.receive(maxBytes: 1)
            let second = try connection.receive(maxBytes: 1)
            let failure: UnixSocketTransportError?
            do {
                _ = try connection.receive(maxBytes: 1)
                failure = nil
            } catch let error as UnixSocketTransportError {
                failure = error
            }
            return (first, second, failure, timing.requestedTimeouts, deadline.remainingBudget)
        }
        #expect(observed.0 == Data([65]))
        #expect(observed.1 == Data([65]))
        #expect(observed.2 == UnixSocketTransportError(reason: .deadlineExceeded, errnoCode: ETIMEDOUT))
        #expect(observed.3 == [.seconds(3), .seconds(2), .seconds(1)])
        #expect(observed.4 == .zero)
    }

    @Test("a reply received before the fixed expiration succeeds")
    func progressInsideDeadlineSucceeds() async throws {
        let observed = try await valueFromDedicatedThread {
            let pair = try DeadlineSocketPair()
            let timing = ScriptedDeadlineTiming(peerDescriptor: pair.peerDescriptor)
            let deadline = CallDeadline(limit: .seconds(3), timing: timing)
            let connection = UnixSocketConnection(fileDescriptor: pair.clientDescriptor, deadline: deadline)
            defer {
                connection.close()
                pair.closePeer()
            }
            let reply = try connection.receive(maxBytes: 1)
            return (reply, timing.requestedTimeouts, deadline.remainingBudget)
        }
        #expect(observed.0 == Data([65]))
        #expect(observed.1 == [.seconds(3)])
        #expect(observed.2 == .seconds(2))
    }

    @Test("slow partial writes stop at the original expiration despite peer progress")
    func partialWritesCannotExtendDeadline() async throws {
        let observed = try await valueFromDedicatedThread {
            let pair = try DeadlineSocketPair()
            var bufferSize: Int32 = 4096
            guard
                setsockopt(
                    pair.clientDescriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                pair.closeBoth()
                throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
            }
            let timing = ScriptedDeadlineTiming(peerDescriptor: pair.peerDescriptor)
            let deadline = CallDeadline(limit: .seconds(3), timing: timing)
            let connection = UnixSocketConnection(fileDescriptor: pair.clientDescriptor, deadline: deadline)
            defer {
                connection.close()
                pair.closePeer()
            }
            let failure: UnixSocketTransportError?
            do {
                try connection.send(Data(repeating: 65, count: 1_048_576))
                failure = nil
            } catch let error as UnixSocketTransportError {
                failure = error
            }
            return (failure, timing.requestedTimeouts, timing.consumedPeerBytes, deadline.remainingBudget)
        }
        #expect(observed.0 == UnixSocketTransportError(reason: .deadlineExceeded, errnoCode: ETIMEDOUT))
        #expect(observed.1 == [.seconds(3), .seconds(2), .seconds(1)])
        #expect(!observed.2.isEmpty)
        #expect(observed.2.allSatisfy { $0 == 65 })
        #expect(observed.3 == .zero)
    }
}

/// A frozen monotonic origin plus explicit one-second steps, as in the
/// existing controlled-clock convention. Every readiness operation writes one
/// real peer byte; no waiting, scheduling or wall-clock assertion is involved.
private final class ScriptedDeadlineTiming: CallDeadlineTiming, @unchecked Sendable {
    private let lock = NSLock()
    private let peerDescriptor: Int32
    private var instant = ContinuousClock.now
    private var timeouts: [Duration] = []
    private var consumedBytes: [UInt8] = []

    init(peerDescriptor: Int32) {
        self.peerDescriptor = peerDescriptor
    }

    func now() -> ContinuousClock.Instant {
        lock.withLock { instant }
    }

    var requestedTimeouts: [Duration] {
        lock.withLock { timeouts }
    }

    var consumedPeerBytes: [UInt8] { lock.withLock { consumedBytes } }

    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) throws -> CallDeadlineReadiness {
        if events & Int16(POLLIN) != 0 {
            let written = Data([65]).withUnsafeBytes { buffer in
                Darwin.write(peerDescriptor, buffer.baseAddress, buffer.count)
            }
            guard written == 1 else {
                throw UnixSocketTransportError(reason: .writeFailed, errnoCode: errno)
            }
        } else {
            var byte: UInt8 = 0
            let read = Darwin.read(peerDescriptor, &byte, 1)
            if read == 1 {
                lock.withLock { consumedBytes.append(byte) }
            } else if read < 0, errno != EAGAIN && errno != EWOULDBLOCK {
                throw UnixSocketTransportError(reason: .readFailed, errnoCode: errno)
            }
        }
        lock.withLock {
            timeouts.append(timeout)
            instant = instant.advanced(by: .seconds(1))
        }
        return .ready(events)
    }
}

private struct DeadlineSocketPair {
    let clientDescriptor: Int32
    let peerDescriptor: Int32

    init() throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
        }
        clientDescriptor = descriptors[0]
        peerDescriptor = descriptors[1]
        do {
            for descriptor in descriptors {
                try UnixSocketOptions.disableSigPipe(fileDescriptor: descriptor)
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
                }
            }
        } catch {
            closeBoth()
            throw error
        }
    }

    func closePeer() {
        _ = Darwin.close(peerDescriptor)
    }

    func closeBoth() {
        _ = Darwin.close(clientDescriptor)
        closePeer()
    }
}
