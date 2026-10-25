import AgentStudioCore
import Foundation

enum ColdResumeCutoff {
    case awaitingDecision(bindingGenerationId: UUID)
    case invalidated
}

extension SessionsIngestion {
    /// The queue owns this baseline: only a committed live hook can invalidate
    /// it. Stored reports have their own final-reread cutoff and never use it.
    func applyColdEnd(paneId: UUID) async throws -> ColdEndedMain? {
        try await restoreStatusIfNeeded(paneId: paneId)
        consumePaneViewedBatch()
        coldResumeCutoffs[paneId] = nil
        guard !statusRuntime.retiredPaneIds.contains(paneId),
            let binding = try await repository.statusContext(paneId: paneId).currentBinding,
            binding.status == .active,
            let ended = try await repository.endLiveBinding(expectedBinding: binding, endedAt: Date())
        else { return nil }
        applyCommittedCommandFinished(ended, reportedAt: .now)
        await sessionEnded(binding.bindingGenerationId)
        coldResumeCutoffs[paneId] = .awaitingDecision(bindingGenerationId: binding.bindingGenerationId)
        return .init(
            bindingGenerationId: binding.bindingGenerationId, providerIdentifier: binding.providerIdentifier,
            providerConversationId: binding.providerConversationId)
    }

    func invalidateColdResumeIfNeeded(_ commit: SessionsHookCommit) {
        let paneId = commit.binding.paneId
        guard case .awaitingDecision(let generation) = coldResumeCutoffs[paneId] else { return }
        if commit.binding.bindingGenerationId == generation || commit.disposition == .bound {
            coldResumeCutoffs[paneId] = .invalidated
        }
    }

    func applyColdResumeDecision(paneId: UUID, bindingGenerationId: UUID) async throws -> Bool {
        consumePaneViewedBatch()
        guard !statusRuntime.retiredPaneIds.contains(paneId),
            case .awaitingDecision(let generation) = coldResumeCutoffs[paneId], generation == bindingGenerationId,
            let latest = try await repository.statusContext(paneId: paneId).currentBinding
        else { return false }
        return latest.bindingGenerationId == generation && latest.status == .ended
    }
}
