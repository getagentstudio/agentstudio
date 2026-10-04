import AgentStudioCore
import Foundation

/// Mutable state owned exclusively by SessionsIngestion, never by the publication atom.
struct SessionsStatusRuntime {
    var states: [UUID: SessionStatusState] = [:]
    var bindings: [UUID: SessionsBindingRecord] = [:]
    var currentBindingByPane: [UUID: UUID] = [:]
    var pendingAsks: [UUID: OpenAskSummary] = [:]
    var latestViewedAt: [UUID: ContinuousClock.Instant] = [:]
    var retiredPaneIds: Set<UUID> = []
    var restoredPaneIds: Set<UUID> = []

    mutating func restore(_ context: SessionsRepositoryContext, paneId: UUID, admittedAt: ContinuousClock.Instant) {
        guard restoredPaneIds.insert(paneId).inserted, !retiredPaneIds.contains(paneId) else { return }
        for binding in context.bindings {
            bindings[binding.bindingGenerationId] = binding
            var state = SessionStatusState(binding: .bound(binding.bindingGenerationId))
            let evidence = context.evidence.filter { $0.bindingGenerationId == binding.bindingGenerationId }
                .sorted(by: SessionsEvidenceReducer.evidenceOrder)
            for record in evidence where record.freshness == .live {
                if let input = Self.statusInput(record) {
                    SessionStatusReducer.apply(
                        .init(
                            input: input, sequence: record.admissionSequence ?? 0, occurredAt: record.occurredAt,
                            admittedAt: admittedAt, turnId: record.turnId), to: &state)
                }
            }
            if binding.status == .ended {
                SessionStatusReducer.apply(
                    .init(
                        input: .sessionEnd, sequence: context.revision,
                        occurredAt: binding.endedAt ?? binding.startedAt, admittedAt: admittedAt, turnId: nil),
                    to: &state)
            }
            if let asks = pendingAsks[binding.bindingGenerationId] { state.openAsks = asks }
            states[binding.bindingGenerationId] = state
        }
        currentBindingByPane[paneId] = context.currentBinding?.bindingGenerationId
    }

    static func statusInput(_ evidence: SessionsEvidenceRecord) -> SessionStatusInput? {
        if let signal = evidence.providerSignal { return signal.statusInput(occurrenceId: evidence.occurrenceId) }
        // Existing lifecycle evidence remains readable at the additive cutover.
        guard evidence.origin == .reported else { return nil }
        switch evidence.kind {
        case .activityStarted: return .toolActivity
        case .completed: return .stop
        case .aborted: return .interrupt
        case .needsYouOpened: return .permission(toolName: nil, questions: nil, handling: .reportOnly)
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
