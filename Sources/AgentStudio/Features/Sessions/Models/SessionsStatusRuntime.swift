import AgentStudioCore
import Foundation

/// Mutable state owned exclusively by SessionsIngestion, never by the publication atom.
struct SessionsStatusRuntime {
    var states: [UUID: SessionStatusState] = [:]
    var bindings: [UUID: SessionsBindingRecord] = [:]
    var currentBindingByPane: [UUID: UUID] = [:]
    // Restored bindings intentionally have no instant and predate this process's observations.
    var liveBindingBoundAt: [UUID: ContinuousClock.Instant] = [:]
    var confirmedLiveBindingIds: Set<UUID> = []
    var pendingAsks: [UUID: OpenAskSummary] = [:]
    var latestViewedAt: [UUID: ContinuousClock.Instant] = [:]
    var retiredPaneIds: Set<UUID> = []
    var restoredPaneIds: Set<UUID> = []
    mutating func restore(_ context: SessionsRepositoryContext, paneId: UUID, admittedAt: ContinuousClock.Instant) {
        guard restoredPaneIds.insert(paneId).inserted, !retiredPaneIds.contains(paneId) else { return }
        for binding in context.bindings {
            reduceBinding(binding, context: context, admittedAt: admittedAt)
        }
        currentBindingByPane[paneId] = context.currentBinding?.bindingGenerationId
    }

    private mutating func reduceBinding(
        _ binding: SessionsBindingRecord, context: SessionsRepositoryContext, admittedAt: ContinuousClock.Instant
    ) {
        let generation = binding.bindingGenerationId
        let previous = states[generation]
        bindings[generation] = binding
        var state = SessionStatusState(binding: .bound(generation))
        let evidence = context.evidence.filter {
            $0.bindingGenerationId == generation && $0.statusEffect == .applied
        }.sorted(by: SessionsEvidenceReducer.admissionOrder)
        for record in evidence {
            guard let input = Self.statusInput(record) else { continue }
            SessionStatusReducer.apply(
                .init(
                    input: input, sequence: record.admissionSequence ?? 0, occurredAt: record.occurredAt,
                    admittedAt: admittedAt, turnId: record.turnId), to: &state)
        }
        if binding.status == .ended {
            SessionStatusReducer.apply(
                .init(
                    input: .sessionEnd, sequence: context.revision,
                    occurredAt: binding.endedAt ?? binding.startedAt, admittedAt: admittedAt, turnId: nil), to: &state)
        }
        state.openAsks = pendingAsks[generation] ?? previous?.openAsks ?? state.openAsks
        state.lineWork = previous?.lineWork
        if let viewedAt = latestViewedAt[binding.paneId] {
            SessionStatusReducer.apply(
                .init(
                    input: .paneViewed(viewedAt), sequence: 0, occurredAt: binding.startedAt,
                    admittedAt: admittedAt, turnId: nil), to: &state)
        }
        states[generation] = state
    }

    static func statusInput(_ evidence: SessionsEvidenceRecord) -> SessionStatusInput? {
        if let signal = evidence.providerSignal {
            return signal.statusInput(occurrenceId: evidence.recordId, bindingId: evidence.bindingGenerationId)
        }
        // Existing lifecycle evidence remains readable at the additive cutover.
        guard evidence.origin == .reported else { return nil }
        switch evidence.kind {
        case .activityStarted: return .toolActivity
        case .completed: return .stop
        case .aborted: return .interrupt
        case .needsYouOpened: return .permission(toolName: nil, questions: nil)
        case .needsYouResolved: return nil
        }
    }

    func summary(paneId: UUID) throws -> SessionSummary? {
        guard let generation = currentBindingByPane[paneId], let binding = bindings[generation],
            let state = states[generation]
        else { return nil }
        let prompts = SessionSummaryProjection.prompts(state.providerPrompts)
        return SessionSummary(
            id: binding.conversationId, provider: try .init(binding.providerIdentifier),
            sessionRef: try .init(binding.providerConversationId), bindingGeneration: generation,
            status: SessionSummaryProjection.status(SessionStatusReducer.status(of: state)),
            providerPrompts: prompts,
            omittedPromptCount: state.providerPrompts.count - prompts.count)
    }
}
