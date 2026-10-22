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

    private enum PendingMutation {
        case hook(PendingHook)
        case unverifiedStatus(PendingUnverifiedStatus)
        case commandFinished(PendingCommandFinished)

        var paneId: UUID {
            switch self {
            case .hook(let pending): return pending.hook.paneId
            case .unverifiedStatus(let pending): return pending.paneId
            case .commandFinished(let pending): return pending.paneId
            }
        }
    }

    let repository: SessionsRepository
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
        statusApplyProbe: @escaping @Sendable (SessionStatusApplySnapshot) -> Void = { _ in }
    ) {
        self.repository = repository
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

    package func finish() async {
        acceptsSubmissions = false
        emitStatistics(for: nil, event: .finishing)
        let task = consumerTask
        await task?.value
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
                case .hook(let hook):
                    try await restoreStatusIfNeeded(paneId: paneId)
                    let outcome = try await repository.applyHook(
                        hook.hook,
                        commitParticipant: hook.commitParticipant,
                        confirmedLiveBindingIds: statusRuntime.confirmedLiveBindingIds)
                    if case .committed(let committed) = outcome {
                        try await applyCommittedHook(committed, admittedAt: hook.admittedAt)
                    }
                    clearRefusal(paneId: paneId)
                    publishStatus(paneId: paneId)
                    hook.continuation.resume(returning: outcome)
                case .unverifiedStatus(let pending):
                    consumePaneViewedBatch()
                    guard pending.remainsPresent(), !isStatusClosed,
                        !statusRuntime.retiredPaneIds.contains(paneId)
                    else {
                        pending.continuation.resume(returning: .notAccepted)
                        break
                    }
                    try await restoreStatusIfNeeded(paneId: paneId, remainsPresent: pending.remainsPresent)
                    consumePaneViewedBatch()
                    guard pending.remainsPresent(), !isStatusClosed,
                        !statusRuntime.retiredPaneIds.contains(paneId)
                    else {
                        pending.continuation.resume(returning: .notAccepted)
                        break
                    }
                    guard let hook = pending.hook else {
                        storeRefusal(paneId: paneId, refusal: pending.refusal, recordedAt: pending.recordedAt)
                        publishStatus(paneId: paneId)
                        pending.continuation.resume(returning: .refusalRecorded)
                        break
                    }
                    guard !hasActiveBinding(paneId: paneId) else {
                        publishStatus(paneId: paneId)
                        pending.continuation.resume(returning: .hookAcceptedWithoutStatus)
                        break
                    }
                    let applied = unverifiedStatusRuntime.apply(hook)
                    if applied, hook.signal?.name == .sessionEnd {
                        retireRefusal(paneId: paneId, through: pending.recordedAt)
                    }
                    if let viewedAt = statusRuntime.latestViewedAt[paneId] {
                        unverifiedStatusRuntime.viewed(paneId: paneId, at: viewedAt)
                    }
                    publishStatus(paneId: paneId)
                    pending.continuation.resume(returning: applied ? .hookApplied : .hookAcceptedWithoutStatus)
                case .commandFinished(let commandFinished):
                    let committed = try await closeLiveBindingForCommandExit(
                        paneId: paneId, reportedAt: commandFinished.reportedAt)
                    commandFinished.continuation.resume(returning: committed)
                }
            } catch {
                switch pending {
                case .hook(let hook): hook.continuation.resume(throwing: error)
                case .unverifiedStatus(let pending): pending.continuation.resume(throwing: error)
                case .commandFinished(let commandFinished): commandFinished.continuation.resume(throwing: error)
                }
            }
            let remaining = pendingCountByPane[paneId, default: 1] - 1
            if remaining == 0 {
                pendingCountByPane.removeValue(forKey: paneId)
            } else {
                pendingCountByPane[paneId] = remaining
            }
            outstandingCount -= 1
            emitStatistics(for: paneId, event: .depthChanged)
        }
        consumerTask = nil
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
