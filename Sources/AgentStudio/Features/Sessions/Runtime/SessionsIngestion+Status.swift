import AgentStudioCore
import Foundation

extension SessionsIngestion: SessionOpenAskInput {
    package func receiveOpenAskSummary(_ update: SessionsOpenAskUpdate) async {
        guard !isStatusClosed else { return }
        let previous = statusRuntime.pendingAsks[update.bindingGenerationId]?.sequence ?? 0
        guard update.summary.sequence > previous else { return }
        statusRuntime.pendingAsks[update.bindingGenerationId] = update.summary
        guard var state = statusRuntime.states[update.bindingGenerationId] else { return }
        SessionStatusReducer.apply(
            .init(
                input: .openAsks(update.summary), sequence: update.summary.sequence, occurredAt: Date(),
                admittedAt: ContinuousClock.now, turnId: nil), to: &state)
        statusRuntime.states[update.bindingGenerationId] = state
        if let paneId = statusRuntime.bindings[update.bindingGenerationId]?.paneId { publishStatus(paneId: paneId) }
    }

    package func receiveAgentLine(work: AgentLineWork?, bindingGenerationId: UUID) async {
        guard !isStatusClosed else { return }
        guard var state = statusRuntime.states[bindingGenerationId] else { return }
        state.lineWork = work
        statusRuntime.states[bindingGenerationId] = state
        if let paneId = statusRuntime.bindings[bindingGenerationId]?.paneId { publishStatus(paneId: paneId) }
    }

    package func sessionSummary(paneId: UUID) async throws -> SessionSummary? {
        try await restoreStatusIfNeeded(paneId: paneId)
        consumePaneViewedBatch()
        return try statusRuntime.summary(paneId: paneId)
    }

    package func readSessionStatus(paneId: UUID) async throws -> SessionsStatusReadResult {
        try await restoreStatusIfNeeded(paneId: paneId)
        consumePaneViewedBatch()
        guard let generation = statusRuntime.currentBindingByPane[paneId] else { return .unbound }
        guard let state = statusRuntime.states[generation], let summary = try statusRuntime.summary(paneId: paneId)
        else { throw SessionsRepositoryError.invalidStoredValue("current session status") }
        switch state.binding {
        case .bound: return .live(summary)
        case .ended, .replaced: return .ended(summary)
        }
    }

    func restoreStatusIfNeeded(paneId: UUID) async throws {
        guard !statusRuntime.retiredPaneIds.contains(paneId) else { return }
        if statusIngressTask == nil {
            statusIngressTask = Task { [weak self, paneViewedMailbox] in
                for await _ in paneViewedMailbox.wakes {
                    guard let self else { break }
                    await self.consumePaneViewedBatch()
                }
            }
            await statusPublicationLane?.start()
        }
        if !didLoadOpenAsks {
            didLoadOpenAsks = true
            for update in await openAskSource.openAskSummaries() { await receiveOpenAskSummary(update) }
        }
        guard !statusRuntime.restoredPaneIds.contains(paneId) else { return }
        let context = try await repository.statusContext(paneId: paneId)
        statusRuntime.restore(context, paneId: paneId, admittedAt: ContinuousClock.now)
        consumePaneViewedBatch()
        publishStatus(paneId: paneId)
    }

