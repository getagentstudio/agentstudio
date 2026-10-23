import AgentStudioCore
import Foundation

package struct SessionsIngestionLimits: Sendable, Equatable {
    package let maximumPendingPerPane: Int
    package let maximumPendingGlobal: Int

    package init(maximumPendingPerPane: Int, maximumPendingGlobal: Int) {
        self.maximumPendingPerPane = maximumPendingPerPane
        self.maximumPendingGlobal = maximumPendingGlobal
    }
}

package struct SessionsIngestionStatistics: Sendable, Equatable {
    package enum Event: Sendable, Equatable {
        case depthChanged
        case capacityRejected(SessionsLossReason)
        case finishing
    }

    package let event: Event
    package let paneId: UUID?
    package let pendingForPane: Int
    package let pendingGlobal: Int
}

package typealias SessionsIngestionProbe = @Sendable (SessionsIngestionStatistics) -> Void

/// Hook acceptance drives activity independently of whether its status wins.
package enum SessionsUnverifiedStatusOutcome: Sendable, Equatable {
    case notAccepted
    case refusalRecorded
    case hookAcceptedWithoutStatus
    case hookApplied
}

package actor SessionsIngestion {
    private enum ConnectionRefusalRecord {
        case current(SessionsHookRefusal, recordedAt: ContinuousClock.Instant)
        case historical(SessionsHookRefusal, recordedAt: ContinuousClock.Instant)

        var refusal: SessionsHookRefusal {
            switch self {
            case .current(let refusal, _), .historical(let refusal, _): refusal
            }
        }

        var recordedAt: ContinuousClock.Instant {
            switch self {
            case .current(_, let recordedAt), .historical(_, let recordedAt): recordedAt
            }
        }
    }

    private struct PendingHook {
        let hook: SessionsHookAdmission
        let admittedAt: ContinuousClock.Instant
        let commitParticipant: (any SessionsCommitParticipant)?
        let continuation: CheckedContinuation<SessionsHookOutcome, any Error>
    }

    private struct PendingUnverifiedStatus {
        let hook: SessionsHookAdmission?
        let paneId: UUID
        let refusal: SessionsHookRefusal
        let recordedAt: ContinuousClock.Instant
        let remainsPresent: @Sendable () -> Bool
        let continuation: CheckedContinuation<SessionsUnverifiedStatusOutcome, any Error>
    }

    private struct PendingCommandFinished {
        let paneId: UUID
        let reportedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<SessionsBindingEndCommit?, any Error>
    }

    private struct PendingClosedApp {
        let item: ClosedAppOutboxItem
        let restoreEvidence: any ClosedAppRestoreEvidenceParticipant
        let participants: [any SessionsCommitParticipant]
        let continuation: CheckedContinuation<ClosedAppOutboxOutcome, any Error>
    }

    private struct PendingColdEnd {
        let paneId: UUID
        let continuation: CheckedContinuation<ColdEndedMain?, any Error>
    }

    private struct PendingColdResume {
        let paneId: UUID
        let bindingGenerationId: UUID
        let continuation: CheckedContinuation<Bool, any Error>
    }

    private enum PendingMutation {
        case hook(PendingHook)
        case unverifiedStatus(PendingUnverifiedStatus)
        case commandFinished(PendingCommandFinished)
        case closedApp(PendingClosedApp)
        case coldEnd(PendingColdEnd)
        case coldResume(PendingColdResume)

        var paneId: UUID? {
            switch self {
            case .hook(let pending): return pending.hook.paneId
            case .unverifiedStatus(let pending): return pending.paneId
            case .commandFinished(let pending): return pending.paneId
            case .closedApp(let pending): return pending.item.paneId
            case .coldEnd(let pending): return pending.paneId
            case .coldResume(let pending): return pending.paneId
            }
        }
    }

    let repository: SessionsRepository
    let terminalLeaderReader: any PaneTerminalLeaderReading
    private let limits: SessionsIngestionLimits
    private let probe: SessionsIngestionProbe
    private var acceptsSubmissions = true
    private var pendingMutations: [PendingMutation] = []
    private var pendingCountByPane: [UUID: Int] = [:]
    private var outstandingCount = 0
    private var consumerTask: Task<Void, Never>?
    package nonisolated let paneViewedMailbox: SessionsPaneViewedMailbox
    let statusPublicationMailbox: SessionStatusPublicationMailbox
    let statusPublicationLane: SessionStatusPublicationLane?
    let openAskSource: any SessionOpenAskReading
    let sessionEnded: @Sendable (UUID) async -> Void
    var coldResumeCutoffs: [UUID: ColdResumeCutoff] = [:]
    var statusRuntime = SessionsStatusRuntime()
    var unverifiedStatusRuntime = UnverifiedPaneStatusRuntime()
    var statusIngressTask: Task<Void, Never>?
    var didLoadOpenAsks = false
    var isStatusClosed = false
    private var refusalByPane: [UUID: ConnectionRefusalRecord] = [:]

    package func recordRefusal(paneId: UUID, refusal: SessionsHookRefusal) async {
        let recordedAt = ContinuousClock.now
        guard !isStatusClosed else { return }
        await startPaneViewedIngressIfNeeded()
        consumePaneViewedBatch()
        guard !isStatusClosed, !statusRuntime.retiredPaneIds.contains(paneId) else { return }
        storeRefusal(paneId: paneId, refusal: refusal, recordedAt: recordedAt)
        publishStatus(paneId: paneId)
    }

    package func lastRefusal(paneId: UUID) -> SessionsHookRefusal? {
        consumePaneViewedBatch()
        return refusalByPane[paneId]?.refusal
    }

    private func storeRefusal(paneId: UUID, refusal: SessionsHookRefusal, recordedAt: ContinuousClock.Instant) {
        if let latest = refusalByPane[paneId], latest.recordedAt > recordedAt { return }
        let counted = SessionsHookRefusal(
            reason: refusal.reason, event: refusal.event, at: refusal.at, intent: refusal.intent,
            count: (refusalByPane[paneId]?.refusal.count ?? 0) + 1)
        refusalByPane[paneId] = .current(counted, recordedAt: recordedAt)
    }

    package func recordUnverifiedStatus(
        paneId: UUID, hook: SessionsHookAdmission?, refusal: SessionsHookRefusal,
        remainsPresent: @escaping @Sendable () -> Bool
    ) async throws -> SessionsUnverifiedStatusOutcome {
        let recordedAt = hook?.admissionInstant ?? ContinuousClock.now
        guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
        guard remainsPresent() else { return .notAccepted }
        if let error = currentCapacityError(for: paneId) {
            await startPaneViewedIngressIfNeeded()
            consumePaneViewedBatch()
            guard remainsPresent(), !isStatusClosed, !statusRuntime.retiredPaneIds.contains(paneId) else {
                return .notAccepted
            }
            await recordRefusal(
                paneId: paneId,
                refusal: .init(reason: .queueFull, event: refusal.event, at: refusal.at, intent: .status))
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(
                .unverifiedStatus(
                    .init(
                        hook: hook, paneId: paneId, refusal: refusal, recordedAt: recordedAt,
                        remainsPresent: remainsPresent,
                        continuation: continuation)))
            pendingCountByPane[paneId, default: 0] += 1
            outstandingCount += 1
            emitStatistics(for: paneId, event: .depthChanged)
            startConsumerIfNeeded()
        }
    }

    func currentRefusalReason(paneId: UUID) -> AgentConnectionRefusalReason? {
        guard case .current(let refusal, _)? = refusalByPane[paneId] else { return nil }
        return refusal.reason
    }

    func retireRefusal(paneId: UUID, before exitInstant: ContinuousClock.Instant) {
        guard case .current(let refusal, let recordedAt)? = refusalByPane[paneId] else { return }
        guard recordedAt < exitInstant else { return }
        refusalByPane[paneId] = .historical(refusal, recordedAt: recordedAt)
    }

    private func retireRefusal(paneId: UUID, through eventInstant: ContinuousClock.Instant) {
        guard case .current(let refusal, let recordedAt)? = refusalByPane[paneId] else { return }
        guard recordedAt <= eventInstant else { return }
        refusalByPane[paneId] = .historical(refusal, recordedAt: recordedAt)
    }

    func clearRefusal(paneId: UUID) {
        refusalByPane.removeValue(forKey: paneId)
    }

    package init(
        repository: SessionsRepository,
        limits: SessionsIngestionLimits,
        probe: @escaping SessionsIngestionProbe,
        paneViewedMailbox: SessionsPaneViewedMailbox = .init(),
        statusSink: (@MainActor @Sendable ([PaneId: SessionStatusPublication]) async -> Void)? = nil,
        openAskSource: any SessionOpenAskReading = EmptySessionOpenAskSource(),
        sessionEnded: @escaping @Sendable (UUID) async -> Void = { _ in },
        statusApplyMeasurement: SessionStatusApplyMeasurement = .init(),
        statusApplyProbe: @escaping @Sendable (SessionStatusApplySnapshot) -> Void = { _ in },
        terminalLeaderReader: any PaneTerminalLeaderReading
    ) {
        self.repository = repository
        self.terminalLeaderReader = terminalLeaderReader
        self.limits = limits
        self.probe = probe
        self.paneViewedMailbox = paneViewedMailbox
        let mailbox = SessionStatusPublicationMailbox()
        statusPublicationMailbox = mailbox
        statusPublicationLane = statusSink.map {
            SessionStatusPublicationLane(
                mailbox: mailbox, sink: $0, measurement: statusApplyMeasurement, probe: statusApplyProbe)
        }
        self.openAskSource = openAskSource
        self.sessionEnded = sessionEnded
    }

    package func submitHook(
        _ hook: SessionsHookAdmission,
        commitParticipant: (any SessionsCommitParticipant)? = nil
    ) async throws -> SessionsHookOutcome {
        guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
        if let error = currentCapacityError(for: hook.paneId) {
            emitStatistics(for: hook.paneId, event: .capacityRejected(lossReason(for: error)))
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(
                .hook(
                    .init(
                        hook: hook, admittedAt: hook.admissionInstant,
                        commitParticipant: commitParticipant, continuation: continuation)))
            pendingCountByPane[hook.paneId, default: 0] += 1
            outstandingCount += 1
            emitStatistics(for: hook.paneId, event: .depthChanged)
            startConsumerIfNeeded()
        }
    }

    package func submitCommandFinished(
        paneId: UUID, reportedAt: ContinuousClock.Instant
    ) async throws -> SessionsBindingEndCommit? {
        guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
        // A terminal exit is authoritative, so preserve it in the FIFO even at hook capacity.
        return try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(
                .commandFinished(.init(paneId: paneId, reportedAt: reportedAt, continuation: continuation)))
            pendingCountByPane[paneId, default: 0] += 1
            outstandingCount += 1
            emitStatistics(for: paneId, event: .depthChanged)
            startConsumerIfNeeded()
        }
    }

    private func currentCapacityError(for paneId: UUID?) -> SessionsRepositoryError? {
        if outstandingCount >= limits.maximumPendingGlobal {
            return .globalQueueFull
        }
        if let paneId, pendingCountByPane[paneId, default: 0] >= limits.maximumPendingPerPane {
            return .paneQueueFull(paneId)
        }
        return nil
    }

    private func lossReason(for error: SessionsRepositoryError) -> SessionsLossReason {
        error == .globalQueueFull ? .globalQueueFull : .paneQueueFull
    }

    /// Reads past the current binding, for a caller that has to attribute an
    /// event to the generation its conversation opened rather than to whatever
    /// the pane is bound to now. It reads only; nothing here enters the FIFO.
    package func bindingForProviderConversation(
        paneId: UUID,
        providerIdentifier: String,
        providerConversationId: String
    ) async throws -> SessionsBindingRecord? {
        try await repository.bindingForProviderConversation(
            paneId: paneId,
            providerIdentifier: providerIdentifier,
            providerConversationId: providerConversationId
        )
    }

    package func admitClosedAppOutboxItem(
        _ item: ClosedAppOutboxItem, restoreEvidence: any ClosedAppRestoreEvidenceParticipant,
        participants: [any SessionsCommitParticipant]
    ) async throws -> ClosedAppOutboxOutcome {
        guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
        if let error = currentCapacityError(for: item.paneId) { throw error }
        return try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(
                .closedApp(
                    .init(
                        item: item, restoreEvidence: restoreEvidence, participants: participants,
                        continuation: continuation)))
            if let paneId = item.paneId { pendingCountByPane[paneId, default: 0] += 1 }
            outstandingCount += 1
            emitStatistics(for: item.paneId, event: .depthChanged)
            startConsumerIfNeeded()
        }
    }

    package func endLiveMainForColdRestore(paneId: UUID) async throws -> ColdEndedMain? {
        guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
        return try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(.coldEnd(.init(paneId: paneId, continuation: continuation)))
            pendingCountByPane[paneId, default: 0] += 1
            outstandingCount += 1
            emitStatistics(for: paneId, event: .depthChanged)
            startConsumerIfNeeded()
        }
    }

    package func commitColdResume(paneId: UUID, bindingGenerationId: UUID) async throws -> Bool {
        guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
        return try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(
                .coldResume(
                    .init(
                        paneId: paneId, bindingGenerationId: bindingGenerationId, continuation: continuation)))
            pendingCountByPane[paneId, default: 0] += 1
            outstandingCount += 1
            emitStatistics(for: paneId, event: .depthChanged)
            startConsumerIfNeeded()
        }
    }

    package func finish() async {
        acceptsSubmissions = false
        emitStatistics(for: nil, event: .finishing)
        let task = consumerTask
        await task?.value
        coldResumeCutoffs.removeAll()
        isStatusClosed = true
        for paneId in Set(unverifiedStatusRuntime.panes.keys).union(refusalByPane.keys) {
            statusPublicationMailbox.retire(.init(existingUUID: paneId))
        }
        await statusPublicationLane?.publishPending()
        refusalByPane.removeAll()
        unverifiedStatusRuntime.panes.removeAll()
        paneViewedMailbox.close()
        statusIngressTask?.cancel()
        await statusIngressTask?.value
        statusIngressTask = nil
        await statusPublicationLane?.shutdown()
        statusPublicationMailbox.close()
    }
}

