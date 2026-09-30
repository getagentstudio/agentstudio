import Foundation

/// Envelope emission for derived git facts: sequences, posts to the runtime
/// bus, and records delivery telemetry. Split from the projector actor body
/// to keep it under the type/file length caps.
extension GitWorkingDirectoryProjector {
    func emitGitWorkingDirectoryEvent(
        worktreeId: UUID,
        repoId: UUID,
        event: GitWorkingDirectoryEvent
    ) async {
        let capturedLifetime = RepositoryObservationRequestContext.worktree
        guard capturedLifetime == observationLifetimesByWorktreeID[worktreeId] else { return }
        nextEnvelopeSequence += 1
        let envelope = RuntimeEnvelope.worktree(
            WorktreeEnvelope(
                source: .system(.builtin(.gitWorkingDirectoryProjector)),
                seq: nextEnvelopeSequence,
                timestamp: envelopeClock.now,
                repoId: repoId,
                worktreeId: worktreeId,
                event: .gitWorkingDirectory(event),
                observationLifetime: capturedLifetime.map(RepositoryFactObservationLifetime.worktree) ?? .unscoped
            )
        )

        let droppedCount = (await runtimeEnvelopePoster.post(envelope)).droppedCount
        if droppedCount > 0 {
            Self.logger.warning(
                "Git projector event delivery dropped for \(droppedCount, privacy: .public) subscriber(s); seq=\(self.nextEnvelopeSequence, privacy: .public)"
            )
        }
        aggregatePerformance.increment(\.eventPosted)
        aggregatePerformance.increment(\.droppedSubscriber, by: droppedCount)
        flushAggregatePerformanceSnapshotIfNeeded()
        Self.logger.debug("Posted git projector event for worktree \(worktreeId.uuidString, privacy: .public)")
    }
}