    func applyCommittedStatus(
        mutation: SessionsMutation, result: SessionsSubmissionResult, admittedAt: ContinuousClock.Instant
    ) async throws {
        if case .historical = result.outcome { return }
        let sequence = result.commitRevision ?? 0
        switch mutation {
        case .bind:
            switch result.outcome {
            case .binding(.established(let binding)):
                installStatusBinding(binding)
            case .binding(.replaced(let previous, let current)):
                updateStatus(
                    generation: previous.bindingGenerationId,
                    event: .init(
                        input: .bindingReplaced(by: current.bindingGenerationId), sequence: sequence,
                        occurredAt: current.startedAt, admittedAt: admittedAt, turnId: nil))
                statusRuntime.bindings[previous.bindingGenerationId] = previous
                installStatusBinding(current)
                await sessionEnded(previous.bindingGenerationId)
            case .binding(.unchanged): break
            default: break
            }
        case .recordEvidence(let evidence):
            guard evidence.origin == .reported,
                case .sourceGeneration(_, let sourceGeneration) = evidence.context,
                let binding = statusRuntime.bindings.values.first(where: { $0.sourceGenerationId == sourceGeneration }),
                case .bound = statusRuntime.states[binding.bindingGenerationId]?.binding
            else { break }
            let record = SessionsEvidenceRecord(
                occurrenceId: evidence.occurrenceId, conversationId: binding.conversationId,
                bindingGenerationId: binding.bindingGenerationId, sourceGenerationId: sourceGeneration,
                turnId: evidence.turnId, subject: evidence.subject, kind: evidence.kind,
                origin: evidence.origin, freshness: evidence.freshness, occurredAt: evidence.occurredAt,
                admissionSequence: sequence, sourceOccurredAt: mutation.boundedSourceOccurredAt,
                providerSignal: evidence.providerSignal)
            guard let input = SessionsStatusRuntime.statusInput(record) else { break }
            let isOlderHook = statusRuntime.isOlderHook(record)
            statusRuntime.noteHook(record, input: input, admittedAt: admittedAt)
            if isOlderHook {
                let context = try await repository.statusContext(paneId: binding.paneId)
                statusRuntime.rereduceBinding(
                    context, bindingGenerationId: binding.bindingGenerationId, admittedAt: admittedAt)
            } else {
                updateStatus(
                    generation: binding.bindingGenerationId,
                    event: .init(
                        input: input, sequence: sequence, occurredAt: evidence.occurredAt, admittedAt: admittedAt,
                        turnId: evidence.turnId))
            }
        case .sourceEnded(let end):
            if let binding = statusRuntime.bindings.values.first(where: {
                $0.sourceGenerationId == end.sourceGenerationId
            }),
                case .bound = statusRuntime.states[binding.bindingGenerationId]?.binding
            {
                updateStatus(
                    generation: binding.bindingGenerationId,
                    event: .init(
                        input: .sessionEnd, sequence: sequence, occurredAt: end.endedAt, admittedAt: admittedAt,
                        turnId: nil))
                await sessionEnded(binding.bindingGenerationId)
            }
        case .prepareForLaunch:
            for paneId in try await repository.statusPaneIds() { try await restoreStatusIfNeeded(paneId: paneId) }
        case .recordLiveLoss:
            break
        }
        consumePaneViewedBatch()
        if let paneId = mutation.paneId { publishStatus(paneId: paneId) }
    }

    private func installStatusBinding(_ binding: SessionsBindingRecord) {
        guard !statusRuntime.retiredPaneIds.contains(binding.paneId) else { return }
        statusRuntime.bindings[binding.bindingGenerationId] = binding
        statusRuntime.currentBindingByPane[binding.paneId] = binding.bindingGenerationId
        var state = SessionStatusState(binding: .bound(binding.bindingGenerationId))
        if let asks = statusRuntime.pendingAsks[binding.bindingGenerationId] { state.openAsks = asks }
        statusRuntime.states[binding.bindingGenerationId] = state
    }

    private func updateStatus(generation: UUID, event: SessionStatusEvent) {
        guard var state = statusRuntime.states[generation], let binding = statusRuntime.bindings[generation] else {
            return
        }
        SessionStatusReducer.apply(event, to: &state)
        if let viewedAt = statusRuntime.latestViewedAt[binding.paneId] {
            SessionStatusReducer.apply(
                .init(
                    input: .paneViewed(viewedAt), sequence: event.sequence, occurredAt: event.occurredAt,
                    admittedAt: event.admittedAt, turnId: nil), to: &state)
        }
        statusRuntime.states[generation] = state
    }

    func consumePaneViewedBatch() {
        let batch = paneViewedMailbox.takeBatch()
        for paneId in batch.retiredPaneIds {
            guard statusRuntime.retiredPaneIds.insert(paneId).inserted else { continue }
            statusRuntime.currentBindingByPane.removeValue(forKey: paneId)
            statusRuntime.latestViewedAt.removeValue(forKey: paneId)
            statusPublicationMailbox.retire(.init(existingUUID: paneId))
        }
        for view in batch.views where !statusRuntime.retiredPaneIds.contains(view.paneId) {
            let paneId = view.paneId
            let viewedAt = view.viewedAt
            if let latest = statusRuntime.latestViewedAt[paneId], latest >= viewedAt { continue }
            statusRuntime.latestViewedAt[paneId] = viewedAt
            if let generation = statusRuntime.currentBindingByPane[paneId] {
                updateStatus(
                    generation: generation,
                    event: .init(
                        input: .paneViewed(viewedAt), sequence: 0, occurredAt: Date(), admittedAt: ContinuousClock.now,
                        turnId: nil))
                publishStatus(paneId: paneId)
            }
        }
    }

    private func publishStatus(paneId: UUID) {
        guard !statusRuntime.retiredPaneIds.contains(paneId),
            let generation = statusRuntime.currentBindingByPane[paneId],
            let state = statusRuntime.states[generation]
        else { return }
        statusPublicationMailbox.offer(SessionStatusReducer.status(of: state), for: .init(existingUUID: paneId))
    }
}
