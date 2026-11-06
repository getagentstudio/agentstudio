import Foundation

extension DarwinFSEventStreamClient {
    package func updateWatchedFolderAdmission(worktreeId: UUID, snapshot: WatchedFolderAdmissionSnapshot?) {
        lifecycleLock.withLock {
            watchedFolderAdmissionByWorktreeId[worktreeId] = snapshot
        }
    }

    /// The callback's lifecycleLock remains held through filtering and yield, fencing snapshot replacement.
    func yieldAdmittedWatchedFolderBatchWhileLocked(_ batch: FSEventBatch) {
        if let snapshot = watchedFolderAdmissionByWorktreeId[batch.worktreeId] {
            let filtered = WatchedFolderTopologyAdmission.filterBatch(batch, snapshot: snapshot)
            ingressPerformanceAccumulator.recordWatchedFolderFilter(batch, admittedBatch: filtered)
            guard let filtered else { return }
            ingressBuffer.yield(filtered)
        } else {
            ingressBuffer.yield(batch)
        }
    }
}
