import Foundation

extension SessionsIngestion {
    func applyClosedAppOutboxItem(
        _ item: ClosedAppOutboxItem, restoreEvidence: any ClosedAppRestoreEvidenceParticipant,
        participants: [any SessionsCommitParticipant]
    ) async throws -> ClosedAppOutboxOutcome {
        if let paneId = item.paneId { try await restoreStatusIfNeeded(paneId: paneId) }
        consumePaneViewedBatch()
        let admittedItem: ClosedAppOutboxItem
        if case .report(let report) = item, statusRuntime.retiredPaneIds.contains(report.paneId) {
            admittedItem = .refused(paneId: report.paneId)
        } else {
            admittedItem = item
        }
        let committed = try await repository.admitClosedAppOutboxItem(
            admittedItem, restoreEvidence: restoreEvidence, participants: participants)
        if let ended = committed.ended {
            applyCommittedCommandFinished(ended, reportedAt: ContinuousClock.now)
            await sessionEnded(ended.binding.bindingGenerationId)
        }
        return committed.outcome
    }
}
