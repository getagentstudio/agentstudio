import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// One monotonic limit shared by connect, authentication and every partial I/O.
public struct CallDeadline: Sendable {
    private let expiresAt: ContinuousClock.Instant
    private let timing: any CallDeadlineTiming

    public init(limit: Duration) {
        self.init(limit: limit, timing: SystemCallDeadlineTiming())
    }

    package init(limit: Duration, timing: any CallDeadlineTiming) {
        self.timing = timing
        expiresAt = timing.now().advanced(by: limit)
    }

    package init(limit: Duration, startedAt: ContinuousClock.Instant) {
        self.init(limit: limit, startedAt: startedAt, timing: SystemCallDeadlineTiming())
    }

    package init(limit: Duration, startedAt: ContinuousClock.Instant, timing: any CallDeadlineTiming) {
        self.timing = timing
        expiresAt = startedAt.advanced(by: limit)
    }

    /// Downstream completion work shares the original limit instead of starting another one.
    package var remainingBudget: Duration {
        max(.zero, timing.now().duration(to: expiresAt))
    }

    /// Shortens a downstream call without extending ingress expiration or replacing its clock.
    package func capped(to limit: Duration) -> Self {
        let startedAt = timing.now()
        let remainingLimit = min(limit, max(.zero, startedAt.duration(to: expiresAt)))
        return Self(limit: remainingLimit, startedAt: startedAt, timing: timing)
    }

    #if canImport(Darwin)
        func checkExpiration() throws {
            guard timing.now() < expiresAt else {
                throw UnixSocketTransportError(reason: .deadlineExceeded, errnoCode: ETIMEDOUT)
            }
        }

        func wait(fileDescriptor: Int32, events: Int16) throws {
            while true {
                let remaining = timing.now().duration(to: expiresAt)
                guard remaining > .zero else {
                    throw UnixSocketTransportError(reason: .deadlineExceeded, errnoCode: ETIMEDOUT)
                }
                // Recompute after an early timeout, an interrupted wait or a
                // capped poll. Nothing extends the absolute expiration.
                switch try timing.waitForReadiness(fileDescriptor: fileDescriptor, events: events, timeout: remaining) {
                case .timedOut, .interrupted:
                    continue
                case .ready(let revents):
                    guard revents & Int16(POLLNVAL) == 0 else {
                        throw UnixSocketTransportError(reason: .connectionClosed, errnoCode: EBADF)
                    }
                }
                try checkExpiration()
                // HUP/ERR also wake the actual nonblocking operation, which
                // reports its established EOF/error semantics (or SO_ERROR).
                return
            }
        }
    #endif
}

package enum CallDeadlineReadiness: Sendable {
    case ready(Int16)
    case timedOut
    case interrupted
}

/// Time and the blocking readiness wait are one dependency, so a controlled
/// clock cannot accidentally leave a test sleeping inside a real poll.
package protocol CallDeadlineTiming: Sendable {
    func now() -> ContinuousClock.Instant
    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) throws -> CallDeadlineReadiness
}

private struct SystemCallDeadlineTiming: CallDeadlineTiming {
    func now() -> ContinuousClock.Instant { ContinuousClock.now }

    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) throws -> CallDeadlineReadiness {
        #if canImport(Darwin)
            let milliseconds = timeout / .milliseconds(1)
            let pollTimeout = Int32(min(Double(Int32.max), milliseconds.rounded(.up)))
            var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, pollTimeout)
            if result < 0 {
                if errno == EINTR { return .interrupted }
                throw UnixSocketTransportError(reason: .readinessFailed, errnoCode: errno)
            }
            if result == 0 { return .timedOut }
            return .ready(descriptor.revents)
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }
}
