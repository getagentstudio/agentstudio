import AgentStudioInfrastructure
import Foundation

enum WorktreeAnnotationSourceResolutionError: Error, Equatable, Sendable {
    case invalidSource
    case unavailable
}

struct WorktreeAnnotationCapturedSource: Equatable, Sendable {
    let fingerprint: WorktreeAnnotationSourceFingerprint
    let origin: WorktreeAnnotationThreadOrigin
}

struct WorktreeAnnotationSourceRefreshCapture: Equatable, Sendable {
    let fingerprint: WorktreeAnnotationSourceFingerprint
    let material: WorktreeAnnotationSourceMaterial
}

protocol WorktreeAnnotationGitEvidenceSource: Sendable {
    func currentWorktreeAnnotationReviewedSubjectEvidence(
        sourceGeneration: Int
    ) async throws -> WorktreeAnnotationReviewedSubjectEvidence?
    func worktreeAnnotationAncestryDisposition(
        acceptedReviewedHeadOID: String,
        currentReviewedHeadOID: String,
        sourceGeneration: Int
    ) async throws -> WorktreeAnnotationAncestryDisposition
}

typealias WorktreeAnnotationAncestryResolver =
    @Sendable (String, String, Int) async throws -> WorktreeAnnotationAncestryDisposition

struct WorktreeAnnotationSourceResolver: Sendable {
    let capture:
        @Sendable (
            BridgeProductWorktreeAnnotationOrigin,
            BridgeProductSurface,
            BridgeProductReviewAnnotationPublicationIdentity?,
            BridgeProductAdmissionContext
        ) async throws -> WorktreeAnnotationCapturedSource
    let currentFingerprint:
        @Sendable (
            BridgeProductSurface,
            BridgeProductReviewAnnotationPublicationIdentity?,
            BridgeProductAdmissionContext
        ) async throws -> WorktreeAnnotationSourceFingerprint
    let refresh:
        @Sendable (
            BridgeProductSurface,
            BridgeProductReviewAnnotationPublicationIdentity?,
            BridgeProductAdmissionContext,
            [WorktreeAnnotationSourceRefreshRequirement]
        ) async throws -> WorktreeAnnotationSourceRefreshCapture
    let currentSourceGeneration:
        @Sendable (
            BridgeProductSurface,
            BridgeProductReviewAnnotationPublicationIdentity?,
            BridgeProductAdmissionContext
        ) async throws -> Int
    let currentReviewedSubjectEvidence:
        @Sendable (
            BridgeProductSurface,
            BridgeProductReviewAnnotationPublicationIdentity?,
            BridgeProductAdmissionContext
        ) async throws -> WorktreeAnnotationReviewedSubjectEvidence?
    let ancestryDisposition: WorktreeAnnotationAncestryResolver

    init(
        capture:
            @escaping @Sendable (
                BridgeProductWorktreeAnnotationOrigin,
                BridgeProductSurface,
                BridgeProductReviewAnnotationPublicationIdentity?,
                BridgeProductAdmissionContext
            ) async throws -> WorktreeAnnotationCapturedSource,
        currentFingerprint:
            @escaping @Sendable (
                BridgeProductSurface,
                BridgeProductReviewAnnotationPublicationIdentity?,
                BridgeProductAdmissionContext
            ) async throws -> WorktreeAnnotationSourceFingerprint,
        refresh:
            @escaping @Sendable (
                BridgeProductSurface,
                BridgeProductReviewAnnotationPublicationIdentity?,
                BridgeProductAdmissionContext,
                [WorktreeAnnotationSourceRefreshRequirement]
            ) async throws -> WorktreeAnnotationSourceRefreshCapture,
        currentSourceGeneration:
            @escaping @Sendable (
                BridgeProductSurface,
                BridgeProductReviewAnnotationPublicationIdentity?,
                BridgeProductAdmissionContext
            ) async throws -> Int = { _, _, _ in
                throw WorktreeAnnotationSourceResolutionError.unavailable
            },
        currentReviewedSubjectEvidence:
            @escaping @Sendable (
                BridgeProductSurface,
                BridgeProductReviewAnnotationPublicationIdentity?,
                BridgeProductAdmissionContext
            ) async throws -> WorktreeAnnotationReviewedSubjectEvidence? = { _, _, _ in nil },
        ancestryDisposition: @escaping WorktreeAnnotationAncestryResolver = { _, _, _ in .notEvaluated }
    ) {
        self.capture = capture
        self.currentFingerprint = currentFingerprint
        self.refresh = refresh
        self.currentSourceGeneration = currentSourceGeneration
        self.currentReviewedSubjectEvidence = currentReviewedSubjectEvidence
        self.ancestryDisposition = ancestryDisposition
    }

