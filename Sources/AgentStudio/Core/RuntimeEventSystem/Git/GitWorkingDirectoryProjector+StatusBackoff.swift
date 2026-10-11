import AgentStudioInfrastructure
import Foundation

/// Status-compute backoff (circuit breaker): a worktree whose git status
/// fails is refreshed on an exponential schedule instead of
/// per file-change event; change events arriving during backoff coalesce
/// into one deferred refresh at expiry. Split from the projector actor body
/// to keep it under the type/file length caps.
extension GitWorkingDirectoryProjector {
    var hasGlobalCapacityRetryPause: Bool {
        capacityRetryReasonByWorktreeId.values.contains(.readCapacityExceeded)
    }

    func deferChangesetIfStatusBackoffOpen(_ changeset: FileChangeset) -> Bool {
        guard openStatusBackoffWorktreeIds.contains(changeset.worktreeId) else { return false }
        coalesceDeferredStatusBackoffChangeset(changeset)
        return true
    }

    func coalesceDeferredStatusBackoffChangeset(_ changeset: FileChangeset) {
        let worktreeId = changeset.worktreeId
        guard let existing = deferredStatusBackoffChangesetByWorktreeId[worktreeId] else {
            deferredStatusBackoffChangesetByWorktreeId[worktreeId] = changeset
            return
        }
        deferredStatusBackoffChangesetByWorktreeId[worktreeId] = mergeTrackedChangesets(existing, with: changeset)
    }

    /// Opens (or advances) the per-worktree circuit breaker after a status
    /// compute fails. Quiesces the worktree by moving any in-flight/pending
    /// refresh into a single deferred changeset, then schedules an exponentially
    /// growing expiry.
    func openOrAdvanceStatusBackoff(
        for changeset: FileChangeset,
        reason: GitWorkingTreeStatusUnavailableReason
    ) {
        guard !isShuttingDown else { return }
        let worktreeId = changeset.worktreeId
        guard isAutomaticEligible(worktreeId: worktreeId) || hasRequiredIntent(worktreeId: worktreeId) else {
            return
        }

        let failureCount = (statusBackoffFailureCountByWorktreeId[worktreeId] ?? 0) + 1
        statusBackoffFailureCountByWorktreeId[worktreeId] = failureCount
        openStatusBackoffWorktreeIds.insert(worktreeId)

        // Quiesce: fold any pending compute plus the failed changeset into the
        // single deferred slot so nothing recomputes during the open window.
        if let pending = pendingByWorktreeId.removeValue(forKey: worktreeId) {
            coalesceDeferredStatusBackoffChangeset(pending)
        }
        coalesceDeferredStatusBackoffChangeset(changeset)

        let backoffDelay = refreshPolicy.statusFailureBackoffDelay(forConsecutiveFailureCount: failureCount)
        setRefreshDeadline(deadlineClock.now + backoffDelay, kind: .failure, worktreeId: worktreeId)
        emitStatusBackoffTelemetry(
            worktreeId: worktreeId,
            open: true,
            reason: reason,
            backoffDelay: backoffDelay,
            attempt: failureCount
        )

        rescheduleDeadlineTask()
        recordBackoffFact(worktreeId: worktreeId, level: failureCount)
    }

    /// Fires exactly one coalesced deferred refresh when the backoff window
    /// expires (half-open). The breaker closes only when that refresh succeeds
    /// via `resetStatusBackoff`; if it fails again the breaker re-opens with a
    /// longer window.
    func expireStatusBackoff(worktreeId: UUID) {
        statusFailureDeadlineByWorktreeId.removeValue(forKey: worktreeId)
        guard openStatusBackoffWorktreeIds.remove(worktreeId) != nil else { return }
        guard !isShuttingDown else {
            deferredStatusBackoffChangesetByWorktreeId.removeValue(forKey: worktreeId)
            closeBackoffFact(worktreeId: worktreeId)
            return
        }
        guard !suppressedWorktreeIds.contains(worktreeId) else {
            deferredStatusBackoffChangesetByWorktreeId.removeValue(forKey: worktreeId)
            closeBackoffFact(worktreeId: worktreeId)
            return
        }
        guard let deferredChangeset = deferredStatusBackoffChangesetByWorktreeId.removeValue(forKey: worktreeId) else {
            closeBackoffFact(worktreeId: worktreeId)
            return
        }
        guard isCurrent(deferredChangeset) else {
            closeBackoffFact(worktreeId: worktreeId)
            return
        }
        pendingByWorktreeId[worktreeId] = mergeTrackedChangesets(
            pendingByWorktreeId[worktreeId],
            with: deferredChangeset
        )
        if refreshAttribution.admittedDemandClassByWorktreeId[worktreeId] == "explicit" {
            explicitRefreshWorktreeIds.insert(worktreeId)
        } else {
            tierEligibleWorktreeIds.insert(worktreeId)
        }
        admitPendingWorktrees()
        rescheduleDeadlineTask()
        recordBackoffHalfOpenFact(worktreeId: worktreeId)
    }

