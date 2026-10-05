import AgentStudioCore
import AgentStudioInfrastructure
import CryptoKit
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

package actor SessionsIngestion {
    private enum PendingInput: Sendable {
        case mutation(SessionsMutation)
        case qualifiedHook(SessionsQualifiedHookSubmission)

        var paneId: UUID? {
            switch self {
            case .mutation(let mutation): mutation.paneId
            case .qualifiedHook(let hook): hook.paneId
            }
        }

        func capacityLoss(reason: SessionsLossReason) -> SessionsLiveLossMutation? {
            switch self {
            case .mutation(.recordEvidence(let evidence)):
                .init(
                    paneId: evidence.context.paneId, eventKind: evidence.kind.storageKind,
                    reason: reason, occurredAt: evidence.occurredAt)
            case .qualifiedHook(let hook):
                hook.evidenceKind.map {
                    .init(paneId: hook.paneId, eventKind: $0.storageKind, reason: reason, occurredAt: hook.occurredAt)
                }
            default: nil
            }
        }
    }

    private struct PendingMutation {
        let correlationId: UUID
        let input: PendingInput
        let paneId: UUID?
        let errorAfterCommit: SessionsRepositoryError?
        let admittedAt: ContinuousClock.Instant
        let commitParticipant: (any SessionsCommitParticipant)?
        let continuation: CheckedContinuation<SessionsSubmissionResult, any Error>
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
    var statusIngressTask: Task<Void, Never>?
    var didLoadOpenAsks = false
    var isStatusClosed = false

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

    package func submit(
        correlationId: UUID,
        mutation: SessionsMutation,
        commitParticipant: (any SessionsCommitParticipant)? = nil
    ) async throws -> SessionsMutationOutcome {
        try await submitWithCommitDisposition(
            correlationId: correlationId, mutation: mutation,
            commitParticipant: commitParticipant
        ).outcome
    }

    package func submitWithCommitDisposition(
        correlationId: UUID,
        mutation: SessionsMutation,
        commitParticipant: (any SessionsCommitParticipant)? = nil
    ) async throws -> SessionsSubmissionResult {
        try await submitInput(
            correlationId: correlationId, input: .mutation(mutation), commitParticipant: commitParticipant)
    }

    package func submitQualifiedHook(
        correlationId: UUID, submission: SessionsQualifiedHookSubmission,
        commitParticipant: (any SessionsCommitParticipant)? = nil
    ) async throws -> SessionsSubmissionResult {
        try await submitInput(
            correlationId: correlationId, input: .qualifiedHook(submission), commitParticipant: commitParticipant)
    }

    private func submitInput(
        correlationId: UUID, input: PendingInput,
        commitParticipant: (any SessionsCommitParticipant)? = nil
    ) async throws -> SessionsSubmissionResult {
        guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
        let paneId = input.paneId
        if let capacityError = currentCapacityError(for: paneId) {
            let reason = lossReason(for: capacityError)
            guard let loss = input.capacityLoss(reason: reason) else { throw capacityError }
            emitStatistics(for: paneId, event: .capacityRejected(reason))
            while currentCapacityError(for: paneId) != nil {
                let taskHoldingCapacity = consumerTask
                await taskHoldingCapacity?.value
                guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
            }
            return try await enqueue(
                correlationId: UUIDv7.generate(),
                input: .mutation(.recordLiveLoss(loss)),
                errorAfterCommit: capacityError
            )
        }
        return try await enqueue(
            correlationId: correlationId,
            input: input,
            errorAfterCommit: nil,
            commitParticipant: commitParticipant
        )
    }

    private func enqueue(
        correlationId: UUID,
        input: PendingInput,
        errorAfterCommit: SessionsRepositoryError?,
        commitParticipant: (any SessionsCommitParticipant)? = nil
    ) async throws -> SessionsSubmissionResult {
        let paneId = input.paneId
        return try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(
                PendingMutation(
                    correlationId: correlationId,
                    input: input,
                    paneId: paneId,
                    errorAfterCommit: errorAfterCommit,
                    admittedAt: ContinuousClock.now,
                    commitParticipant: commitParticipant,
                    continuation: continuation
                )
            )
            if let paneId { pendingCountByPane[paneId, default: 0] += 1 }
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

    package func snapshot(_ query: SessionsSnapshotQuery) async throws -> SessionsSnapshot {
        try await repository.snapshot(query)
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

    package func prepareForLaunch(at launchDate: Date) async throws -> SessionsLaunchPreparationOutcome {
        let outcome = try await submit(
            correlationId: UUIDv7.generate(),
            mutation: .prepareForLaunch(launchDate)
        )
        guard case .launchPrepared(let activeSourcesEnded) = outcome else {
            throw SessionsRepositoryError.invalidStoredValue("prepareForLaunch outcome")
        }
        return SessionsLaunchPreparationOutcome(activeSourcesEnded: activeSourcesEnded)
    }

    package func finish() async {
        acceptsSubmissions = false
        emitStatistics(for: nil, event: .finishing)
        let task = consumerTask
        await task?.value
        isStatusClosed = true
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
            do {
                if let paneId = pending.paneId { try await restoreStatusIfNeeded(paneId: paneId) }
                let outcome: SessionsSubmissionResult
                switch pending.input {
                case .mutation(let mutation):
                    let operation = try mutation.repositoryOperation(correlationId: pending.correlationId)
                    outcome = try await repository.apply(
                        operation: operation, commitParticipant: pending.commitParticipant
                    ) { context in
                        try SessionsEvidenceReducer.reduce(mutation: mutation, against: context)
                    }
                    if outcome.disposition == .inserted {
                        try await applyCommittedStatus(
                            mutation: mutation, result: outcome, admittedAt: pending.admittedAt)
                    }
                case .qualifiedHook(let submission):
                    let commit = try await repository.applyQualifiedHook(
                        correlationId: pending.correlationId, submission: submission,
                        commitParticipant: pending.commitParticipant)
                    outcome = commit.result
                    for committed in commit.committedMutations where committed.result.disposition == .inserted {
                        try await applyCommittedStatus(
                            mutation: committed.mutation, result: committed.result, admittedAt: pending.admittedAt)
                    }
                }
                if let errorAfterCommit = pending.errorAfterCommit {
                    pending.continuation.resume(throwing: errorAfterCommit)
                } else {
                    pending.continuation.resume(returning: outcome)
                }
            } catch {
                pending.continuation.resume(throwing: error)
            }
            if let paneId = pending.paneId {
                let nextCount = pendingCountByPane[paneId, default: 1] - 1
                if nextCount == 0 {
                    pendingCountByPane.removeValue(forKey: paneId)
                } else {
                    pendingCountByPane[paneId] = nextCount
                }
            }
            outstandingCount -= 1
            emitStatistics(for: pending.paneId, event: .depthChanged)
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

extension SessionsMutation {
    func repositoryOperation(correlationId: UUID) throws -> SessionsRepositoryOperation {
        SessionsRepositoryOperation(
            correlationId: correlationId, operationScope: operationScope, operationKind: operationKind,
            semanticFingerprint: try semanticFingerprint(), providerOccurrence: providerOccurrence,
            contextQuery: contextQuery, createdAt: occurredAt, sourceOccurredAt: boundedSourceOccurredAt)
    }

    var paneId: UUID? {
        switch self {
        case .bind(let mutation): mutation.paneId
        case .recordEvidence(let mutation): mutation.context.paneId
        case .sourceEnded(let mutation): mutation.paneId
        case .prepareForLaunch: nil
        case .recordLiveLoss(let mutation): mutation.paneId
        }
    }

    fileprivate var contextQuery: SessionsRepositoryContextQuery {
        switch self {
        case .bind(let mutation):
            .bind(
                paneId: mutation.paneId,
                providerIdentifier: mutation.providerIdentifier,
                providerConversationId: mutation.providerConversationId
            )
        case .recordEvidence(let mutation):
            switch mutation.context {
            case .sourceGeneration(let paneId, let sourceGenerationId):
                .source(paneId: paneId, sourceGenerationId: sourceGenerationId)
            case .currentPaneBinding(let paneId), .unattributed(let paneId):
                .pane(paneId)
            }
        case .sourceEnded(let mutation):
            .source(paneId: mutation.paneId, sourceGenerationId: mutation.sourceGenerationId)
        case .recordLiveLoss(let mutation): .pane(mutation.paneId)
        case .prepareForLaunch: .allActiveSources
        }
    }

    fileprivate var operationScope: String {
        switch self {
        case .prepareForLaunch: "sessions:launch"
        default: "pane:\(paneId?.uuidString ?? "unknown")"
        }
    }

    fileprivate var operationKind: String {
        switch self {
        case .bind: "bind"
        case .recordEvidence: "evidence"
        case .sourceEnded: "sourceEnded"
        case .recordLiveLoss: "loss"
        case .prepareForLaunch: "prepareForLaunch"
        }
    }

    fileprivate var providerOccurrence: SessionsProviderOccurrenceIdentity? {
        switch self {
        case .bind(let mutation):
            guard case .qualifiedSessionStart(let occurrenceId) = mutation.transition else {
                return nil
            }
            return SessionsProviderOccurrenceIdentity(kind: .bind, occurrenceId: occurrenceId)
        case .recordEvidence(let mutation):
            return SessionsProviderOccurrenceIdentity(kind: .evidence, occurrenceId: mutation.occurrenceId)
        case .sourceEnded(let mutation):
            return mutation.occurrenceId.map {
                SessionsProviderOccurrenceIdentity(kind: .sourceEnded, occurrenceId: $0)
            }
        case .recordLiveLoss, .prepareForLaunch:
            return nil
        }
    }

    /// Source time orders hook evidence. The mutation owns both time facts
    /// and validates them before either operation or evidence persistence.
    var boundedSourceOccurredAt: Date? {
        sourceOccurredAt.flatMap {
            $0 <= occurredAt.addingTimeInterval(AppPolicies.Sessions.maximumSourceFutureSkew) ? $0 : nil
        }
    }

    private var sourceOccurredAt: Date? {
        switch self {
        case .bind(let mutation): mutation.sourceOccurredAt
        case .recordEvidence(let mutation): mutation.sourceOccurredAt
        case .sourceEnded(let mutation): mutation.sourceOccurredAt
        default: nil
        }
    }

    fileprivate var occurredAt: Date {
        switch self {
        case .bind(let mutation): mutation.reportedAt
        case .recordEvidence(let mutation): mutation.occurredAt
        case .sourceEnded(let mutation): mutation.endedAt
        case .recordLiveLoss(let mutation): mutation.occurredAt
        case .prepareForLaunch(let date): date
        }
    }

    fileprivate func semanticFingerprint() throws -> String {
        try Self.fingerprint(semanticIntent)
    }

    static func providerSemanticFingerprint(_ providerIntent: String) throws -> String {
        try fingerprint(.providerIntent(providerIntent))
    }

    private static func fingerprint(_ intent: SessionsMutationSemanticIntent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(intent))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var semanticIntent: SessionsMutationSemanticIntent {
        switch self {
        case .bind(let mutation):
            if let digest = mutation.providerIntentFingerprint { return .providerIntent(digest) }
            return .bind(SessionsBindSemanticIntent(mutation))
        case .recordEvidence(let mutation):
            if let digest = mutation.providerIntentFingerprint { return .providerIntent(digest) }
            return .providerEvidence(SessionsProviderEvidenceSemanticIntent(mutation))
        case .sourceEnded(let mutation):
            if let digest = mutation.providerIntentFingerprint { return .providerIntent(digest) }
            return .sourceEnded(
                SessionsSourceEndSemanticIntent(
                    paneId: mutation.paneId, sourceGenerationId: mutation.sourceGenerationId))
        case .recordLiveLoss(let mutation): return .recordLiveLoss(mutation)
        case .prepareForLaunch: return .prepareForLaunch
        }
    }
}

private enum SessionsMutationSemanticIntent: Encodable {
    case providerIntent(String)
    case bind(SessionsBindSemanticIntent)
    case providerEvidence(SessionsProviderEvidenceSemanticIntent)
    case sourceEnded(SessionsSourceEndSemanticIntent)
    case recordLiveLoss(SessionsLiveLossMutation)
    case prepareForLaunch
}

private struct SessionsSourceEndSemanticIntent: Encodable {
    let paneId: UUID
    let sourceGenerationId: UUID
}
