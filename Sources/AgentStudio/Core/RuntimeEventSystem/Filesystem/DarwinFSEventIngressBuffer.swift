import AgentStudioInfrastructure
import Foundation

package final class DarwinFSEventIngressBuffer: @unchecked Sendable {
    private struct PendingActivityProcessingFence {
        let id: FSEventActivityProcessingFenceID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private let eventsStream: AsyncStream<FSEventIngressItem>
    private let eventsContinuation: AsyncStream<FSEventIngressItem>.Continuation
    private let maximumRetainedOverflowPathsPerRegistration: Int
    private let maximumRetainedActivityOverflowParticipantScopes: Int
    private let overflowHandler: @Sendable (UUID) -> Void
    private let performanceAccumulator: DarwinFSEventIngressPerformanceAccumulator
    private var overflowRecoveryByWorktreeId: [UUID: FSEventOverflowRecovery] = [:]
    private var activityOverflowRecoveryByParticipantScope: [String: FSEventActivityOverflowRecovery] = [:]
    private var coarseActivityOverflowWorktreeIds: Set<UUID> = []
    private var nextActivityProcessingFenceID: UInt64 = 0
    private var pendingActivityProcessingFence: PendingActivityProcessingFence?

    package init(
        capacity: Int,
        maximumRetainedOverflowPathsPerRegistration: Int =
            AppPolicies.FilesystemIngress.maximumRetainedOverflowPathsPerRegistration,
        maximumRetainedActivityOverflowParticipantScopes: Int =
            AppPolicies.FilesystemIngress.maximumRetainedActivityOverflowParticipantScopes,
        performanceAccumulator: DarwinFSEventIngressPerformanceAccumulator =
            DarwinFSEventIngressPerformanceAccumulator(),
        overflowHandler: @escaping @Sendable (UUID) -> Void = { _ in }
    ) {
        precondition(capacity > 0)
        precondition(maximumRetainedOverflowPathsPerRegistration > 0)
        precondition(maximumRetainedActivityOverflowParticipantScopes > 0)
        let (stream, continuation) = AsyncStream.makeStream(
            of: FSEventIngressItem.self,
            bufferingPolicy: .bufferingOldest(capacity)
        )
        eventsStream = stream
        eventsContinuation = continuation
        self.maximumRetainedOverflowPathsPerRegistration =
            maximumRetainedOverflowPathsPerRegistration
        self.maximumRetainedActivityOverflowParticipantScopes =
            maximumRetainedActivityOverflowParticipantScopes
        self.performanceAccumulator = performanceAccumulator
        self.overflowHandler = overflowHandler
    }

    package func events() -> AsyncStream<FSEventIngressItem> {
        eventsStream
    }

    package func yield(
        _ batch: FSEventBatch,
        source: DarwinFSEventIngressSource = .local
    ) {
        lock.withLock {
            switch eventsContinuation.yield(.batch(batch)) {
            case .enqueued:
                performanceAccumulator.recordIngress(
                    source: source,
                    disposition: .accepted,
                    pathCount: batch.paths.count
                )
            case .dropped(.batch(let droppedBatch)):
                performanceAccumulator.recordIngress(
                    source: source,
                    disposition: .dropped,
                    pathCount: droppedBatch.paths.count
                )
                retainOverflowRecovery(droppedBatch)
                overflowHandler(droppedBatch.worktreeId)
            case .dropped(.activityProcessingFence):
                preconditionFailure("batch yield cannot drop a previously buffered fence")
            case .dropped(.activityObservations):
                preconditionFailure("batch yield cannot drop previously buffered activity")
            case .terminated:
                performanceAccumulator.recordIngress(
                    source: source,
                    disposition: .terminated,
                    pathCount: batch.paths.count
                )
            @unknown default:
                performanceAccumulator.recordIngress(
                    source: source,
                    disposition: .dropped,
                    pathCount: batch.paths.count
                )
                retainOverflowRecovery(batch)
                overflowHandler(batch.worktreeId)
            }
        }
    }

    package func yieldActivityObservations(
        _ activityBatch: FSEventActivityObservationBatch
    ) {
        lock.withLock {
            switch eventsContinuation.yield(.activityObservations(activityBatch)) {
            case .enqueued:
                break
            case .dropped(.activityObservations(let droppedBatch)):
                retainActivityOverflowRecovery(droppedBatch)
            case .dropped(.batch(let droppedBatch)):
                retainOverflowRecovery(droppedBatch)
                overflowHandler(droppedBatch.worktreeId)
            case .dropped(.activityProcessingFence):
                preconditionFailure("activity yield cannot drop a previously buffered fence")
            case .terminated:
                retainActivityOverflowRecovery(activityBatch)
            @unknown default:
                retainActivityOverflowRecovery(activityBatch)
            }
        }
    }

    package func enqueueActivityProcessingFence() async -> Bool {
        await withCheckedContinuation { continuation in
            let shouldResumeRejected = lock.withLock { () -> Bool in
                guard pendingActivityProcessingFence == nil else { return true }
                nextActivityProcessingFenceID &+= 1
                let fenceID = FSEventActivityProcessingFenceID(
                    rawValue: nextActivityProcessingFenceID
                )
                switch eventsContinuation.yield(.activityProcessingFence(fenceID)) {
                case .enqueued:
                    pendingActivityProcessingFence = PendingActivityProcessingFence(
                        id: fenceID,
                        continuation: continuation
                    )
                    return false
                case .dropped(.activityProcessingFence):
                    return true
                case .dropped(.batch(let droppedBatch)):
                    retainOverflowRecovery(droppedBatch)
                    overflowHandler(droppedBatch.worktreeId)
                    return true
                case .dropped(.activityObservations(let droppedBatch)):
                    retainActivityOverflowRecovery(droppedBatch)
                    return true
                case .terminated:
                    return true
                @unknown default:
                    return true
                }
            }
            if shouldResumeRejected {
                continuation.resume(returning: false)
            }
        }
    }

    package func acknowledgeActivityProcessingFence(
        _ fenceID: FSEventActivityProcessingFenceID
    ) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard pendingActivityProcessingFence?.id == fenceID else { return nil }
            defer { pendingActivityProcessingFence = nil }
            return pendingActivityProcessingFence?.continuation
        }
        continuation?.resume(returning: true)
    }

    package func consumeOverflowRecoveries() -> [FSEventOverflowRecovery] {
        lock.withLock {
            defer { overflowRecoveryByWorktreeId.removeAll(keepingCapacity: true) }
            let recoveries = overflowRecoveryByWorktreeId.values.sorted {
                $0.worktreeId.uuidString < $1.worktreeId.uuidString
            }
            performanceAccumulator.recordOverflowDrain(
                recoveryCount: recoveries.count,
                retainedPathCount: recoveries.reduce(0) { $0 + ($1.paths?.count ?? 0) },
                coarseRecoveryCount: recoveries.count(where: { $0.paths == nil })
            )
            return recoveries
        }
    }

    package func consumeActivityOverflowRecoveries() -> [FSEventActivityOverflowRecovery] {
        lock.withLock {
            defer { activityOverflowRecoveryByParticipantScope.removeAll(keepingCapacity: true) }
            return activityOverflowRecoveryByParticipantScope.values.sorted {
                if $0.participant.scopeKey != $1.participant.scopeKey {
                    return $0.participant.scopeKey < $1.participant.scopeKey
                }
                return $0.participant.generation < $1.participant.generation
            }
        }
    }

    package func consumeCoarseActivityOverflowWorktreeIds() -> Set<UUID> {
        lock.withLock {
            defer { coarseActivityOverflowWorktreeIds.removeAll(keepingCapacity: true) }
            return coarseActivityOverflowWorktreeIds
        }
    }

    private func retainOverflowRecovery(_ batch: FSEventBatch) {
        if let participant = batch.participant,
            let processedThroughEventID = batch.observations.map(\.eventID).max()
        {
            retainActivityOverflowRecovery(
                FSEventActivityObservationBatch(
                    participant: participant,
                    processedThroughEventID: processedThroughEventID,
                    participantWorktreeIds: [batch.worktreeId],
                    qualifyingWorktreeIds: [],
                    coverageLostWorktreeIds: [batch.worktreeId]
                )
            )
        }
        let batchRequiresWatchedFolderScan = WatchedFolderTopologyAdmission.mayAffectTopology(batch)
        if let existing = overflowRecoveryByWorktreeId[batch.worktreeId], existing.paths == nil {
            overflowRecoveryByWorktreeId[batch.worktreeId] = FSEventOverflowRecovery(
                worktreeId: batch.worktreeId,
                paths: nil,
                requiresWatchedFolderScan: existing.requiresWatchedFolderScan
                    || batchRequiresWatchedFolderScan,
                requiresFullGitRefresh: existing.requiresFullGitRefresh
                    || batch.requiresFullGitRefresh
            )
            return
        }
        let existing = overflowRecoveryByWorktreeId[batch.worktreeId]
        var retainedPaths = existing?.paths ?? Set<String>()
        let requiresWatchedFolderScan =
            existing?.requiresWatchedFolderScan == true
            || batchRequiresWatchedFolderScan
        let requiresFullGitRefresh =
            existing?.requiresFullGitRefresh == true
            || batch.requiresFullGitRefresh
        for path in batch.paths {
            if retainedPaths.count >= maximumRetainedOverflowPathsPerRegistration,
                !retainedPaths.contains(path)
            {
                overflowRecoveryByWorktreeId[batch.worktreeId] = FSEventOverflowRecovery(
                    worktreeId: batch.worktreeId,
                    paths: nil,
                    requiresWatchedFolderScan: requiresWatchedFolderScan,
                    requiresFullGitRefresh: requiresFullGitRefresh
                )
                return
            }
            retainedPaths.insert(path)
        }
        var retainedObservationsByPath: [String: FSEventObservation] = [:]
        for observation in existing?.observations ?? [] {
            retainedObservationsByPath[observation.path] = observation
        }
        for observation in batch.observations {
            // A source loss sentinel can be excluded from ordinary paths; its coverage fact must survive.
            guard retainedPaths.contains(observation.path) || observation.hasCoverageLoss else { continue }
            let previous = retainedObservationsByPath[observation.path]
            if previous == nil,
                retainedObservationsByPath.count >= maximumRetainedOverflowPathsPerRegistration
            {
                overflowRecoveryByWorktreeId[batch.worktreeId] = FSEventOverflowRecovery(
                    worktreeId: batch.worktreeId,
                    paths: nil,
                    requiresWatchedFolderScan: requiresWatchedFolderScan,
                    requiresFullGitRefresh: requiresFullGitRefresh
                )
                return
            }
            retainedObservationsByPath[observation.path] = FSEventObservation(
                path: observation.path,
                eventID: max(previous?.eventID ?? 0, observation.eventID),
                flags: (previous?.flags ?? 0) | observation.flags
            )
        }
        overflowRecoveryByWorktreeId[batch.worktreeId] = FSEventOverflowRecovery(
            worktreeId: batch.worktreeId,
            paths: retainedPaths,
            observations: retainedObservationsByPath.values.sorted { $0.path < $1.path },
            requiresWatchedFolderScan: requiresWatchedFolderScan,
            requiresFullGitRefresh: requiresFullGitRefresh
        )
    }

    private func retainActivityOverflowRecovery(
        _ batch: FSEventActivityObservationBatch
    ) {
        let scopeKey = batch.participant.scopeKey
        if !coarseActivityOverflowWorktreeIds.isEmpty {
            coarseActivityOverflowWorktreeIds.formUnion(batch.participantWorktreeIds)
            return
        }
        if activityOverflowRecoveryByParticipantScope[scopeKey] == nil,
            activityOverflowRecoveryByParticipantScope.count
                >= maximumRetainedActivityOverflowParticipantScopes
        {
            coarseActivityOverflowWorktreeIds = Set(
                activityOverflowRecoveryByParticipantScope.values.flatMap(
                    \.coverageLostWorktreeIds
                )
            )
            coarseActivityOverflowWorktreeIds.formUnion(batch.participantWorktreeIds)
            activityOverflowRecoveryByParticipantScope.removeAll(keepingCapacity: true)
            return
        }
        let existing = activityOverflowRecoveryByParticipantScope[scopeKey]
        let retainedParticipant: FSEventParticipant
        if let existing, existing.participant.generation > batch.participant.generation {
            retainedParticipant = existing.participant
        } else {
            retainedParticipant = batch.participant
        }
        activityOverflowRecoveryByParticipantScope[scopeKey] = FSEventActivityOverflowRecovery(
            participant: retainedParticipant,
            processedThroughEventID: max(
                retainedParticipant == existing?.participant
                    ? existing?.processedThroughEventID ?? 0 : 0,
                retainedParticipant == batch.participant ? batch.processedThroughEventID : 0
            ),
            coverageLostWorktreeIds: (existing?.coverageLostWorktreeIds ?? [])
                .union(batch.participantWorktreeIds)
        )
    }

    package func finish() {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            eventsContinuation.finish()
            defer { pendingActivityProcessingFence = nil }
            return pendingActivityProcessingFence?.continuation
        }
        continuation?.resume(returning: false)
    }
}