    static let unavailable = Self(
        capture: { _, _, _, _ in throw WorktreeAnnotationSourceResolutionError.unavailable },
        currentFingerprint: { _, _, _ in throw WorktreeAnnotationSourceResolutionError.unavailable },
        refresh: { _, _, _, _ in throw WorktreeAnnotationSourceResolutionError.unavailable }
    )
}

private struct WorktreeAnnotationTransportDemandKey: Hashable {
    let sessionID: WorktreeAnnotationSessionID
    let surface: BridgeProductSurface
}

private struct WorktreeAnnotationCreateRootTransportInput {
    let admission: BridgeProductWorktreeAnnotationAdmission
    let body: String
    let editToken: String
    let origin: BridgeProductWorktreeAnnotationOrigin
    let surface: BridgeProductSurface
    let productAdmission: BridgeProductAdmissionContext
    let reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity?
    let ownerGeneration: String
}

struct WorktreeAnnotationAppliedMessageCommand {
    let sessionID: WorktreeAnnotationSessionID
    let receipt: BridgeProductWorktreeAnnotationMessageReceiptDTO?
}

private struct WorktreeAnnotationAppliedCommand {
    let sessionID: WorktreeAnnotationSessionID?
    let status: WorktreeAnnotationCommandOutcomeStatus
    let receipt: BridgeProductWorktreeAnnotationMessageReceiptDTO?
}

/// Maps committed File/Review product calls into the application-scoped Store.
///
/// Transport acceptance and durable mutation completion are deliberately
/// separate. Every command publishes one bounded correlation outcome after the
/// Store transaction or query returns.
@MainActor
final class WorktreeAnnotationTransportAdapter {
    let now: @Sendable () -> Date
    let contextID: String
    let outputCoordinator: WorktreeAnnotationOutputCoordinatorActor?
    let outputLabels: WorktreeAnnotationOutputLabels?
    private let repositoryID: String
    let sourceResolver: WorktreeAnnotationSourceResolver
    let store: WorktreeAnnotationServiceActor
    private let worktreeID: String
    private var demandGenerationByKey: [WorktreeAnnotationTransportDemandKey: WorktreeAnnotationDemandGeneration] = [:]

    init(
        store: WorktreeAnnotationServiceActor,
        contextID: String,
        repositoryID: String,
        worktreeID: String,
        sourceResolver: WorktreeAnnotationSourceResolver,
        now: @escaping @Sendable () -> Date = Date.init,
        outputCoordinator: WorktreeAnnotationOutputCoordinatorActor? = nil,
        outputLabels: WorktreeAnnotationOutputLabels? = nil
    ) {
        self.store = store
        self.contextID = contextID
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.sourceResolver = sourceResolver
        self.now = now
        self.outputCoordinator = outputCoordinator
        self.outputLabels = outputLabels
    }

