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
        await startPaneViewedIngressIfNeeded()
        if !didLoadOpenAsks {
            do {
                let updates = try await openAskSource.openAskSummaries()
                for update in updates { await receiveOpenAskSummary(update) }
                didLoadOpenAsks = true
            } catch {
                // Keep demand-driven hydration eligible after a transient failure.
            }
        }
        guard !statusRuntime.restoredPaneIds.contains(paneId) else { return }
        let context = try await repository.statusContext(paneId: paneId)
        statusRuntime.restore(context, paneId: paneId, admittedAt: ContinuousClock.now)
        consumePaneViewedBatch()
        publishStatus(paneId: paneId)
    }

    func startPaneViewedIngressIfNeeded() async {
        if statusIngressTask == nil {
            statusIngressTask = Task { [weak self, paneViewedMailbox] in
                for await _ in paneViewedMailbox.wakes {
                    guard let self else { break }
                    await self.consumePaneViewedBatch()
                }
            }
            await statusPublicationLane?.start()
        }
    }

    func applyCommittedHook(_ committed: SessionsHookCommit, admittedAt: ContinuousClock.Instant) async throws {
        guard committed.disposition != .recordedOnly else { return }
        let binding = committed.binding
        if committed.disposition == .bound {
            installStatusBinding(binding, boundAt: admittedAt)
        }
        statusRuntime.bindings[binding.bindingGenerationId] = binding
        let input = SessionsStatusRuntime.statusInput(committed.evidence)
        if let input {
            updateStatus(
                generation: binding.bindingGenerationId,
                event: .init(
                    input: input, sequence: committed.revision, occurredAt: committed.evidence.occurredAt,
                    admittedAt: admittedAt, turnId: committed.evidence.turnId))
        }
        consumePaneViewedBatch()
        publishStatus(paneId: binding.paneId)
        if case .sessionEnd? = input {
            statusRuntime.liveBindingBoundAt.removeValue(forKey: binding.bindingGenerationId)
            await sessionEnded(binding.bindingGenerationId)
        }
    }

    func closeLiveBindingForCommandExit(
        paneId: UUID, reportedAt: ContinuousClock.Instant
    ) async throws -> SessionsBindingEndCommit? {
        try await restoreStatusIfNeeded(paneId: paneId)
        guard !statusRuntime.retiredPaneIds.contains(paneId),
            let bindingGenerationId = statusRuntime.currentBindingByPane[paneId],
            let binding = statusRuntime.bindings[bindingGenerationId],
            binding.status == .active,
            statusRuntime.states[bindingGenerationId] != nil
        else { return nil }
        // A restored binding predates every exit observed by this process.
        if let boundAt = statusRuntime.liveBindingBoundAt[bindingGenerationId], boundAt >= reportedAt {
            return nil
        }

        let endedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
        guard
            let committed = try await repository.endLiveBinding(expectedBinding: binding, endedAt: endedAt)
        else { return nil }
        applyCommittedCommandFinished(committed, reportedAt: reportedAt)
        await sessionEnded(bindingGenerationId)
        return committed
    }

    private func applyCommittedCommandFinished(
        _ committed: SessionsBindingEndCommit, reportedAt: ContinuousClock.Instant
    ) {
        let binding = committed.binding
        statusRuntime.bindings[binding.bindingGenerationId] = binding
        if var state = statusRuntime.states[binding.bindingGenerationId] {
            SessionStatusReducer.apply(
                .init(
                    input: .sessionEnd, sequence: committed.revision, occurredAt: committed.endedAt,
                    admittedAt: reportedAt, turnId: nil), to: &state)
            statusRuntime.states[binding.bindingGenerationId] = state
        }
        statusRuntime.liveBindingBoundAt.removeValue(forKey: binding.bindingGenerationId)
        publishStatus(paneId: binding.paneId)
    }

    private func installStatusBinding(_ binding: SessionsBindingRecord, boundAt: ContinuousClock.Instant) {
        guard !statusRuntime.retiredPaneIds.contains(binding.paneId) else { return }
        statusRuntime.bindings[binding.bindingGenerationId] = binding
        statusRuntime.currentBindingByPane[binding.paneId] = binding.bindingGenerationId
        statusRuntime.liveBindingBoundAt[binding.bindingGenerationId] = boundAt
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
            clearRefusal(paneId: paneId)
            if let bindingGenerationId = statusRuntime.currentBindingByPane.removeValue(forKey: paneId) {
                statusRuntime.liveBindingBoundAt.removeValue(forKey: bindingGenerationId)
            }
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