extension SessionsIngestion {
    fileprivate func startConsumerIfNeeded() {
        guard consumerTask == nil else { return }
        consumerTask = Task { await consumePendingMutations() }
    }

    fileprivate func consumePendingMutations() async {
        while !pendingMutations.isEmpty {
            let pending = pendingMutations.removeFirst()
            let paneId = pending.paneId
            do {
                switch pending {
                case .hook(let hook): try await consumeVerifiedHook(hook)
                case .unverifiedStatus(let pending): try await consumeUnverifiedStatus(pending)
                case .commandFinished(let commandFinished):
                    let committed = try await closeLiveBindingForCommandExit(
                        paneId: commandFinished.paneId, reportedAt: commandFinished.reportedAt)
                    commandFinished.continuation.resume(returning: committed)
                case .closedApp(let pending):
                    let outcome = try await applyClosedAppOutboxItem(
                        pending.item, restoreEvidence: pending.restoreEvidence, participants: pending.participants)
                    pending.continuation.resume(returning: outcome)
                case .coldEnd(let pending):
                    pending.continuation.resume(returning: try await applyColdEnd(paneId: pending.paneId))
                case .coldResume(let pending):
                    pending.continuation.resume(
                        returning: try await applyColdResumeDecision(
                            paneId: pending.paneId, bindingGenerationId: pending.bindingGenerationId))
                }
            } catch {
                switch pending {
                case .hook(let hook): hook.continuation.resume(throwing: error)
                case .unverifiedStatus(let pending): pending.continuation.resume(throwing: error)
                case .commandFinished(let commandFinished): commandFinished.continuation.resume(throwing: error)
                case .closedApp(let pending): pending.continuation.resume(throwing: error)
                case .coldEnd(let pending): pending.continuation.resume(throwing: error)
                case .coldResume(let pending): pending.continuation.resume(throwing: error)
                }
            }
            if let paneId {
                let remaining = pendingCountByPane[paneId, default: 1] - 1
                if remaining == 0 {
                    pendingCountByPane.removeValue(forKey: paneId)
                } else {
                    pendingCountByPane[paneId] = remaining
                }
            }
            outstandingCount -= 1
            emitStatistics(for: paneId, event: .depthChanged)
        }
        consumerTask = nil
    }