    func apply(
        _ request: BridgeProductWorktreeAnnotationCommandRequest,
        surface: BridgeProductSurface,
        correlation: BridgeProductControlCorrelation,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeProductWorktreeAnnotationCommandOutcomeDTO {
        do {
            if surface == .review {
                _ = try await sourceResolver.currentSourceGeneration(
                    surface,
                    request.reviewPublicationIdentity,
                    productAdmission
                )
            }
            let applied = try await applyCommand(
                request.operation,
                surface: surface,
                reviewPublicationIdentity: request.reviewPublicationIdentity,
                productAdmission: productAdmission,
                ownerGeneration: correlation.workerInstanceId
            )
            let outcome = WorktreeAnnotationCommandOutcome(
                requestID: correlation.requestId,
                surface: surface,
                sessionID: applied.sessionID,
                status: applied.status
            )
            return BridgeProductWorktreeAnnotationCommandOutcomeDTO(outcome, receipt: applied.receipt)
        } catch {
            let status: WorktreeAnnotationCommandOutcomeStatus
            if case WorktreeAnnotationRepositoryError.sessionSelectionRequired(let choice) = error {
                status = .admissionRequired(choice)
            } else {
                status = .failed(Self.failureCode(for: error))
            }
            let outcome = WorktreeAnnotationCommandOutcome(
                requestID: correlation.requestId,
                surface: surface,
                sessionID: Self.sessionID(in: request.operation),
                status: status
            )
            return BridgeProductWorktreeAnnotationCommandOutcomeDTO(outcome)
        }
    }

    private func applyCommand(
        _ operation: BridgeProductWorktreeAnnotationOperation,
        surface: BridgeProductSurface,
        reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity?,
        productAdmission: BridgeProductAdmissionContext,
        ownerGeneration: String
    ) async throws -> WorktreeAnnotationAppliedCommand {
        switch operation {
        case .outputHistory(let rawSessionID):
            let sessionID = WorktreeAnnotationSessionID(rawValue: rawSessionID)
            let history = try await store.fetchOutputHistory(
                sessionID: sessionID,
                limit: AppPolicies.Bridge.worktreeAnnotationMaximumOutputHistorySummaries
            )
            return .init(sessionID: sessionID, status: .history(history), receipt: nil)
        case .outputScopeCommit(let body):
            let output = try await executeOutputPreparation(
                body,
                surface: surface,
                reviewPublicationIdentity: reviewPublicationIdentity,
                productAdmission: productAdmission
            )
            return .init(sessionID: output.summary?.sessionID, status: .output(output), receipt: nil)
        case .outputPreferenceChangeFolder:
            guard let outputCoordinator else {
                throw WorktreeAnnotationTransportAdapterError.outputUnavailable
            }
            let result = await outputCoordinator.changeFolder(productAdmission: productAdmission)
            switch result {
            case .selected:
                return .init(sessionID: nil, status: .committed, receipt: nil)
            case .cancelled:
                return .init(sessionID: nil, status: .output(.destinationCancelled), receipt: nil)
            case .failed(let error):
                return .init(sessionID: nil, status: .output(.destinationSelectionFailed(error)), receipt: nil)
            }
        case .outputReveal(let attemptID):
            try await revealOutputAttempt(attemptID: .init(rawValue: attemptID), productAdmission: productAdmission)
            return .init(sessionID: nil, status: .committed, receipt: nil)
        case .outputHandledClear(let body):
            let detail = try await store.clearOutputHandled(
                attemptID: .init(rawValue: body.attemptId),
                expectedSessionRevision: body.expectedSessionRevision,
                now: now()
            )
            return .init(sessionID: detail.session.id, status: .committed, receipt: nil)
        case .repeatOutput(let attemptID):
            let output = try await executeOutputRepeat(
                attemptID: .init(rawValue: attemptID), productAdmission: productAdmission)
            return .init(sessionID: output.summary?.sessionID, status: .output(output), receipt: nil)
        case .createRoot(let admission, let body, let editToken, let origin):
            let applied = try await createRoot(
                .init(
                    admission: admission,
                    body: body,
                    editToken: editToken,
                    origin: origin,
                    surface: surface,
                    productAdmission: productAdmission,
                    reviewPublicationIdentity: reviewPublicationIdentity,
                    ownerGeneration: ownerGeneration
                )
            )
            return .init(sessionID: applied.sessionID, status: .committed, receipt: applied.receipt)
        case .createReply(let body):
            let applied = try await createReply(body, ownerGeneration: ownerGeneration)
            return .init(sessionID: applied.sessionID, status: .committed, receipt: applied.receipt)
        case .flushDraft(let body):
            let applied = try await flushDraft(body, ownerGeneration: ownerGeneration)
            return .init(sessionID: applied.sessionID, status: .committed, receipt: applied.receipt)
        case .saveDraft(let body):
            let applied = try await saveDraft(body, ownerGeneration: ownerGeneration)
            return .init(sessionID: applied.sessionID, status: .committed, receipt: applied.receipt)
        case .revertDraft(let body):
            let applied = try await revertDraft(body, ownerGeneration: ownerGeneration)
            return .init(sessionID: applied.sessionID, status: .committed, receipt: applied.receipt)
        case .acquireEditToken(let body):
            let applied = try await acquireEditToken(body, ownerGeneration: ownerGeneration)
            return .init(sessionID: applied.sessionID, status: .committed, receipt: applied.receipt)
        case .releaseEditToken(let body):
            let applied = try await releaseEditToken(body, ownerGeneration: ownerGeneration)
            return .init(sessionID: applied.sessionID, status: .committed, receipt: applied.receipt)
        case .markMessagesViewed(let body):
            let result = try await markMessagesViewed(body)
            return .init(sessionID: result.sessionID, status: .viewed(result.results), receipt: nil)
        default:
            let sessionID = try await apply(
                operation,
                surface: surface,
                reviewPublicationIdentity: reviewPublicationIdentity,
                productAdmission: productAdmission,
                ownerGeneration: ownerGeneration
            )
            return .init(sessionID: sessionID, status: .committed, receipt: nil)
        }
    }

    private func apply(
        _ operation: BridgeProductWorktreeAnnotationOperation,
        surface: BridgeProductSurface,
        reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity?,
        productAdmission: BridgeProductAdmissionContext,
        ownerGeneration: String
    ) async throws -> WorktreeAnnotationSessionID? {
        switch operation {
        case .discoverSessions:
            _ = try await store.discoverSessions(worktreeID: worktreeID)
            return nil
        case .acquireDemand(let sessionID):
            let typedSessionID = WorktreeAnnotationSessionID(rawValue: sessionID)
            let demandGeneration = try await store.acquireDemand(
                worktreeID: worktreeID,
                contextID: contextID,
                surface: surface,
                sessionID: typedSessionID
            )
            demandGenerationByKey[
                WorktreeAnnotationTransportDemandKey(sessionID: typedSessionID, surface: surface)
            ] = demandGeneration
            return typedSessionID
        case .releaseDemand(let sessionID):
            let typedSessionID = WorktreeAnnotationSessionID(rawValue: sessionID)
            let demandKey = WorktreeAnnotationTransportDemandKey(
                sessionID: typedSessionID,
                surface: surface
            )
            await store.releaseDemand(
                worktreeID: worktreeID,
                contextID: contextID,
                surface: surface,
                sessionID: typedSessionID
            )
            demandGenerationByKey.removeValue(forKey: demandKey)
            return typedSessionID
        case .createRoot(let admission, let body, let editToken, let origin):
            return try await createRoot(
                .init(
                    admission: admission,
                    body: body,
                    editToken: editToken,
                    origin: origin,
                    surface: surface,
                    productAdmission: productAdmission,
                    reviewPublicationIdentity: reviewPublicationIdentity,
                    ownerGeneration: ownerGeneration
                )
            ).sessionID
        case .createReply(let body):
            return try await createReply(body, ownerGeneration: ownerGeneration).sessionID
        case .flushDraft(let body):
            return try await flushDraft(body, ownerGeneration: ownerGeneration).sessionID
        case .acquireEditToken(let body):
            return try await acquireEditToken(body, ownerGeneration: ownerGeneration).sessionID
        case .releaseEditToken(let body):
            return try await releaseEditToken(body, ownerGeneration: ownerGeneration).sessionID
        case .saveDraft(let body):
            return try await saveDraft(body, ownerGeneration: ownerGeneration).sessionID
        case .revertDraft(let body):
            return try await revertDraft(body, ownerGeneration: ownerGeneration).sessionID
        case .setThreadResolution(let body):
            return try await setThreadResolution(body)
        case .setSessionLifecycle(let body):
            return try await setSessionLifecycle(body)
        case .chooseContinuity(let body):
            return try await chooseContinuity(
                body,
                surface: surface,
                reviewPublicationIdentity: reviewPublicationIdentity,
                productAdmission: productAdmission
            )
        case .refreshSource(let body):
            return try await refreshSource(
                body,
                surface: surface,
                reviewPublicationIdentity: reviewPublicationIdentity,
                productAdmission: productAdmission
            )
        case .markMessagesViewed(let body):
            return try await markMessagesViewed(body).sessionID
        case .outputScopeCommit:
            throw WorktreeAnnotationTransportAdapterError.outputUnavailable
        case .outputPreferenceChangeFolder, .outputReveal:
            throw WorktreeAnnotationTransportAdapterError.outputUnavailable
        case .outputHandledClear:
            throw WorktreeAnnotationTransportAdapterError.outputUnavailable
        case .outputHistory(let sessionID):
            let typedSessionID = WorktreeAnnotationSessionID(rawValue: sessionID)
            _ = try await store.fetchOutputHistory(
                sessionID: typedSessionID,
                limit: AppPolicies.Bridge.worktreeAnnotationMaximumOutputHistorySummaries
            )
            return typedSessionID
        case .repeatOutput:
            throw WorktreeAnnotationTransportAdapterError.outputUnavailable
        case .acknowledgeRecovery:
            try await store.acknowledgeRecovery(at: now())
            return nil
        }
    }

    private func markMessagesViewed(
        _ body: BridgeProductWorktreeAnnotationOperation.ViewedBody
    ) async throws -> WorktreeAnnotationSQLiteRepository.ViewedMutationResult {
        try await store.markMessagesViewed(
            .init(
                sessionID: .init(rawValue: body.sessionId),
                items: body.items.map {
                    .init(
                        messageID: .init(rawValue: $0.messageId),
                        expectedSavedRevision: $0.expectedSavedRevision
                    )
                },
                now: now()
            )
        )
    }

    private func setThreadResolution(
        _ body: BridgeProductWorktreeAnnotationOperation.ThreadResolutionBody
    ) async throws -> WorktreeAnnotationSessionID {
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        _ = try await store.setThreadResolution(
            .init(
                sessionID: sessionID,
                threadID: .init(rawValue: body.threadId),
                resolution: body.resolution,
                expectedThreadRevision: body.expectedThreadRevision,
                now: now()
            )
        )
        return sessionID
    }

    private func setSessionLifecycle(
        _ body: BridgeProductWorktreeAnnotationOperation.SessionLifecycleBody
    ) async throws -> WorktreeAnnotationSessionID {
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        _ = try await store.setSessionLifecycle(
            .init(
                sessionID: sessionID,
                lifecycle: body.lifecycle,
                expectedSessionRevision: body.expectedSessionRevision,
                expectedOpenThreadCount: body.expectedOpenThreadCount,
                confirmsUnresolvedWork: body.confirmsUnresolvedWork,
                now: now()
            )
        )
        return sessionID
    }

    private func createRoot(
        _ input: WorktreeAnnotationCreateRootTransportInput
    ) async throws -> WorktreeAnnotationAppliedMessageCommand {
        let capturedSource = try await sourceResolver.capture(
            input.origin,
            input.surface,
            input.reviewPublicationIdentity,
            input.productAdmission
        )
        try validateFingerprint(capturedSource.fingerprint)
        let detail = try await store.createRootDraft(
            .init(
                admission: Self.sessionAdmission(input.admission),
                repositoryID: repositoryID,
                worktreeID: worktreeID,
                sourceFingerprint: capturedSource.fingerprint,
                origin: capturedSource.origin,
                body: input.body,
                editToken: input.editToken,
                now: now()
            ),
            ownerGeneration: input.ownerGeneration,
            placementContext: .init(contextID: contextID, surface: input.surface)
        )
        guard let createdThread = detail.threads.last,
            let createdMessage = createdThread.messages.first,
            createdMessage.ordinal == 0,
            createdMessage.draft?.activeEditToken == input.editToken
        else {
            throw WorktreeAnnotationTransportAdapterError.messageReceiptUnavailable
        }
        return try appliedMessageCommand(detail: detail, thread: createdThread, message: createdMessage)
    }

    private func createReply(
        _ body: BridgeProductWorktreeAnnotationOperation.MutationBody,
        ownerGeneration: String
    ) async throws -> WorktreeAnnotationAppliedMessageCommand {
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        let detail = try await store.createReplyDraft(
            .init(
                sessionID: sessionID,
                threadID: .init(rawValue: body.threadId),
                expectedThreadRevision: body.expectedThreadRevision,
                body: body.body,
                editToken: body.editToken,
                now: now()
            ),
            ownerGeneration: ownerGeneration
        )
        guard let thread = detail.threads.first(where: { $0.thread.id.rawValue == body.threadId }),
            let message = thread.messages.last,
            message.draft?.activeEditToken == body.editToken
        else {
            throw WorktreeAnnotationTransportAdapterError.messageReceiptUnavailable
        }
        return try appliedMessageCommand(detail: detail, thread: thread, message: message)
    }

    private func flushDraft(
        _ body: BridgeProductWorktreeAnnotationOperation.DraftMutationBody,
        ownerGeneration: String
    ) async throws -> WorktreeAnnotationAppliedMessageCommand {
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        let result = try await store.flushDraft(
            .init(
                sessionID: sessionID,
                messageID: .init(rawValue: body.messageId),
                editToken: body.editToken,
                expectedMessageRevision: body.expectedMessageRevision,
                expectedDraftRevision: body.expectedDraftRevision,
                body: body.body,
                now: now()
            ),
            ownerGeneration: ownerGeneration
        )
        return try appliedDraftMutationCommand(result, messageID: body.messageId)
    }

    private func saveDraft(
        _ body: BridgeProductWorktreeAnnotationOperation.DraftRevisionBody,
        ownerGeneration: String
    ) async throws -> WorktreeAnnotationAppliedMessageCommand {
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        let detail = try await store.saveDraft(
            .init(
                sessionID: sessionID,
                messageID: .init(rawValue: body.messageId),
                editToken: body.editToken,
                expectedMessageRevision: body.expectedMessageRevision,
                expectedDraftRevision: body.expectedDraftRevision,
                now: now()
            ),
            ownerGeneration: ownerGeneration
        )
        return try appliedMessageCommand(detail: detail, messageID: body.messageId)
    }

    private func revertDraft(
        _ body: BridgeProductWorktreeAnnotationOperation.DraftRevisionBody,
        ownerGeneration: String
    ) async throws -> WorktreeAnnotationAppliedMessageCommand {
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        let result = try await store.revertDraft(
            .init(
                sessionID: sessionID,
                messageID: .init(rawValue: body.messageId),
                editToken: body.editToken,
                expectedMessageRevision: body.expectedMessageRevision,
                expectedDraftRevision: body.expectedDraftRevision,
                now: now()
            ),
            ownerGeneration: ownerGeneration
        )
        return try appliedDraftMutationCommand(result, messageID: body.messageId)
    }

    private func appliedDraftMutationCommand(
        _ result: WorktreeAnnotationDraftMutationResult, messageID: UUID
    ) throws -> WorktreeAnnotationAppliedMessageCommand {
        guard let removedMessage = result.removedMessage else {
            return try appliedMessageCommand(detail: result.detail, messageID: messageID)
        }
        let detail = result.detail
        let threadRevision = detail.threads.first { $0.thread.id == removedMessage.threadID }?.thread.semanticRevision
        return .init(
            sessionID: detail.session.id,
            receipt: .messageRemoved(
                .init(
                    sessionId: detail.session.id.rawValue, sessionRevision: detail.session.semanticRevision,
                    threadId: removedMessage.threadID.rawValue, threadRevision: threadRevision,
                    messageId: removedMessage.messageID.rawValue, removedMessageRevision: removedMessage.messageRevision
                )))
    }

    func appliedMessageCommand(
        detail: WorktreeAnnotationSessionDetail,
        messageID: UUID
    ) throws -> WorktreeAnnotationAppliedMessageCommand {
        for thread in detail.threads {
            if let message = thread.messages.first(where: { $0.id.rawValue == messageID }) {
                return try appliedMessageCommand(detail: detail, thread: thread, message: message)
            }
        }
        throw WorktreeAnnotationTransportAdapterError.messageReceiptUnavailable
    }

    func appliedMessageCommand(
        detail: WorktreeAnnotationSessionDetail,
        thread: WorktreeAnnotationThreadDetail,
        message: WorktreeAnnotationMessage
    ) throws -> WorktreeAnnotationAppliedMessageCommand {
        try WorktreeAnnotationAppliedMessageCommand(
            sessionID: detail.session.id,
            receipt: .init(
                session: detail.session,
                thread: thread.thread,
                message: message
            )
        )
    }

    private func chooseContinuity(
        _ body: BridgeProductWorktreeAnnotationOperation.ContinuityBody,
        surface: BridgeProductSurface,
        reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity?,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSessionID {
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        let relationship: WorktreeAnnotationSourceRelationship
        let fingerprint: WorktreeAnnotationSourceFingerprint?
        switch body.decision {
        case .acceptCurrentSource:
            let current = try await sourceResolver.currentFingerprint(
                surface,
                reviewPublicationIdentity,
                productAdmission
            )
            try validateFingerprint(current)
            relationship = .applicable
            fingerprint = current
        case .keepDetached:
            relationship = .detached
            fingerprint = nil
        }
        _ = try await store.setSourceRelationship(
            .init(
                sessionID: sessionID,
                relationship: relationship,
                sourceFingerprint: fingerprint,
                expectedSessionRevision: body.expectedSessionRevision,
                now: now()
            )
        )
        return sessionID
    }

    private func refreshSource(
        _ body: BridgeProductWorktreeAnnotationOperation.SourceRefreshBody,
        surface: BridgeProductSurface,
        reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity?,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSessionID {
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        let demandKey = WorktreeAnnotationTransportDemandKey(sessionID: sessionID, surface: surface)
        guard let demandGeneration = demandGenerationByKey[demandKey] else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let refreshSnapshot = try await store.sourceRefreshSnapshot(sessionID: sessionID)
        guard demandGenerationByKey[demandKey] == demandGeneration else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let capture = try await sourceResolver.refresh(
            surface,
            reviewPublicationIdentity,
            productAdmission,
            refreshSnapshot.requirements
        )
        guard demandGenerationByKey[demandKey] == demandGeneration else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        try validateFingerprint(capture.fingerprint)
        _ = try await store.refreshSource(
            .init(
                contextID: contextID,
                demandGeneration: demandGeneration,
                sessionID: sessionID,
                surface: surface,
                sourceEpoch: body.sourceEpoch,
                expectedSnapshot: refreshSnapshot,
                currentFingerprint: capture.fingerprint,
                material: capture.material,
                now: now()
            )
        )
        return sessionID
    }

    private func validateFingerprint(_ fingerprint: WorktreeAnnotationSourceFingerprint) throws {
        guard fingerprint.repositoryID == repositoryID,
            fingerprint.worktreeID == worktreeID
        else {
            throw WorktreeAnnotationSourceResolutionError.invalidSource
        }
    }

    private static func sessionAdmission(
        _ admission: BridgeProductWorktreeAnnotationAdmission
    ) -> WorktreeAnnotationSQLiteRepository.SessionAdmission {
        switch admission {
        case .implicitOrSingle:
            .implicitOrSingle
        case .newSession:
            .newSession
        case .selected(let sessionID):
            .selected(.init(rawValue: sessionID))
        }
    }

    private static func sessionID(
        in operation: BridgeProductWorktreeAnnotationOperation
    ) -> WorktreeAnnotationSessionID? {
        switch operation {
        case .acquireDemand(let id), .releaseDemand(let id), .outputHistory(let id):
            .init(rawValue: id)
        case .createReply(let body):
            .init(rawValue: body.sessionId)
        case .flushDraft(let body):
            .init(rawValue: body.sessionId)
        case .acquireEditToken(let body), .releaseEditToken(let body),
            .saveDraft(let body), .revertDraft(let body):
            .init(rawValue: body.sessionId)
        case .setThreadResolution(let body):
            .init(rawValue: body.sessionId)
        case .setSessionLifecycle(let body):
            .init(rawValue: body.sessionId)
        case .chooseContinuity(let body):
            .init(rawValue: body.sessionId)
        case .refreshSource(let body):
            .init(rawValue: body.sessionId)
        case .outputScopeCommit(let body):
            .init(rawValue: body.sessionId)
        case .outputPreferenceChangeFolder, .outputReveal:
            nil
        case .markMessagesViewed(let body):
            .init(rawValue: body.sessionId)
        case .acknowledgeRecovery, .createRoot, .discoverSessions, .outputHandledClear, .repeatOutput:
            nil
        }
    }

    private func revealOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID, productAdmission: BridgeProductAdmissionContext
    ) async throws {
        guard let outputCoordinator else {
            throw WorktreeAnnotationTransportAdapterError.outputUnavailable
        }
        let output: WorktreeAnnotationSQLiteRepository.PreparedOutput
        do {
            output = try await store.inspectOutputAttempt(attemptID: attemptID)
        } catch {
            throw WorktreeAnnotationTransportAdapterError.outputAttemptUnavailable
        }
        let detail = try await store.outputSessionDetail(sessionID: output.attempt.sessionID)
        guard detail.session.repositoryID == repositoryID,
            detail.session.worktreeID == worktreeID,
            output.attempt.state == .succeeded,
            let path = output.attempt.destinationPath,
            output.attempt.outputKind == .jsonFile
        else {
            throw WorktreeAnnotationTransportAdapterError.outputAttemptUnavailable
        }
        guard await outputCoordinator.revealSavedFile(path: path, productAdmission: productAdmission) else {
            throw WorktreeAnnotationTransportAdapterError.outputFileMissing
        }
    }

    private static func failureCode(for error: any Error) -> WorktreeAnnotationCommandFailureCode {
        if let repositoryError = error as? WorktreeAnnotationRepositoryError {
            switch repositoryError {
            case .conflict: .conflict
            case .editTokenConflict: .editTokenConflict
            case .messageLocked: .messageLocked
            case .sessionReadOnly: .sessionReadOnly
            case .sessionSelectionRequired: .sessionSelectionRequired
            case .openThreadCountConflict: .openThreadCountConflict
            case .unresolvedWorkConfirmationRequired: .unresolvedWorkConfirmationRequired
            case .notFound: .notFound
            case .invalidState, .duplicateSelection, .emptySelection:
                .unexpected
            }
        } else if let storeError = error as? WorktreeAnnotationServiceError {
            switch storeError {
            case .recoveryAcknowledgementRequired: .recoveryAcknowledgementRequired
            case .staleSourceEpoch: .conflict
            case .unavailable: .unavailable
            }
        } else if let sourceError = error as? WorktreeAnnotationSourceResolutionError {
            switch sourceError {
            case .invalidSource: .invalidSource
            case .unavailable: .unavailable
            }
        } else if let adapterError = error as? WorktreeAnnotationTransportAdapterError {
            switch adapterError {
            case .messageReceiptUnavailable: .unexpected
            case .outputUnavailable: .outputUnavailable
            case .outputAttemptUnavailable: .notFound
            case .outputFileMissing: .outputFileMissing
            }
        } else {
            .unexpected
        }
    }
}

enum WorktreeAnnotationTransportAdapterError: Error {
    case messageReceiptUnavailable
    case outputUnavailable
    case outputAttemptUnavailable
    case outputFileMissing
}
