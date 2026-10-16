extension BridgeWorktreeProductConstructionCoordinator {
    /// Only verified work on the current producer can extend its consumers' progress windows.
    /// Admission, joins and diagnostics never enter this path.
    func reportReviewProgress(
        _ phase: BridgeReviewConstructionPhase,
        entryNonce: UInt64,
        epoch: BridgeWorktreeFreshnessEpoch
    ) {
        guard !isClosed,
            var entry = entriesByNonce[entryNonce],
            case .review = entry.identity.key,
            case .building = entry.phase,
            entry.identity.epoch == epoch,
            epoch == currentEpoch(for: entry.identity.key.worktree),
            entry.completedReviewPhases.insert(phase).inserted
        else { return }
        entriesByNonce[entryNonce] = entry
        for waiter in entry.waiters.values where !waiter.cancellationState.isCancelled {
            waiter.reviewProgress?(phase)
        }
    }
}
