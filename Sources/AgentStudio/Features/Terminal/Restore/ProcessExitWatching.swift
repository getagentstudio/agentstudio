import AgentStudioCore
import AgentStudioInfrastructure
import Darwin
import Dispatch
import Foundation

package enum ProcessExitWatchFailure: Equatable, Sendable {
    case permissionDenied, resourceExhausted, other
}

package enum ProcessExitWatchEvent: Equatable, Sendable {
    case exited(watchId: UUID)
    case alreadyGone(watchId: UUID)
    case unavailable(watchId: UUID, ProcessExitWatchFailure)
}

package struct ProcessExitWatch: Sendable {
    package let events: AsyncStream<ProcessExitWatchEvent>
    package let cancel: @Sendable () -> Void
}

package protocol ProcessExitWatching: Sendable {
    func watchExit(of process: ProcessIncarnation, watchId: UUID) -> ProcessExitWatch
}

package protocol ProcessExitSource: AnyObject, Sendable {
    func setRegistrationHandler(_ handler: @escaping @Sendable () -> Void)
    func setEventHandler(_ handler: @escaping @Sendable () -> Void)
    func setCancelHandler(_ handler: @escaping @Sendable () -> Void)
    func resume()
    func cancel()
}

package protocol ProcessExitSourceMaking: Sendable {
    func makeSource(pid: Int32) throws -> any ProcessExitSource
}

package enum ProcessExitWatcherFact: Equatable, Sendable {
    case sourceCreated, resumed, registered
    case checked(ColdStartLeaderState)
    case sourceCancelled
    case cancelled
    case settled(ProcessExitWatchEvent)
    case lateRequestDropped
}

