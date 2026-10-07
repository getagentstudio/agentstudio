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
    private struct PendingMutation {
        let correlationId: UUID
        let mutation: SessionsMutation
        let paneId: UUID?
        let errorAfterCommit: SessionsRepositoryError?
        let commitParticipant: (any SessionsCommitParticipant)?
        let continuation: CheckedContinuation<SessionsSubmissionResult, any Error>
    }

    private let repository: SessionsRepository
    private let limits: SessionsIngestionLimits
    private let probe: SessionsIngestionProbe
    private var acceptsSubmissions = true
    private var pendingMutations: [PendingMutation] = []
    private var pendingCountByPane: [UUID: Int] = [:]
    private var outstandingCount = 0
    private var consumerTask: Task<Void, Never>?

    package init(
        repository: SessionsRepository,
        limits: SessionsIngestionLimits,
        probe: @escaping SessionsIngestionProbe
    ) {
        self.repository = repository
        self.limits = limits
        self.probe = probe
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
        guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
        let paneId = mutation.paneId
        if let capacityError = currentCapacityError(for: paneId) {
            guard case .recordEvidence(let evidenceMutation) = mutation else { throw capacityError }
            let reason = lossReason(for: capacityError)
            emitStatistics(for: paneId, event: .capacityRejected(reason))
            while currentCapacityError(for: paneId) != nil {
                let taskHoldingCapacity = consumerTask
                await taskHoldingCapacity?.value
                guard acceptsSubmissions else { throw SessionsRepositoryError.ingestionFinished }
            }
            return try await enqueue(
                correlationId: UUIDv7.generate(),
                mutation: .recordLiveLoss(
                    SessionsLiveLossMutation(
                        paneId: evidenceMutation.context.paneId,
                        eventKind: evidenceMutation.kind.storageKind,
                        reason: reason,
                        occurredAt: evidenceMutation.occurredAt
                    )
                ),
                errorAfterCommit: capacityError
            )
        }
        return try await enqueue(
            correlationId: correlationId,
            mutation: mutation,
            errorAfterCommit: nil,
            commitParticipant: commitParticipant
        )
    }

    private func enqueue(
        correlationId: UUID,
        mutation: SessionsMutation,
        errorAfterCommit: SessionsRepositoryError?,
        commitParticipant: (any SessionsCommitParticipant)? = nil
    ) async throws -> SessionsSubmissionResult {
        let paneId = mutation.paneId
        return try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(
                PendingMutation(
                    correlationId: correlationId,
                    mutation: mutation,
                    paneId: paneId,
                    errorAfterCommit: errorAfterCommit,
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
                let operation = try makeRepositoryOperation(
                    correlationId: pending.correlationId,
                    mutation: pending.mutation
                )
                let outcome = try await repository.apply(
                    operation: operation,
                    commitParticipant: pending.commitParticipant
                ) { context in
                    try SessionsEvidenceReducer.reduce(mutation: pending.mutation, against: context)
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

    fileprivate func makeRepositoryOperation(
        correlationId: UUID,
        mutation: SessionsMutation
    ) throws -> SessionsRepositoryOperation {
        SessionsRepositoryOperation(
            correlationId: correlationId,
            operationScope: mutation.operationScope,
            operationKind: mutation.operationKind,
            semanticFingerprint: try mutation.semanticFingerprint(),
            providerOccurrence: mutation.providerOccurrence,
            contextQuery: mutation.contextQuery,
            createdAt: mutation.occurredAt
        )
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
    fileprivate var paneId: UUID? {
        switch self {
        case .bind(let mutation): mutation.paneId
        case .message(let mutation): mutation.context.paneId
        case .recordEvidence(let mutation): mutation.context.paneId
        case .deliberateNeedsYou(let mutation): mutation.paneId
        case .clearDeliberateNeedsYou(let mutation): mutation.paneId
        case .deliberateDone(let mutation): mutation.paneId
        case .sourceEnded(let mutation): mutation.paneId
        case .acknowledgeMessage, .prepareForLaunch: nil
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
        case .message(let mutation):
            switch mutation.context {
            case .sourceGeneration(let paneId, let sourceGenerationId):
                .source(paneId: paneId, sourceGenerationId: sourceGenerationId)
            case .currentPaneBinding(let paneId), .unattributed(let paneId):
                .pane(paneId)
            }
        case .recordEvidence(let mutation):
            switch mutation.context {
            case .sourceGeneration(let paneId, let sourceGenerationId):
                .source(paneId: paneId, sourceGenerationId: sourceGenerationId)
            case .currentPaneBinding(let paneId), .unattributed(let paneId):
                .pane(paneId)
            }
        case .deliberateNeedsYou(let mutation): .pane(mutation.paneId)
        case .clearDeliberateNeedsYou(let mutation): .pane(mutation.paneId)
        case .deliberateDone(let mutation): .pane(mutation.paneId)
        case .sourceEnded(let mutation):
            .source(paneId: mutation.paneId, sourceGenerationId: mutation.sourceGenerationId)
        case .acknowledgeMessage(let mutation): .message(mutation.occurrenceId)
        case .recordLiveLoss(let mutation): .pane(mutation.paneId)
        case .prepareForLaunch: .allActiveSources
        }
    }

    fileprivate var operationScope: String {
        switch self {
        case .acknowledgeMessage(let mutation): "message:\(mutation.occurrenceId.uuidString)"
        case .prepareForLaunch: "sessions:launch"
        default: "pane:\(paneId?.uuidString ?? "unknown")"
        }
    }

    fileprivate var operationKind: String {
        switch self {
        case .bind: "bind"
        case .message: "message"
        case .recordEvidence: "evidence"
        case .deliberateNeedsYou: "deliberateNeedsYou"
        case .clearDeliberateNeedsYou: "clearDeliberateNeedsYou"
        case .deliberateDone: "deliberateDone"
        case .sourceEnded: "sourceEnded"
        case .acknowledgeMessage: "messageAcknowledgment"
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
        case .message, .deliberateNeedsYou, .clearDeliberateNeedsYou, .deliberateDone,
            .sourceEnded, .acknowledgeMessage, .recordLiveLoss, .prepareForLaunch:
            return nil
        }
    }

    fileprivate var occurredAt: Date {
        switch self {
        case .bind(let mutation): mutation.reportedAt
        case .message(let mutation): mutation.receivedAt
        case .recordEvidence(let mutation): mutation.occurredAt
        case .deliberateNeedsYou(let mutation): mutation.reportedAt
        case .clearDeliberateNeedsYou(let mutation): mutation.clearedAt
        case .deliberateDone(let mutation): mutation.reportedAt
        case .sourceEnded(let mutation): mutation.endedAt
        case .acknowledgeMessage(let mutation): mutation.acknowledgedAt
        case .recordLiveLoss(let mutation): mutation.occurredAt
        case .prepareForLaunch(let date): date
        }
    }

    fileprivate func semanticFingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(semanticIntent))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var semanticIntent: SessionsMutationSemanticIntent {
        switch self {
        case .bind(let mutation): .bind(mutation)
        case .message(let mutation):
            .message(
                SessionsMessageSemanticIntent(
                    context: mutation.context,
                    text: mutation.text,
                    freshness: mutation.freshness
                )
            )
        case .recordEvidence(let mutation): .providerEvidence(mutation)
        case .deliberateNeedsYou(let mutation):
            .deliberateNeedsYou(
                SessionsNeedsYouSemanticIntent(
                    paneId: mutation.paneId,
                    explanation: mutation.explanation
                )
            )
        case .clearDeliberateNeedsYou(let mutation):
            .clearDeliberateNeedsYou(SessionsPaneSemanticIntent(paneId: mutation.paneId))
        case .deliberateDone(let mutation):
            .deliberateDone(SessionsPaneSemanticIntent(paneId: mutation.paneId))
        case .sourceEnded(let mutation): .sourceEnded(mutation)
        case .acknowledgeMessage(let mutation):
            .acknowledgeMessage(
                SessionsAcknowledgmentSemanticIntent(occurrenceId: mutation.occurrenceId)
            )
        case .recordLiveLoss(let mutation): .recordLiveLoss(mutation)
        case .prepareForLaunch: .prepareForLaunch
        }
    }
}

private enum SessionsMutationSemanticIntent: Encodable {
    case bind(SessionsBindMutation)
    case message(SessionsMessageSemanticIntent)
    case providerEvidence(SessionsEvidenceMutation)
    case deliberateNeedsYou(SessionsNeedsYouSemanticIntent)
    case clearDeliberateNeedsYou(SessionsPaneSemanticIntent)
    case deliberateDone(SessionsPaneSemanticIntent)
    case sourceEnded(SessionsSourceEndMutation)
    case acknowledgeMessage(SessionsAcknowledgmentSemanticIntent)
    case recordLiveLoss(SessionsLiveLossMutation)
    case prepareForLaunch
}

private struct SessionsMessageSemanticIntent: Encodable {
    let context: SessionsReportContext
    let text: String
    let freshness: SessionsEvidenceFreshness
}

private struct SessionsNeedsYouSemanticIntent: Encodable {
    let paneId: UUID
    let explanation: String
}

private struct SessionsPaneSemanticIntent: Encodable {
    let paneId: UUID
}

private struct SessionsAcknowledgmentSemanticIntent: Encodable {
    let occurrenceId: UUID
}
