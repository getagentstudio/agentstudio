import AgentStudioCore
import Foundation

/// Controllable FSEvent stream client for tests.
/// Tracks registrations/unregistrations and lets tests inject batches explicitly.
package final class ControllableFSEventStreamClient: FSEventStreamClient, @unchecked Sendable {
    private let lock = NSLock()
    private var activeIds = Set<UUID>()
    private var registeredIds: [UUID] = []
    private var unregisteredIds: [UUID] = []
    private var continuation: AsyncStream<FSEventIngressItem>.Continuation?
    private var stream: AsyncStream<FSEventIngressItem>?
    private var overflowRecoveryByWorktreeId: [UUID: FSEventOverflowRecovery] = [:]
    private var activityOverflowRecoveryByParticipant: [FSEventParticipant: FSEventActivityOverflowRecovery] = [:]
    private var acknowledgedActivityProcessingFenceIds: [FSEventActivityProcessingFenceID] = []
    private var nextRegistrationOutcome: FSEventStreamRegistrationOutcome = .observing
    private var activityBarrier: FSEventActivityBarrier?
    private let ingressBuffer: DarwinFSEventIngressBuffer?

    package init(ingressBuffer: DarwinFSEventIngressBuffer? = nil) {
        self.ingressBuffer = ingressBuffer
        let (stream, continuation) = AsyncStream<FSEventIngressItem>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stream = stream
        self.continuation = continuation
    }

    package var activeWorktreeIds: Set<UUID> { lock.withLock { activeIds } }

    package var registeredWorktreeIds: [UUID] {
        lock.withLock { registeredIds }
    }

    package var unregisteredWorktreeIds: [UUID] {
        lock.withLock { unregisteredIds }
    }

    package var acknowledgedActivityProcessingFenceIDs: [FSEventActivityProcessingFenceID] {
        lock.withLock { acknowledgedActivityProcessingFenceIds }
    }

    package func events() -> AsyncStream<FSEventIngressItem> {
        if let ingressBuffer { return ingressBuffer.events() }
        return lock.withLock { stream! }
    }

    package func consumeOverflowRecoveries() -> [FSEventOverflowRecovery] {
        if let ingressBuffer { return ingressBuffer.consumeOverflowRecoveries() }
        return lock.withLock {
            defer { overflowRecoveryByWorktreeId.removeAll(keepingCapacity: true) }
            return overflowRecoveryByWorktreeId.values.sorted {
                $0.worktreeId.uuidString < $1.worktreeId.uuidString
            }
        }
    }

    package func consumeActivityOverflowRecoveries() -> [FSEventActivityOverflowRecovery] {
        lock.withLock {
            defer { activityOverflowRecoveryByParticipant.removeAll(keepingCapacity: true) }
            return activityOverflowRecoveryByParticipant.values.sorted {
                if $0.participant.scopeKey != $1.participant.scopeKey {
                    return $0.participant.scopeKey < $1.participant.scopeKey
                }
                return $0.participant.generation < $1.participant.generation
            }
        }
    }

    package func sendOverflowRecovery(
        worktreeId: UUID,
        paths: Set<String>? = nil,
        requiresWatchedFolderScan: Bool = false,
        requiresFullGitRefresh: Bool = false
    ) {
        lock.withLock {
            let existing = overflowRecoveryByWorktreeId[worktreeId]
            let mergedPaths = paths.map {
                (existing?.paths ?? []).union($0)
            }
            overflowRecoveryByWorktreeId[worktreeId] = FSEventOverflowRecovery(
                worktreeId: worktreeId,
                paths: existing?.paths == nil && existing != nil ? nil : mergedPaths,
                requiresWatchedFolderScan: existing?.requiresWatchedFolderScan == true
                    || requiresWatchedFolderScan,
                requiresFullGitRefresh: existing?.requiresFullGitRefresh == true
                    || requiresFullGitRefresh
            )
        }
    }

    package func sendActivityOverflowRecovery(
        participant: FSEventParticipant,
        processedThroughEventID: UInt64,
        coverageLostWorktreeIds: Set<UUID>
    ) {
        lock.withLock {
            let existing = activityOverflowRecoveryByParticipant[participant]
            activityOverflowRecoveryByParticipant[participant] = FSEventActivityOverflowRecovery(
                participant: participant,
                processedThroughEventID: max(
                    existing?.processedThroughEventID ?? 0,
                    processedThroughEventID
                ),
                coverageLostWorktreeIds: (existing?.coverageLostWorktreeIds ?? [])
                    .union(coverageLostWorktreeIds)
            )
        }
    }

    package func setNextRegistrationOutcome(_ outcome: FSEventStreamRegistrationOutcome) {
        lock.withLock { nextRegistrationOutcome = outcome }
    }

    package func register(
        worktreeId: UUID,
        repoId: UUID,
        rootPath: URL
    ) -> FSEventStreamRegistrationOutcome {
        lock.withLock {
            let outcome = nextRegistrationOutcome
            nextRegistrationOutcome = .observing
            if outcome == .observing {
                registeredIds.append(worktreeId)
                activeIds.insert(worktreeId)
            }
            return outcome
        }
    }

    package func unregister(worktreeId: UUID) {
        lock.withLock {
            unregisteredIds.append(worktreeId)
            activeIds.remove(worktreeId)
        }
    }

    package func shutdown() {
        ingressBuffer?.finish()
        continuation?.finish()
    }

    package func acknowledgeActivityProcessingFence(
        _ fenceID: FSEventActivityProcessingFenceID
    ) {
        lock.withLock { acknowledgedActivityProcessingFenceIds.append(fenceID) }
    }

    package func captureActivityBarrier() async -> FSEventActivityBarrier? {
        lock.withLock { activityBarrier }
    }

    package func setActivityBarrier(_ barrier: FSEventActivityBarrier?) {
        lock.withLock { activityBarrier = barrier }
    }

    package func send(_ batch: FSEventBatch) {
        if let ingressBuffer {
            ingressBuffer.yield(batch)
        } else {
            continuation?.yield(.batch(batch))
        }
    }

    package func sendActivityProcessingFence(_ fenceID: FSEventActivityProcessingFenceID) {
        continuation?.yield(.activityProcessingFence(fenceID))
    }
}
