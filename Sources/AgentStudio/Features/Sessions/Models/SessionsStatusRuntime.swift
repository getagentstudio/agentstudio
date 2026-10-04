import AgentStudioCore
import Foundation

/// Mutable state owned exclusively by SessionsIngestion, never by the publication atom.
struct SessionsStatusRuntime {
    private struct StopAdmission {
        let evidence: SessionsEvidenceRecord
        let admittedAt: ContinuousClock.Instant
    }

    var states: [UUID: SessionStatusState] = [:]
    var bindings: [UUID: SessionsBindingRecord] = [:]
    var currentBindingByPane: [UUID: UUID] = [:]
    var pendingAsks: [UUID: OpenAskSummary] = [:]
    var latestViewedAt: [UUID: ContinuousClock.Instant] = [:]
    var retiredPaneIds: Set<UUID> = []
    var restoredPaneIds: Set<UUID> = []
    private var latestSourceHookByBinding: [UUID: SessionsSourceHookOrder] = [:]
    // Either the latest stamped Stop or the latest unstamped Stop can be the
    // final completion after ordering. Retain both admission instants so a
    // replay does not move DONE past an already recorded pane-viewed mark.
    private var latestStampedStopByBinding: [UUID: StopAdmission] = [:]
    private var latestUnstampedStopByBinding: [UUID: StopAdmission] = [:]

    mutating func restore(_ context: SessionsRepositoryContext, paneId: UUID, admittedAt: ContinuousClock.Instant) {
        guard restoredPaneIds.insert(paneId).inserted, !retiredPaneIds.contains(paneId) else { return }
        for binding in context.bindings {
            reduceBinding(binding, context: context, admittedAt: admittedAt)
        }
        currentBindingByPane[paneId] = context.currentBinding?.bindingGenerationId
    }

    func isOlderHook(_ evidence: SessionsEvidenceRecord) -> Bool {
        guard let order = SessionsSourceHookOrder(evidence),
            let latest = latestSourceHookByBinding[evidence.bindingGenerationId]
        else { return false }
        return order < latest
    }

    mutating func noteHook(
        _ evidence: SessionsEvidenceRecord, input: SessionStatusInput, admittedAt: ContinuousClock.Instant
    ) {
        let generation = evidence.bindingGenerationId
        if let order = SessionsSourceHookOrder(evidence) {
            if latestSourceHookByBinding[generation].map({ $0 < order }) ?? true {
                latestSourceHookByBinding[generation] = order
            }
            if case .stop = input,
                latestStampedStopByBinding[generation].flatMap({ SessionsSourceHookOrder($0.evidence) }).map({
                    $0 < order
                }) ?? true
            {
                latestStampedStopByBinding[generation] = StopAdmission(evidence: evidence, admittedAt: admittedAt)
            }
        } else if case .stop = input {
            if latestUnstampedStopByBinding[generation].map({
                SessionsEvidenceReducer.admissionOrder($0.evidence, evidence)
            }) ?? true {
                latestUnstampedStopByBinding[generation] = StopAdmission(evidence: evidence, admittedAt: admittedAt)
            }
        }
    }

    mutating func rereduceBinding(
        _ context: SessionsRepositoryContext, bindingGenerationId: UUID, admittedAt: ContinuousClock.Instant
    ) {
        guard let binding = context.bindings.first(where: { $0.bindingGenerationId == bindingGenerationId }),
            !retiredPaneIds.contains(binding.paneId), case .bound = states[bindingGenerationId]?.binding
        else { return }
        reduceBinding(binding, context: context, admittedAt: admittedAt)
    }

    private mutating func reduceBinding(
        _ binding: SessionsBindingRecord, context: SessionsRepositoryContext, admittedAt: ContinuousClock.Instant
    ) {
        let generation = binding.bindingGenerationId
        let previous = states[generation]
        bindings[generation] = binding
        var state = SessionStatusState(binding: .bound(generation))
        let evidence = SessionsEvidenceReducer.evidenceOrder(
            context.evidence.filter {
                $0.bindingGenerationId == generation && $0.freshness == .live
            })
        for record in evidence {
            guard let input = Self.statusInput(record) else { continue }
            noteHook(record, input: input, admittedAt: admittedAt)
            let stopAdmission = [latestStampedStopByBinding[generation], latestUnstampedStopByBinding[generation]]
                .compactMap { $0 }.first { $0.evidence.occurrenceId == record.occurrenceId }
            SessionStatusReducer.apply(
                .init(
                    input: input, sequence: record.admissionSequence ?? 0, occurredAt: record.occurredAt,
                    admittedAt: stopAdmission?.admittedAt ?? admittedAt, turnId: record.turnId), to: &state)
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
