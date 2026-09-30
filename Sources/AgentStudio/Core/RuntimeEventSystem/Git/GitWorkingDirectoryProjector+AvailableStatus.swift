import AgentStudioInfrastructure
import Foundation

extension GitWorkingDirectoryProjector {
    func handleAvailableStatusResult(
        _ statusSnapshot: GitWorkingTreeStatus,
        materialized: MaterializedGitStatus,
        changeset: FileChangeset,
        context: StatusCompletionContext
    ) async {
        let statusCompletion = envelopeClock.now
        let statusDuration = context.computeStart.duration(to: statusCompletion)
        consecutiveStatusFailureCountByWorktreeId.removeValue(forKey: changeset.worktreeId)
        performanceTraceRecorder?.recordDuration(
            .gitStatusComputed,
            duration: statusDuration,
            attributes: gitStatusCompletionTraceAttributes(
                for: changeset,
                unavailable: nil,
                context: GitStatusCompletionTraceContext(
                    scope: context.scope,
                    pathspecCount: context.pathspecCount,
                    statusCompletion: statusCompletion,
                    outcome: .completed,
                    consecutiveFailureCount: 0,
                    statusDuration: statusDuration
                )
            )
        )
        guard !Task.isCancelled, !isShuttingDown else { return }
        guard !suppressedWorktreeIds.contains(changeset.worktreeId) else { return }
        guard isCurrentForPublication(changeset) else { return }
        let currentStatusSnapshot = await prepareRemoteReferenceCurrentStatus(
            statusSnapshot,
            changeset: changeset
        )
        guard !Task.isCancelled, !isShuttingDown, isCurrentForPublication(changeset),
            RepositoryObservationRequestContext.worktree == observationLifetimesByWorktreeID[changeset.worktreeId]
        else { return }
        admissionStartedAtByWorktreeId.removeValue(forKey: changeset.worktreeId)
        clearCapacityRetryState(worktreeId: changeset.worktreeId)
        resetStatusBackoff(worktreeId: changeset.worktreeId)
        let previousAccepted = acceptedStatusBaseline(for: changeset.worktreeId)
        let currentAcceptedFacts = GitWorkingTreeStatusFacts(status: currentStatusSnapshot)
        let completeStatusChanged =
            previousAccepted.facts != currentAcceptedFacts
            || previousAccepted.detail != materialized.detail
        lastStatusEntriesByWorktreeId[changeset.worktreeId] = currentStatusSnapshot.entries
        lastAcceptedStatusFactsByWorktreeId[changeset.worktreeId] = currentAcceptedFacts
        acceptExactCleanAuthority(from: materialized, scope: context.scope, changeset: changeset)
        if let detail = materialized.detail {
            lastAcceptedLineDetailByWorktreeId[changeset.worktreeId] = detail
            if materialized.refreshedDetail {
                lastAcceptedLineDetailAtByWorktreeId[changeset.worktreeId] = deadlineClock.now
            }
        }

        let nextSnapshot = GitWorkingTreeSnapshot(
            worktreeId: changeset.worktreeId,
            repoId: changeset.repoId,
            rootPath: changeset.rootPath,
            summary: currentStatusSnapshot.summary,
            branch: currentStatusSnapshot.branch
        )
        let previousSnapshot = lastEmittedSnapshotByWorktreeId[changeset.worktreeId]
        let snapshotChanged = previousSnapshot != nextSnapshot
        if completeStatusChanged {
            resetAdaptiveCadence(worktreeId: changeset.worktreeId)
        } else if pendingByWorktreeId[changeset.worktreeId] == nil {
            unchangedStatusResultCountByWorktreeId[changeset.worktreeId, default: 0] += 1
        }
        if snapshotChanged {
            lastEmittedSnapshotByWorktreeId[changeset.worktreeId] = nextSnapshot
        } else {
            aggregatePerformance.increment(\.snapshotEqual)
            flushAggregatePerformanceSnapshotIfNeeded()
        }
        settleCompletedRepositoryRecomputationTarget(worktreeId: changeset.worktreeId)
        completeAdmittedRequiredIntent(worktreeId: changeset.worktreeId)
        recordAutomaticCompletion(worktreeId: changeset.worktreeId, duty: statusDuration)

        await emitCompletedStatusOutcome(for: changeset)
        if snapshotChanged {
            await emitGitWorkingDirectoryEvent(
                worktreeId: changeset.worktreeId,
                repoId: changeset.repoId,
                event: .snapshotChanged(snapshot: nextSnapshot)
            )
        }

        var branchChanged = false
        if let previousSnapshot,
            let nextBranch = currentStatusSnapshot.branch,
            previousSnapshot.branch != nextBranch
        {
            await emitGitWorkingDirectoryEvent(
                worktreeId: changeset.worktreeId,
                repoId: changeset.repoId,
                event: .branchChanged(
                    worktreeId: changeset.worktreeId,
                    repoId: changeset.repoId,
                    from: previousSnapshot.branch ?? "",
                    to: nextBranch
                )
            )
            branchChanged = true
        }
        closeCompletedRefreshFact(
            worktreeId: changeset.worktreeId,
            ifCurrent: context.refreshFactScope,
            snapshotChanged: snapshotChanged,
            branchChanged: branchChanged
        )
    }

    private func closeCompletedRefreshFact(
        worktreeId: UUID,
        ifCurrent refreshFactScope: GitProjectorScope?,
        snapshotChanged: Bool,
        branchChanged: Bool
    ) {
        closeRefreshFact(
            worktreeId: worktreeId,
            ifCurrent: refreshFactScope,
            outcome: snapshotChanged || branchChanged
                ? .completed(snapshotChanged: snapshotChanged, branchChanged: branchChanged)
                : .equal
        )
    }

    private func emitCompletedStatusOutcome(for changeset: FileChangeset) async {
        await emitGitWorkingDirectoryEvent(
            worktreeId: changeset.worktreeId,
            repoId: changeset.repoId,
            event: .statusOutcome(
                GitStatusOutcomeFact(
                    worktreeId: changeset.worktreeId,
                    repoId: changeset.repoId,
                    outcome: .completed,
                    reason: nil,
                    consecutiveFailureCount: 0
                ))
        )
    }

    private func acceptExactCleanAuthority(
        from materialized: MaterializedGitStatus,
        scope: GitStatusScope,
        changeset: FileChangeset
    ) {
        let authority = materialized.facts.exactCleanAuthority
        let worktreeId = changeset.worktreeId
        if scope == .full, let authority {
            exactCleanAuthorityByWorktreeId[worktreeId] = authority
            recordExactCleanBaselineAcceptedTelemetry()
        } else {
            exactCleanAuthorityByWorktreeId.removeValue(forKey: worktreeId)
        }
    }

    private func acceptedStatusBaseline(
        for worktreeId: UUID
    ) -> (facts: GitWorkingTreeStatusFacts?, detail: GitWorkingTreeLineDetail?) {
        (
            facts: lastAcceptedStatusFactsByWorktreeId[worktreeId],
            detail: lastAcceptedLineDetailByWorktreeId[worktreeId]
        )
    }
}