    private func consumeVerifiedHook(_ pending: PendingHook) async throws {
        let paneId = pending.hook.paneId
        try await restoreStatusIfNeeded(paneId: paneId)
        let eligibility = await mainEligibility(for: pending.hook, claimOnly: false)
        consumePaneViewedBatch()
        guard !isStatusClosed, !statusRuntime.retiredPaneIds.contains(paneId) else {
            pending.continuation.resume(returning: .ignored)
            return
        }
        let outcome = try await repository.applyHook(
            pending.hook, commitParticipant: pending.commitParticipant,
            confirmedLiveBindingIds: statusRuntime.confirmedLiveBindingIds, eligibility: eligibility)
        if case .committed(let committed) = outcome {
            invalidateColdResumeIfNeeded(committed)
            try await applyCommittedHook(committed, admittedAt: pending.admittedAt)
        }
        clearRefusal(paneId: paneId)
        publishStatus(paneId: paneId)
        pending.continuation.resume(returning: outcome)
    }

    private func consumeUnverifiedStatus(_ pending: PendingUnverifiedStatus) async throws {
        let paneId = pending.paneId
        consumePaneViewedBatch()
        guard pending.remainsPresent(), !isStatusClosed, !statusRuntime.retiredPaneIds.contains(paneId) else {
            pending.continuation.resume(returning: .notAccepted)
            return
        }
        try await restoreStatusIfNeeded(paneId: paneId, remainsPresent: pending.remainsPresent)
        consumePaneViewedBatch()
        guard pending.remainsPresent(), !isStatusClosed, !statusRuntime.retiredPaneIds.contains(paneId) else {
            pending.continuation.resume(returning: .notAccepted)
            return
        }
        guard let hook = pending.hook else {
            storeRefusal(paneId: paneId, refusal: pending.refusal, recordedAt: pending.recordedAt)
            publishStatus(paneId: paneId)
            pending.continuation.resume(returning: .refusalRecorded)
            return
        }
        guard !hasActiveBinding(paneId: paneId) else {
            publishStatus(paneId: paneId)
            pending.continuation.resume(returning: .hookAcceptedWithoutStatus)
            return
        }
        let eligibility = await mainEligibility(for: hook, claimOnly: true)
        consumePaneViewedBatch()
        guard pending.remainsPresent(), !isStatusClosed, !statusRuntime.retiredPaneIds.contains(paneId) else {
            pending.continuation.resume(returning: .notAccepted)
            return
        }
        guard !hasActiveBinding(paneId: paneId) else {
            publishStatus(paneId: paneId)
            pending.continuation.resume(returning: .hookAcceptedWithoutStatus)
            return
        }
        let applied = unverifiedStatusRuntime.apply(hook, eligibility: eligibility)
        if applied, hook.signal?.name == .sessionEnd {
            retireRefusal(paneId: paneId, through: pending.recordedAt)
        }
        if let viewedAt = statusRuntime.latestViewedAt[paneId] {
            unverifiedStatusRuntime.viewed(paneId: paneId, at: viewedAt)
        }
        publishStatus(paneId: paneId)
        pending.continuation.resume(returning: applied ? .hookApplied : .hookAcceptedWithoutStatus)
    }

    fileprivate func emitStatistics(for paneId: UUID?, event: SessionsIngestionStatistics.Event) {
        probe(
            SessionsIngestionStatistics(
                event: event,
                paneId: paneId,
                pendingForPane: paneId.map { pendingCountByPane[$0, default: 0] } ?? 0,
                pendingGlobal: outstandingCount
            )
        )
    }
}
