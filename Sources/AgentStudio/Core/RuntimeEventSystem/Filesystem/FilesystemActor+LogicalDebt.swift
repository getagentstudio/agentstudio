import AgentStudioInfrastructure
import Foundation

struct FilesystemLogicalDebtTraceIdentity: Equatable, Sendable {
    let pendingWorktreeCount: Int
    let drainTaskCount: Int
    let watchedFolderPacedPendingCount: Int
    let watchedFolderReadyCount: Int
    let watchedFolderActiveCount: Int
    let watchedFolderDirtyFollowUpCount: Int
}

struct FilesystemLogicalDebtSnapshot: Equatable, Sendable {
    let pendingWorktreeCount: Int
    let drainTaskCount: Int
    /// Actor-owned obligations remain outstanding until covering completion or retirement;
    /// scheduler custody is counted independently, including while submission is in flight.
    let watchedFolderPacedPendingCount: Int
    let watchedFolderReadyCount: Int
    let watchedFolderActiveQuantumCount: Int
    let watchedFolderAwaitingValidationCount: Int
    let watchedFolderPendingResultCount: Int
    let watchedFolderLeasedResultCount: Int
    let watchedFolderDirtyFollowUpCount: Int

    var watchedFolderActiveCount: Int {
        watchedFolderActiveQuantumCount
            + watchedFolderAwaitingValidationCount
            + watchedFolderPendingResultCount
            + watchedFolderLeasedResultCount
    }

    var logicalDebtCount: Int {
        pendingWorktreeCount
            + drainTaskCount
            + watchedFolderPacedPendingCount
            + watchedFolderReadyCount
            + watchedFolderActiveCount
            + watchedFolderDirtyFollowUpCount
    }

    var traceIdentity: FilesystemLogicalDebtTraceIdentity {
        FilesystemLogicalDebtTraceIdentity(
            pendingWorktreeCount: pendingWorktreeCount,
            drainTaskCount: drainTaskCount,
            watchedFolderPacedPendingCount: watchedFolderPacedPendingCount,
            watchedFolderReadyCount: watchedFolderReadyCount,
            watchedFolderActiveCount: watchedFolderActiveCount,
            watchedFolderDirtyFollowUpCount: watchedFolderDirtyFollowUpCount
        )
    }

    var traceAttributes: [String: AgentStudioTraceValue] {
        [
            "agentstudio.performance.filesystem.pending_worktree.count": .int(pendingWorktreeCount),
            "agentstudio.performance.filesystem.drain_task.count": .int(drainTaskCount),
            "agentstudio.performance.filesystem.watched_folder.paced_pending.count": .int(
                watchedFolderPacedPendingCount),
            "agentstudio.performance.filesystem.watched_folder.ready.count": .int(watchedFolderReadyCount),
            "agentstudio.performance.filesystem.watched_folder.active.count": .int(watchedFolderActiveCount),
            "agentstudio.performance.filesystem.watched_folder.dirty_follow_up.count": .int(
                watchedFolderDirtyFollowUpCount
            ),
            "agentstudio.performance.filesystem.logical_debt.count": .int(logicalDebtCount),
        ]
    }
}

extension FilesystemActor {
    package func logicalDebtCount() async -> Int {
        await logicalDebtSnapshot().logicalDebtCount
    }

    func logicalDebtSnapshot() async -> FilesystemLogicalDebtSnapshot {
        makeLogicalDebtSnapshot(
            watchedFolderSchedulerState: await watchedFolderScanScheduler.stateSnapshot(),
            pendingWorktreeCount: pendingWorktreeLogicalDebtCount,
            drainTaskCount: drainTaskLogicalDebtCount
        )
    }

    func recordLogicalDebtSnapshotIfChanged() async {
        let scheduler = watchedFolderScanScheduler
        await recordLogicalDebtSnapshotIfChanged(
            watchedFolderStateSnapshot: { await scheduler.stateSnapshot() }
        )
    }

    func recordLogicalDebtSnapshotIfChanged(
        watchedFolderStateSnapshot: @Sendable () async -> WatchedFolderScanSchedulerStateSnapshot
    ) async {
        guard performanceTraceRecorder?.isEnabled == true else { return }
        logicalDebtSnapshotPublicationRevision &+= 1
        let publicationRevision = logicalDebtSnapshotPublicationRevision
        let watchedFolderSchedulerState = await watchedFolderStateSnapshot()
        guard logicalDebtSnapshotPublicationRevision == publicationRevision else { return }
        let pendingWorktreeCount = pendingWorktreeLogicalDebtCount
        let drainTaskCount = drainTaskLogicalDebtCount
        let snapshot = makeLogicalDebtSnapshot(
            watchedFolderSchedulerState: watchedFolderSchedulerState,
            pendingWorktreeCount: pendingWorktreeCount,
            drainTaskCount: drainTaskCount
        )
        guard snapshot.traceIdentity != lastRecordedLogicalDebtSnapshot?.traceIdentity else { return }
        lastRecordedLogicalDebtSnapshot = snapshot
        performanceTraceRecorder?.record(
            .filesystemLogicalDebt,
            attributes: snapshot.traceAttributes
        )
    }

    private func makeLogicalDebtSnapshot(
        watchedFolderSchedulerState: WatchedFolderScanSchedulerStateSnapshot,
        pendingWorktreeCount: Int,
        drainTaskCount: Int
    ) -> FilesystemLogicalDebtSnapshot {
        let pacedPendingCount = watchedFolderScanState.pacing.obligationsBySourceID.count
        switch watchedFolderSchedulerState {
        case .active(let activeState):
            return FilesystemLogicalDebtSnapshot(
                pendingWorktreeCount: pendingWorktreeCount,
                drainTaskCount: drainTaskCount,
                watchedFolderPacedPendingCount: pacedPendingCount,
                watchedFolderReadyCount: activeState.ready,
                watchedFolderActiveQuantumCount: activeState.activeQuanta,
                watchedFolderAwaitingValidationCount: activeState.awaitingValidations,
                watchedFolderPendingResultCount: activeState.pendingResults,
                watchedFolderLeasedResultCount: activeState.leasedResults,
                watchedFolderDirtyFollowUpCount: activeState.dirtyFollowUps
            )
        case .shuttingDown(let custodyState):
            return FilesystemLogicalDebtSnapshot(
                pendingWorktreeCount: pendingWorktreeCount,
                drainTaskCount: drainTaskCount,
                watchedFolderPacedPendingCount: pacedPendingCount,
                watchedFolderReadyCount: 0,
                watchedFolderActiveQuantumCount: custodyState.activeQuanta,
                watchedFolderAwaitingValidationCount: custodyState.awaitingValidations,
                watchedFolderPendingResultCount: custodyState.pendingResults,
                watchedFolderLeasedResultCount: custodyState.leasedResults,
                watchedFolderDirtyFollowUpCount: 0
            )
        case .shutDown:
            return FilesystemLogicalDebtSnapshot(
                pendingWorktreeCount: pendingWorktreeCount,
                drainTaskCount: drainTaskCount,
                watchedFolderPacedPendingCount: pacedPendingCount,
                watchedFolderReadyCount: 0,
                watchedFolderActiveQuantumCount: 0,
                watchedFolderAwaitingValidationCount: 0,
                watchedFolderPendingResultCount: 0,
                watchedFolderLeasedResultCount: 0,
                watchedFolderDirtyFollowUpCount: 0
            )
        }
    }
}
