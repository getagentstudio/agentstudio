import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension WorkspaceSurfaceCoordinator {
    func startTerminalSessionCleanup(
        using backend: any ZmxSessionControlling,
        canRetire: @escaping @MainActor @Sendable (ZmxSessionID) -> Bool,
        delay: AsyncDelay = .taskSleep
    ) {
        guard terminalSessionCleanupTask == nil, !terminalSessionCleanupStopped else { return }
        let wakeups = terminalSessionCleanupWakeups
        terminalSessionCleanupTask = Task { [weak self] in
            await Self.runTerminalSessionCleanupLoop(wakeups: wakeups, delay: delay) { [weak self] in
                guard let self, !self.terminalSessionCleanupStopped else { throw CancellationError() }
                return try await self.performTerminalSessionCleanupPass(using: backend, canRetire: canRetire)
            }
        }
        signalTerminalSessionCleanup()
    }

    func signalTerminalSessionCleanup() {
        guard !terminalSessionCleanupStopped else { return }
        terminalSessionCleanupWakeups.continuation.yield(())
    }

    /// Signals only invalidate the durable query. One sleeper owns retry scheduling;
    /// both it and admitted persistence work are joined before shutdown completes.
    @concurrent nonisolated private static func runTerminalSessionCleanupLoop(
        wakeups: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation),
        delay: AsyncDelay,
        check: @escaping @MainActor @Sendable () async throws -> Bool
    ) async {
        do {
            try await delay.wait(AppPolicies.WorkspacePersistence.sessionCleanupStartupDelay)
        } catch {
            return
        }
        var sleeper: Task<Void, Never>?
        for await _ in wakeups.stream {
            sleeper?.cancel()
            await sleeper?.value
            sleeper = nil
            guard !Task.isCancelled else { break }
            let needsRetry: Bool
            do {
                needsRetry = try await check()
            } catch is CancellationError {
                break
            } catch {
                needsRetry = true
            }
            guard !Task.isCancelled else { break }
            guard needsRetry else { continue }
            sleeper = Task {
                do {
                    try await delay.wait(AppPolicies.WorkspacePersistence.sessionCleanupRetryDelay)
                    guard !Task.isCancelled else { return }
                    wakeups.continuation.yield(())
                } catch {
                    // Cancellation finishes or reschedules the sole retry delay.
                }
            }
        }
        sleeper?.cancel()
        await sleeper?.value
    }

    /// Returns whether unfinished observable work needs a bounded retry.
    func performTerminalSessionCleanupPass(
        using backend: any ZmxSessionControlling,
        canRetire: @escaping @MainActor @Sendable (ZmxSessionID) -> Bool,
        stopIncompatibleSession: @escaping @Sendable (ZmxSessionID, String) async throws -> Void = {
            try await ZmxIncompatibleSessionStop.stop(sessionID: $0, directory: $1)
        }
    ) async throws -> Bool {
        var needsRetry = false
        var cursor: ZmxSessionID?
        while true {
            try Task.checkCancellation()
            let batch = try await store.terminalSessionCleanupBatch(after: cursor)
            guard !batch.isEmpty else {
                let prunedHistory = try await store.pruneCompletedHistoryBatch()
                return needsRetry || prunedHistory
            }
            for work in batch {
                try Task.checkCancellation()
                cursor = work.sessionID
                switch work {
                case .stopIncompatible(let sessionID, let identity):
                    do {
                        let directory = sessionConfig.zmxDir
                        try await store.stopPendingIncompatibleTerminalSession(sessionID: sessionID, identity: identity)
                        {
                            guard await !self.terminalSessionCleanupStopped else { throw CancellationError() }
                            guard await canRetire(sessionID) else {
                                throw ZmxSessionControlFailure.nativeAttachmentPresent
                            }
                            try await stopIncompatibleSession(sessionID, directory)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        needsRetry = true
                    }
                case .observeIdentity(let sessionID):
                    do {
                        try await store.observePendingTerminalSession(sessionID: sessionID) {
                            guard await !self.terminalSessionCleanupStopped else { throw CancellationError() }
                            guard await canRetire(sessionID) else {
                                throw ZmxSessionControlFailure.nativeAttachmentPresent
                            }
                            return try await backend.observeSessionIdentity(sessionID)
                        }
                        // Evidence is durable before the next pass admits destructive work.
                        signalTerminalSessionCleanup()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        needsRetry = true
                    }
                case .retire(let sessionID, let identity):
                    do {
                        let result = try await store.retirePendingTerminalSession(
                            sessionID: sessionID, identity: identity
                        ) {
                            guard await !self.terminalSessionCleanupStopped else { throw CancellationError() }
                            guard await canRetire(sessionID) else {
                                throw ZmxSessionControlFailure.nativeAttachmentPresent
                            }
                            return try await backend.retireVerifiedSession(sessionID, expectedIdentity: identity)
                        }
                        if result == .pending { needsRetry = true }
                    } catch is ZmxSessionControlFailure {
                        needsRetry = true
                    }
                }
            }
        }
    }
}
