import AgentStudioInfrastructure
import Foundation

extension GitWorkingDirectoryProjector {
    func resumeShutdownsWaitingForSubscriptionStart() {
        let waitingShutdowns = startCompletionWaiters
        startCompletionWaiters.removeAll(keepingCapacity: false)
        for waiter in waitingShutdowns {
            waiter.resume()
        }
    }

    func waitForSubscriptionStartBeforeShutdown() async {
        guard isStarting else { return }
        await withCheckedContinuation { continuation in
            startCompletionWaiters.append(continuation)
        }
    }

    func didHandleRuntimeEnvelope(
        lifetime: UInt64,
        seq: UInt64,
        disposition: GitProjectorEnvelopeDisposition
    ) {
        guard lifetime == subscriptionLifetime else { return }
        emitUnreportedDroppedEnvelopeFacts(lifetime: lifetime)
        factSink?(.lifetime(lifetime), .envelopeHandled(seq: seq, disposition: disposition))
    }

    func emitUnreportedDroppedEnvelopeFacts(lifetime: UInt64) {
        guard factSink != nil, let subscriptionHandle else { return }
        let droppedCount = subscriptionHandle.deliveryCheckpoint().droppedCount
        if droppedCount > lastEmittedDroppedEnvelopeCount {
            let delta = droppedCount - lastEmittedDroppedEnvelopeCount
            lastEmittedDroppedEnvelopeCount = droppedCount
            factSink?(.lifetime(lifetime), .envelopesDropped(count: delta))
        }
    }

    func subscriptionStreamDidEnd(lifetime: UInt64) {
        guard lifetime == subscriptionLifetime, !isShuttingDown else { return }
        isShuttingDown = true
        // The subscription task cannot join itself. Schedule shutdown after its
        // loop returns, so restart cannot overlap the old lifetime's cleanup.
        Task { [weak self] in
            await self?.shutdown()
        }
    }

    func drainTaskDidExit(taskGeneration: UInt64) {
        outstandingDrainTasks.removeValue(forKey: taskGeneration)
    }

    func clearRefreshSchedulingStateAfterShutdown() {
        closeVisibilityAdmissionFacts(as: .cancelled)
        for worktreeId in Array(capacityFactOpenEpisodeByWorktreeId.keys) {
            closeCapacityFact(worktreeId: worktreeId, outcome: .cancelled)
        }
        for worktreeId in Array(backoffFactOpenEpisodeByWorktreeId.keys) {
            closeBackoffFact(worktreeId: worktreeId)
        }
        capacityRetryWorktreeIds.removeAll(keepingCapacity: false)
        capacityRetryReasonByWorktreeId.removeAll(keepingCapacity: false)
        capacityRearmedWorktreeIds.removeAll(keepingCapacity: false)
        capacityFallbackDeadlineByWorktreeId.removeAll(keepingCapacity: false)
        statusBackoffFailureCountByWorktreeId.removeAll(keepingCapacity: false)
        openStatusBackoffWorktreeIds.removeAll(keepingCapacity: false)
        statusFailureDeadlineByWorktreeId.removeAll(keepingCapacity: false)
        cancelAllDeadlineFacts()
        deadlineQueue = GitRefreshDeadlineQueue()
        deferredStatusBackoffChangesetByWorktreeId.removeAll(keepingCapacity: false)
        for worktreeId in Array(quarantinedWorktreeIds) {
            clearQuarantineState(worktreeId: worktreeId)
        }
        validatedRootPathByWorktreeId.removeAll(keepingCapacity: false)
        unchangedStatusResultCountByWorktreeId.removeAll(keepingCapacity: false)
        automaticRefreshDeadlineByWorktreeId.removeAll(keepingCapacity: false)
        lastAutomaticStartAtByWorktreeId.removeAll(keepingCapacity: false)
        lastAutomaticCompletionAtByWorktreeId.removeAll(keepingCapacity: false)
        lastAutomaticDutyByWorktreeId.removeAll(keepingCapacity: false)
        pendingByWorktreeId.removeAll(keepingCapacity: false)
        closeAllOpenIntakeFacts(as: .changesetDropped(.superseded))
        immediateRefreshWorktreeIds.removeAll(keepingCapacity: false)
        explicitRefreshWorktreeIds.removeAll(keepingCapacity: false)
        tierEligibleWorktreeIds.removeAll(keepingCapacity: false)
        admittedDemandTierByWorktreeId.removeAll(keepingCapacity: false)
        admissionStartedAtByWorktreeId.removeAll(keepingCapacity: false)
        visibleSidebarStripeCursor = 0
        lastProcessedSidebarVisibleWorktreeIds.removeAll(keepingCapacity: false)
        pendingVisibilityDeltaWorktreeIds.removeAll(keepingCapacity: false)
        coalescingWorktreeIds.removeAll(keepingCapacity: false)
    }

}