    func deferChangesetIfCapacityRetryPending(_ changeset: FileChangeset) -> Bool {
        guard capacityRetryWorktreeIds.contains(changeset.worktreeId) else { return false }
        coalesceCapacityRetryChangeset(changeset)
        return true
    }

    func scheduleCapacityRetry(
        for changeset: FileChangeset,
        reason: GitWorkingTreeStatusUnavailableReason,
        afterPhysicalCompletionGeneration completionGeneration: UInt64?
    ) {
        guard !isShuttingDown else { return }
        guard reason == .readCapacityExceeded || reason == .readAlreadyInFlight else { return }
        let worktreeId = changeset.worktreeId
        guard isAutomaticEligible(worktreeId: worktreeId) || hasRequiredIntent(worktreeId: worktreeId) else {
            return
        }
        capacityRetryWorktreeIds.insert(worktreeId)
        capacityRetryReasonByWorktreeId[worktreeId] = reason
        capacityRearmedWorktreeIds.insert(worktreeId)
        coalesceCapacityRetryChangeset(changeset)
        if refreshAttribution.admittedDemandClassByWorktreeId[worktreeId] == "explicit" {
            explicitRefreshWorktreeIds.insert(worktreeId)
        } else {
            tierEligibleWorktreeIds.insert(worktreeId)
        }
        let retryDelay = refreshPolicy.capacityRetryDelay(for: worktreeId)
        setRefreshDeadline(
            deadlineClock.now + retryDelay,
            kind: .capacityFallback,
            worktreeId: worktreeId
        )
        if let completionGeneration {
            startCapacityCompletionWait(after: completionGeneration)
        }
        rescheduleDeadlineTask()
        openCapacityFactIfNeeded(worktreeId: worktreeId)
    }

    private func startCapacityCompletionWait(after generation: UInt64) {
        guard capacityCompletionTask == nil else { return }
        let provider = gitWorkingTreeProvider
        capacityCompletionTask = Task { [weak self, provider] in
            await provider.waitForPhysicalCompletion(after: generation)
            guard !Task.isCancelled else { return }
            await self?.physicalCapacityDidComplete()
        }
    }

    private func physicalCapacityDidComplete() {
        capacityCompletionTask = nil
        let deferredWorktreeIds = capacityRetryWorktreeIds
        capacityRetryWorktreeIds.removeAll(keepingCapacity: true)
        capacityRetryReasonByWorktreeId.removeAll(keepingCapacity: true)
        for worktreeId in deferredWorktreeIds {
            capacityFallbackDeadlineByWorktreeId.removeValue(forKey: worktreeId)
            closeDeadlineFact(worktreeId: worktreeId, sourceKind: .capacityFallback, disposition: .obsolete)
            closeCapacityFact(worktreeId: worktreeId, outcome: .rearmed)
        }
        admitPendingWorktrees()
        rescheduleDeadlineTask()
    }

    func expireCapacityRetry(worktreeId: UUID) {
        capacityFallbackDeadlineByWorktreeId.removeValue(forKey: worktreeId)
        guard capacityRetryWorktreeIds.remove(worktreeId) != nil else { return }
        defer {
            closeCapacityFact(worktreeId: worktreeId, outcome: .expired)
        }
        capacityRetryReasonByWorktreeId.removeValue(forKey: worktreeId)
        guard !isShuttingDown else {
            capacityRearmedWorktreeIds.remove(worktreeId)
            pendingByWorktreeId.removeValue(forKey: worktreeId)
            return
        }
        guard !suppressedWorktreeIds.contains(worktreeId) else {
            capacityRearmedWorktreeIds.remove(worktreeId)
            pendingByWorktreeId.removeValue(forKey: worktreeId)
            return
        }
        guard let pendingChangeset = pendingByWorktreeId[worktreeId] else {
            capacityRearmedWorktreeIds.remove(worktreeId)
            return
        }
        guard isCurrent(pendingChangeset) else {
            capacityRearmedWorktreeIds.remove(worktreeId)
            pendingByWorktreeId.removeValue(forKey: worktreeId)
            return
        }
        admitPendingWorktrees()
        rescheduleDeadlineTask()
    }

    @discardableResult
    func clearCapacityRetryState(worktreeId: UUID) -> Bool {
        let hadGlobalCapacityRetryPause = hasGlobalCapacityRetryPause
        capacityRetryWorktreeIds.remove(worktreeId)
        capacityRetryReasonByWorktreeId.removeValue(forKey: worktreeId)
        capacityRearmedWorktreeIds.remove(worktreeId)
        capacityFallbackDeadlineByWorktreeId.removeValue(forKey: worktreeId)
        cancelDeadlineFact(worktreeId: worktreeId, sourceKind: .capacityFallback)
        if capacityRetryWorktreeIds.isEmpty {
            capacityCompletionTask?.cancel()
            capacityCompletionTask = nil
        }
        rescheduleDeadlineTask()
        closeCapacityFact(worktreeId: worktreeId, outcome: .cancelled)
        return hadGlobalCapacityRetryPause && !hasGlobalCapacityRetryPause
    }