/// All state is protected by the recursive lock. The injected source may call
/// its cancel handler synchronously; native Dispatch sources call it later.
/// Both paths settle from the cancel acknowledgment exactly once.
package final class DarwinProcessExitWatcher: ProcessExitWatching, @unchecked Sendable {
    private struct Entry {
        let source: any ProcessExitSource
        let process: ProcessIncarnation
        let continuation: AsyncStream<ProcessExitWatchEvent>.Continuation
        var registered = false
        var pendingExit = false
        var cancellation: Cancellation?
    }
    private enum Cancellation: Equatable {
        case cancelled
        case event(ProcessExitWatchEvent)
    }
    // The injected cancel handler may re-enter synchronously; native handlers
    // arrive later on Dispatch. Both paths need the same ownership lock.
    private let lock = NSRecursiveLock()
    private var entries: [UUID: Entry] = [:]
    private var usedIdentifiers: Set<UUID> = []
    private var stopped = false
    private let sourceMaker: any ProcessExitSourceMaking
    private let leaderState: @Sendable (ProcessIncarnation) -> ColdStartLeaderState
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private let factSink: (@Sendable (UUID, ProcessExitWatcherFact) -> Void)?

    package init(
        sourceMaker: (any ProcessExitSourceMaking)? = nil,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        leaderState: @escaping @Sendable (ProcessIncarnation) -> ColdStartLeaderState = {
            DarwinColdStartObserverSyscalls().leaderState(of: $0)
        },
        factSink: (@Sendable (UUID, ProcessExitWatcherFact) -> Void)? = nil
    ) {
        self.performanceTraceRecorder = performanceTraceRecorder
        self.sourceMaker = sourceMaker ?? NativeProcessExitSourceMaker()
        self.leaderState = leaderState
        self.factSink = factSink
    }

    package func watchExit(of process: ProcessIncarnation, watchId: UUID) -> ProcessExitWatch {
        AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreForegroundWatch, recorder: performanceTraceRecorder
        ) {
            let stream = AsyncStream.makeStream(of: ProcessExitWatchEvent.self, bufferingPolicy: .bufferingOldest(1))
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else {
                stream.continuation.finish()
                factSink?(watchId, .lateRequestDropped)
                return ProcessExitWatch(events: stream.stream, cancel: {})
            }
            guard usedIdentifiers.insert(watchId).inserted else {
                // Its fact scope already closed. A replay owns no new source or
                // operation and must not emit a second closing fact for that id.
                stream.continuation.finish()
                return ProcessExitWatch(events: stream.stream, cancel: {})
            }
            do {
                let source = try sourceMaker.makeSource(pid: process.pid)
                entries[watchId] = Entry(source: source, process: process, continuation: stream.continuation)
                factSink?(watchId, .sourceCreated)
                source.setRegistrationHandler { [weak self] in self?.registered(watchId) }
                source.setEventHandler { [weak self] in self?.exited(watchId) }
                source.setCancelHandler { [weak self] in self?.cancellationAcknowledged(watchId) }
                // Publish before resume can invoke any handlers on the native queue.
                factSink?(watchId, .resumed)
                source.resume()
            } catch {
                let number = (error as? POSIXErrorNumber)?.rawValue ?? (error as? POSIXError)?.code.rawValue ?? EIO
                let event: ProcessExitWatchEvent =
                    number == ESRCH
                    ? .alreadyGone(watchId: watchId) : .unavailable(watchId: watchId, Self.failureClass(number))
                stream.continuation.yield(event)
                stream.continuation.finish()
                factSink?(watchId, .settled(event))
            }

            return ProcessExitWatch(events: stream.stream, cancel: { [weak self] in self?.cancel(watchId) })
        }
    }

    private func registered(_ watchId: UUID) {
        AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreForegroundWatch, recorder: performanceTraceRecorder
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard var entry = entries[watchId], entry.cancellation == nil, !entry.registered else { return }
            entry.registered = true
            entries[watchId] = entry
            factSink?(watchId, .registered)
            // This is the only initial incarnation check, gated by registration.
            let state = leaderState(entry.process)
            factSink?(watchId, .checked(state))
            switch state {
            case .exited: beginCancellation(watchId, .event(.alreadyGone(watchId: watchId)))
            case .unverifiable(let error):
                beginCancellation(watchId, .event(.unavailable(watchId: watchId, Self.failureClass(error.rawValue))))
            case .sameIncarnationAlive:
                if entry.pendingExit { beginCancellation(watchId, .event(.exited(watchId: watchId))) }
            }

        }
    }

    private func exited(_ watchId: UUID) {
        AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreForegroundWatch, recorder: performanceTraceRecorder
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard var entry = entries[watchId], entry.cancellation == nil else { return }
            guard entry.registered else {
                entry.pendingExit = true
                entries[watchId] = entry
                return
            }
            beginCancellation(watchId, .event(.exited(watchId: watchId)))

        }
    }

    private func cancel(_ watchId: UUID) {
        AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreForegroundWatch, recorder: performanceTraceRecorder
        ) {
            lock.lock()
            defer { lock.unlock() }
            beginCancellation(watchId, .cancelled)

        }
    }

    private func beginCancellation(_ watchId: UUID, _ cancellation: Cancellation) {
        guard var entry = entries[watchId], entry.cancellation == nil else { return }
        entry.cancellation = cancellation
        entries[watchId] = entry
        entry.source.cancel()
    }

    private func cancellationAcknowledged(_ watchId: UUID) {
        AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreForegroundWatch, recorder: performanceTraceRecorder
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[watchId], let cancellation = entry.cancellation else { return }
            entries[watchId] = nil
            factSink?(watchId, .sourceCancelled)
            switch cancellation {
            case .cancelled: factSink?(watchId, .cancelled)
            case .event(let event):
                entry.continuation.yield(event)
                factSink?(watchId, .settled(event))
            }
            entry.continuation.finish()

        }
    }

    package func shutdown() {
        AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreForegroundWatch, recorder: performanceTraceRecorder
        ) {
            lock.lock()
            defer { lock.unlock() }
            stopped = true
            for identifier in Array(entries.keys) { beginCancellation(identifier, .cancelled) }
        }
    }

    deinit {
        for entry in entries.values {
            if entry.cancellation == nil { entry.source.cancel() }
            entry.continuation.finish()
        }
    }

    private static func failureClass(_ errorNumber: Int32) -> ProcessExitWatchFailure {
        switch errorNumber {
        case EACCES, EPERM: .permissionDenied
        case ENOMEM, ENOSPC, EMFILE, ENFILE: .resourceExhausted
        default: .other
        }
    }
}