    private func coalesceCapacityRetryChangeset(_ changeset: FileChangeset) {
        let worktreeId = changeset.worktreeId
        guard let existing = pendingByWorktreeId[worktreeId] else {
            pendingByWorktreeId[worktreeId] = changeset
            return
        }
        pendingByWorktreeId[worktreeId] = mergeTrackedChangesets(existing, with: changeset)
    }

    /// Closes the breaker after a successful compute, clearing the failure count
    /// and any pending expiry, and emits a close fact when the breaker was armed.
    func resetStatusBackoff(worktreeId: UUID) {
        let hadFailures = statusBackoffFailureCountByWorktreeId.removeValue(forKey: worktreeId) != nil
        statusFailureDeadlineByWorktreeId.removeValue(forKey: worktreeId)
        closeDeadlineFact(worktreeId: worktreeId, sourceKind: .failure, disposition: .obsolete)
        let wasOpen = openStatusBackoffWorktreeIds.remove(worktreeId) != nil
        deferredStatusBackoffChangesetByWorktreeId.removeValue(forKey: worktreeId)
        rescheduleDeadlineTask()
        guard hadFailures || wasOpen else { return }
        emitStatusBackoffTelemetry(worktreeId: worktreeId, open: false, reason: nil, backoffDelay: .zero, attempt: 0)
        closeBackoffFact(worktreeId: worktreeId)
    }

    func clearStatusBackoffState(worktreeId: UUID) {
        statusFailureDeadlineByWorktreeId.removeValue(forKey: worktreeId)
        cancelDeadlineFact(worktreeId: worktreeId, sourceKind: .failure)
        statusBackoffFailureCountByWorktreeId.removeValue(forKey: worktreeId)
        openStatusBackoffWorktreeIds.remove(worktreeId)
        deferredStatusBackoffChangesetByWorktreeId.removeValue(forKey: worktreeId)
        rescheduleDeadlineTask()
        closeBackoffFact(worktreeId: worktreeId)
    }

    func emitStatusBackoffTelemetry(
        worktreeId: UUID,
        open: Bool,
        reason: GitWorkingTreeStatusUnavailableReason?,
        backoffDelay: Duration,
        attempt: Int
    ) {
        guard let performanceTraceRecorder else { return }
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.worktree.id": .string(worktreeId.uuidString),
            "agentstudio.performance.git.backoff_open": .bool(open),
            "agentstudio.performance.git.backoff_ms": .double(
                AgentStudioPerformanceTraceRecorder.milliseconds(from: backoffDelay)
            ),
            "agentstudio.performance.git.backoff_attempt.count": .int(attempt),
            "agentstudio.performance.git.pending.count": .int(pendingByWorktreeId.count),
            "agentstudio.performance.git.running.count": .int(worktreeTasks.count),
        ]
        if let reason {
            attributes["agentstudio.performance.git.backoff.reason"] = .string(reason.rawValue)
        }
        performanceTraceRecorder.record(.gitBackoff, attributes: attributes)
    }

    nonisolated static func mergeChangesets(
        _ existing: FileChangeset?,
        with incoming: FileChangeset
    ) -> FileChangeset {
        guard let existing else { return incoming }
        let freshest: FileChangeset
        if existing.timestamp != incoming.timestamp {
            freshest = existing.timestamp > incoming.timestamp ? existing : incoming
        } else {
            freshest = existing.batchSeq >= incoming.batchSeq ? existing : incoming
        }
        // Empty paths request a full refresh, including origin discovery. A narrower
        // file change must not discard that pending obligation during coalescing.
        let mergedPaths =
            existing.paths.isEmpty || incoming.paths.isEmpty
            ? [] : normalizedPathspecs(existing.paths + incoming.paths)
        return FileChangeset(
            worktreeId: freshest.worktreeId,
            repoId: freshest.repoId,
            rootPath: freshest.rootPath,
            paths: mergedPaths,
            containsGitInternalChanges: existing.containsGitInternalChanges || incoming.containsGitInternalChanges,
            suppressedIgnoredPathCount: existing.suppressedIgnoredPathCount + incoming.suppressedIgnoredPathCount,
            suppressedGitInternalPathCount: existing.suppressedGitInternalPathCount
                + incoming.suppressedGitInternalPathCount,
            timestamp: freshest.timestamp,
            batchSeq: freshest.batchSeq
        )
    }
}
