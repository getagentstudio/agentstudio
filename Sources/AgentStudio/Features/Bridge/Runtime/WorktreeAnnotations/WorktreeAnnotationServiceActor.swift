import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

enum WorktreeAnnotationServiceError: Error, Equatable, Sendable {
    case recoveryAcknowledgementRequired
    case staleSourceEpoch
    case unavailable
}

struct WorktreeAnnotationDemandGeneration: Equatable, Sendable {
    let id: UUID
}

private struct WorktreeAnnotationSourceRefreshFence: Equatable {
    let demandGeneration: WorktreeAnnotationDemandGeneration
    let sourceEpoch: Int
}

struct WorktreeAnnotationSourceRefreshProps: Sendable {
    let contextID: String
    let demandGeneration: WorktreeAnnotationDemandGeneration
    let sessionID: WorktreeAnnotationSessionID
    let surface: BridgeProductSurface
    let sourceEpoch: Int
    let expectedSnapshot: WorktreeAnnotationSourceRefreshSnapshot
    let currentFingerprint: WorktreeAnnotationSourceFingerprint
    let material: WorktreeAnnotationSourceMaterial
    let now: Date
}

struct WorktreeAnnotationSourceRefreshRequirement: Equatable, Sendable {
    let threadID: WorktreeAnnotationThreadID
    let origin: WorktreeAnnotationThreadOrigin
}

struct WorktreeAnnotationSourceRefreshSnapshot: Equatable, Sendable {
    let sessionID: WorktreeAnnotationSessionID
    let acceptedSourceFingerprint: WorktreeAnnotationSourceFingerprint
    let requirements: [WorktreeAnnotationSourceRefreshRequirement]
}

struct WorktreeAnnotationServiceProjectionCapture: Sendable {
    let recoveryState: WorktreeAnnotationRecoveryState
    let repositorySnapshot: WorktreeAnnotationRepositoryProjectionSnapshot
    let revision: Int
}

/// Application-scoped actor for annotation commands, queries, and demand.
///
/// Semantic mutations await the repository transaction before applying its
/// compact classified change. SQLite remains the only annotation authority.
package actor WorktreeAnnotationServiceActor {
    let repositoryAccess: any WorktreeAnnotationRepositoryAccess
    let lifecycleTraceRecorder: (any BridgeProductMetadataLifecycleTraceRecording)?
    private var activeDemandGenerationByContextKey:
        [WorktreeAnnotationPlacementContextKey: WorktreeAnnotationDemandGeneration] = [:]
    private var latestSourceRefreshFenceByContextKey:
        [WorktreeAnnotationPlacementContextKey: WorktreeAnnotationSourceRefreshFence] = [:]
    var changeObserverByToken: [UUID: WorktreeAnnotationChangeObserverState] = [:]
    var catalogInvalidationObserverByToken: [UUID: WorktreeAnnotationCatalogInvalidationObserverState] = [:]
    var projectionRevision = 0
    let editOwnership = WorktreeAnnotationEditOwnershipRegistry()
    var recoveryState: WorktreeAnnotationRecoveryState = .available
    var unacknowledgedRecoveryWitness: WorktreeAnnotationRecoveryProvenance?

    init(
        repositoryAccess: any WorktreeAnnotationRepositoryAccess,
        lifecycleTraceRecorder: (any BridgeProductMetadataLifecycleTraceRecording)? = nil
    ) {
        self.repositoryAccess = repositoryAccess
        self.lifecycleTraceRecorder = lifecycleTraceRecorder
    }

    package init(
        sqliteAdapter: WorktreeAnnotationSQLiteDatastoreAdapter,
        traceRuntime: AgentStudioTraceRuntime? = nil
    ) {
        repositoryAccess = sqliteAdapter
        lifecycleTraceRecorder = traceRuntime.map {
            BridgeProductMetadataLifecycleTraceRecorder(
                recorder: BridgePerformanceTraceRecorder(traceRuntime: $0)
            )
        }
    }

    func discoverSessions(worktreeID: String) async throws -> [WorktreeAnnotationSession] {
        try requireAvailableForReads()
        return try await repositoryAccess.discoverSessions(worktreeID: worktreeID)
    }

    func captureProjection(
        worktreeID: String,
        demandedSessionIDs: [WorktreeAnnotationSessionID]
    ) async throws -> WorktreeAnnotationServiceProjectionCapture {
        try requireAvailableForReads()
        let capturedRevision = projectionRevision
        let capturedRecoveryState = recoveryState
        let repositorySnapshot = try await repositoryAccess.fetchProjectionSnapshot(
            worktreeID: worktreeID,
            demandedSessionIDs: demandedSessionIDs
        )
        guard projectionRevision == capturedRevision,
            recoveryState == capturedRecoveryState
        else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        return WorktreeAnnotationServiceProjectionCapture(
            recoveryState: capturedRecoveryState,
            repositorySnapshot: repositorySnapshot,
            revision: capturedRevision
        )
    }

    func acquireDemand(
        worktreeID: String,
        contextID: String,
        surface: BridgeProductSurface,
        sessionID: WorktreeAnnotationSessionID
    ) async throws -> WorktreeAnnotationDemandGeneration {
        try requireAvailableForReads()
        guard !contextID.isEmpty else { throw WorktreeAnnotationServiceError.staleSourceEpoch }

        let contextKey = WorktreeAnnotationPlacementContextKey(
            contextID: contextID,
            surface: surface,
            sessionID: sessionID
        )
        let demandGeneration = WorktreeAnnotationDemandGeneration(id: UUIDv7.generate())
        activeDemandGenerationByContextKey.updateValue(
            demandGeneration,
            forKey: contextKey
        )
        let detail: WorktreeAnnotationSessionDetail
        do {
            detail = try await repositoryAccess.fetchSessionDetail(sessionID: sessionID)
        } catch {
            rollbackDemandRegistration(
                contextKey: contextKey,
                demandGeneration: demandGeneration
            )
            throw error
        }
        guard activeDemandGenerationByContextKey[contextKey] == demandGeneration else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        guard detail.session.worktreeID == worktreeID else {
            rollbackDemandRegistration(
                contextKey: contextKey,
                demandGeneration: demandGeneration
            )
            throw WorktreeAnnotationRepositoryError.notFound
        }
        return demandGeneration
    }

    func releaseDemand(
        worktreeID: String,
        contextID: String,
        surface: BridgeProductSurface,
        sessionID: WorktreeAnnotationSessionID
    ) async {
        let contextKey = WorktreeAnnotationPlacementContextKey(
            contextID: contextID,
            surface: surface,
            sessionID: sessionID
        )
        activeDemandGenerationByContextKey.removeValue(forKey: contextKey)
    }

    func sourceRefreshSnapshot(
        sessionID: WorktreeAnnotationSessionID
    ) async throws -> WorktreeAnnotationSourceRefreshSnapshot {
        try requireAvailableForReads()
        let detail = try await repositoryAccess.fetchSessionDetail(sessionID: sessionID)
        return Self.sourceRefreshSnapshot(from: detail)
    }

    @discardableResult
    func createRootDraft(
        _ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps
    ) async throws -> WorktreeAnnotationSessionDetail {
        try requireMutationAllowed()
        return try await publishCommittedMutation { try await repositoryAccess.createRootDraft(props) }
    }

    @discardableResult
    func createRootDraft(
        _ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps,
        placementContext: WorktreeAnnotationRootPlacementContext
    ) async throws -> WorktreeAnnotationSessionDetail {
        try requireMutationAllowed()
        _ = placementContext
        return try await publishCommittedMutation { try await repositoryAccess.createRootDraft(props) }
    }

    @discardableResult
    func flushDraft(
        _ props: WorktreeAnnotationSQLiteRepository.FlushDraftProps
    ) async throws -> WorktreeAnnotationDraftMutationResult {
        try await publishCommittedMutation { try await repositoryAccess.flushDraft(props) }
    }

    @discardableResult
    func saveDraft(
        _ props: WorktreeAnnotationSQLiteRepository.SaveDraftProps
    ) async throws -> WorktreeAnnotationSessionDetail {
        try await publishCommittedMutation { try await repositoryAccess.saveDraft(props) }
    }

    @discardableResult
    func revertDraft(
        _ props: WorktreeAnnotationSQLiteRepository.RevertDraftProps
    ) async throws -> WorktreeAnnotationDraftMutationResult {
        try await publishCommittedMutation { try await repositoryAccess.revertDraft(props) }
    }

    @discardableResult
    func createReplyDraft(
        _ props: WorktreeAnnotationSQLiteRepository.CreateReplyDraftProps
    ) async throws -> WorktreeAnnotationSessionDetail {
        try await publishCommittedMutation { try await repositoryAccess.createReplyDraft(props) }
    }

    @discardableResult
    func setThreadResolution(
        _ props: WorktreeAnnotationSQLiteRepository.SetThreadResolutionProps
    ) async throws -> WorktreeAnnotationSessionDetail {
        try await publishCommittedMutation { try await repositoryAccess.setThreadResolution(props) }
    }

    @discardableResult
    func setSessionLifecycle(
        _ props: WorktreeAnnotationSQLiteRepository.SetSessionLifecycleProps
    ) async throws -> WorktreeAnnotationSessionDetail {
        try await publishCommittedMutation { try await repositoryAccess.setSessionLifecycle(props) }
    }

    @discardableResult
    func setSourceRelationship(
        _ props: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps
    ) async throws -> WorktreeAnnotationSessionDetail {
        try await publishCommittedMutation { try await repositoryAccess.setSourceRelationship(props) }
    }

    @discardableResult
    func acceptCurrentAssociation(
        _ props: WorktreeAnnotationSQLiteRepository.AcceptCurrentAssociationProps
    ) async throws -> WorktreeAnnotationSQLiteRepository.AssociationMutationResult {
        try requireMutationAllowed()
        return try await publishCorrelatedMutation {
            try await repositoryAccess.acceptCurrentAssociation(props)
        }
    }

    @discardableResult
    func markMessagesViewed(
        _ props: WorktreeAnnotationSQLiteRepository.MarkMessagesViewedProps
    ) async throws -> WorktreeAnnotationSQLiteRepository.ViewedMutationResult {
        try requireMutationAllowed()
        return try await publishCorrelatedMutation {
            try await repositoryAccess.markMessagesViewed(props)
        }
    }

    @discardableResult
    func refreshSource(
        _ props: WorktreeAnnotationSourceRefreshProps
    ) async throws -> WorktreeAnnotationSessionDetail {
        try requireAvailableForReads()
        let committedResult = try await publishCorrelatedMutation {
            try await performSourceRefresh(props)
        }
        guard committedResult.remainsCurrent else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        return committedResult.detail
    }

    private func performSourceRefresh(
        _ props: WorktreeAnnotationSourceRefreshProps
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSourceRefreshCommittedResult> {
        try requireAvailableForReads()
        guard !props.contextID.isEmpty, props.sourceEpoch >= 0 else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let contextKey = WorktreeAnnotationPlacementContextKey(
            contextID: props.contextID,
            surface: props.surface,
            sessionID: props.sessionID
        )
        guard activeDemandGenerationByContextKey[contextKey] == props.demandGeneration else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let refreshFence = WorktreeAnnotationSourceRefreshFence(
            demandGeneration: props.demandGeneration,
            sourceEpoch: props.sourceEpoch
        )
        if let latestFence = latestSourceRefreshFenceByContextKey[contextKey] {
            guard
                refreshFence.demandGeneration != latestFence.demandGeneration
                    || refreshFence.sourceEpoch > latestFence.sourceEpoch
            else {
                throw WorktreeAnnotationServiceError.staleSourceEpoch
            }
        }
        latestSourceRefreshFenceByContextKey[contextKey] = refreshFence

        let loadedDetail = try await repositoryAccess.fetchSessionDetail(sessionID: props.sessionID)
        guard activeDemandGenerationByContextKey[contextKey] == props.demandGeneration,
            latestSourceRefreshFenceByContextKey[contextKey] == refreshFence
        else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        guard Self.sourceRefreshSnapshot(from: loadedDetail) == props.expectedSnapshot else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let evaluation = try WorktreeAnnotationSourceEvaluator.evaluate(
            .init(
                session: loadedDetail.session,
                threads: loadedDetail.threads.map(\.thread),
                surface: props.surface,
                sourceEpoch: String(props.sourceEpoch),
                currentFingerprint: props.currentFingerprint,
                material: props.material
            )
        )
        let committedMutation: WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
        if evaluation.sourceRelationship != loadedDetail.session.sourceRelationship
            || evaluation.acceptedSourceFingerprint.map({
                $0 != loadedDetail.session.acceptedSourceFingerprint
            }) == true
        {
            committedMutation = try await repositoryAccess.setSourceRelationship(
                .init(
                    sessionID: props.sessionID,
                    relationship: evaluation.sourceRelationship,
                    sourceFingerprint: evaluation.acceptedSourceFingerprint,
                    expectedSessionRevision: loadedDetail.session.semanticRevision,
                    now: props.now
                )
            )
        } else {
            committedMutation = WorktreeAnnotationCommittedMutation(
                canonicalResult: loadedDetail,
                change: .noChange
            )
        }
        return WorktreeAnnotationCommittedMutation(
            canonicalResult: WorktreeAnnotationSourceRefreshCommittedResult(
                detail: committedMutation.canonicalResult,
                remainsCurrent: activeDemandGenerationByContextKey[contextKey] == props.demandGeneration
                    && latestSourceRefreshFenceByContextKey[contextKey] == refreshFence
            ),
            change: committedMutation.change
        )
    }

    @discardableResult
    func prepareOutput(
        _ props: WorktreeAnnotationSQLiteRepository.PrepareOutputProps
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        try requireMutationAllowed()
        guard props.expectedProjectionRevision == projectionRevision else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        return try await publishCorrelatedMutation { try await repositoryAccess.prepareOutput(props) }
    }

    func inspectOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        try requireAvailableForReads()
        return try await repositoryAccess.inspectOutputAttempt(attemptID: attemptID)
    }

    func outputSessionDetail(
        sessionID: WorktreeAnnotationSessionID
    ) async throws -> WorktreeAnnotationSessionDetail {
        try requireAvailableForReads()
        return try await repositoryAccess.fetchSessionDetail(sessionID: sessionID)
    }

    func outputSessionDetail(
        sessionID: WorktreeAnnotationSessionID,
        expectedSessionRevision: Int,
        expectedProjectionRevision: Int
    ) async throws -> WorktreeAnnotationSessionDetail {
        try requireAvailableForReads()
        guard projectionRevision == expectedProjectionRevision else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let detail = try await repositoryAccess.fetchSessionDetail(sessionID: sessionID)
        guard projectionRevision == expectedProjectionRevision else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        guard detail.session.semanticRevision == expectedSessionRevision else {
            throw WorktreeAnnotationRepositoryError.conflict(
                currentRevision: detail.session.semanticRevision
            )
        }
        return detail
    }

    @discardableResult
    func repeatOutputAttempt(
        sourceAttemptID: WorktreeAnnotationOutputAttemptID,
        repeatedAttemptID: WorktreeAnnotationOutputAttemptID,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        try requireMutationAllowed()
        return try await publishCorrelatedMutation {
            try await repositoryAccess.repeatOutputAttempt(
                sourceAttemptID: sourceAttemptID,
                repeatedAttemptID: repeatedAttemptID,
                destinationPath: destinationPath,
                now: now
            )
        }
    }

    @discardableResult
    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        try requireMutationAllowed()
        return try await publishCorrelatedMutation {
            try await repositoryAccess.cancelOutputAttempt(attemptID: attemptID, now: now)
        }
    }

    @discardableResult
    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        effectError: String,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        try requireMutationAllowed()
        return try await publishCorrelatedMutation {
            try await repositoryAccess.cancelOutputAttempt(
                attemptID: attemptID,
                effectError: effectError,
                now: now
            )
        }
    }

    @discardableResult
    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String? = nil,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        try requireMutationAllowed()
        return try await publishCorrelatedMutation {
            try await repositoryAccess.finalizeOutputAttempt(
                attemptID: attemptID,
                eventKind: eventKind,
                destinationPath: destinationPath,
                now: now
            )
        }
    }

    @discardableResult
    func markOutputAttemptFinalizationFailed(
        attemptID: WorktreeAnnotationOutputAttemptID,
        cleanupError: String,
        destinationPath: String? = nil,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        try requireMutationAllowed()
        return try await publishCorrelatedMutation {
            try await repositoryAccess.markOutputAttemptFinalizationFailed(
                attemptID: attemptID,
                cleanupError: cleanupError,
                destinationPath: destinationPath,
                now: now
            )
        }
    }

    func fetchOutputHistory(
        sessionID: WorktreeAnnotationSessionID,
        limit: Int
    ) async throws -> [WorktreeAnnotationOutputHistorySummary] {
        try requireAvailableForReads()
        guard limit > 0 else { throw WorktreeAnnotationRepositoryError.invalidState }
        return try await repositoryAccess.fetchOutputHistory(
            sessionID: sessionID,
            limit: min(limit, AppPolicies.Bridge.worktreeAnnotationMaximumOutputHistorySummaries)
        )
    }

    func clearOutputHandled(
        attemptID: WorktreeAnnotationOutputAttemptID,
        expectedSessionRevision: Int,
        now: Date
    ) async throws -> WorktreeAnnotationSessionDetail {
        try await publishCommittedMutation {
            try await repositoryAccess.clearOutputHandled(
                attemptID: attemptID,
                expectedSessionRevision: expectedSessionRevision,
                now: now
            )
        }
    }

    func markPreparedOutputAttemptsUnknown(now: Date) async throws -> Int {
        try requireMutationAllowed()
        let changedCount = try await publishCorrelatedMutation {
            try await repositoryAccess.markPreparedOutputAttemptsUnknown(now: now)
        }
        if changedCount > 0 {
            activeDemandGenerationByContextKey.removeAll()
        }
        return changedCount
    }

    func requireAvailableForReads() throws {
        if recoveryState == .unavailable {
            throw WorktreeAnnotationServiceError.unavailable
        }
    }

    func requireMutationAllowed() throws {
        try requireAvailableForReads()
        guard unacknowledgedRecoveryWitness == nil else {
            throw WorktreeAnnotationServiceError.recoveryAcknowledgementRequired
        }
    }

    func publishCommittedMutation<CanonicalResult: Sendable>(
        _ mutation: () async throws -> WorktreeAnnotationCommittedMutation<CanonicalResult>
    ) async throws -> CanonicalResult {
        try requireMutationAllowed()
        return try await publishCorrelatedMutation(mutation)
    }

    func publishCorrelatedMutation<CanonicalResult: Sendable>(
        _ mutation: () async throws -> WorktreeAnnotationCommittedMutation<CanonicalResult>
    ) async throws -> CanonicalResult {
        let operationCorrelationID = BridgeOperationCorrelation.mintScrubbedID()
        await recordNativeAnnotationWork(
            operationCorrelationID: operationCorrelationID,
            result: .started,
            stage: .nativeWorkStarted
        )
        do {
            let committedMutation = try await mutation()
            emitCommittedCatalogInvalidation(committedMutation.change)
            await recordNativeAnnotationWork(
                operationCorrelationID: operationCorrelationID,
                result: .success,
                stage: .nativeWorkTerminal
            )
            await applyCommittedChange(
                committedMutation.change,
                operationCorrelationID: operationCorrelationID
            )
            return committedMutation.canonicalResult
        } catch {
            emitConservativeCatalogInvalidationAfterUnknownOutcome()
            await recordNativeAnnotationWork(
                operationCorrelationID: operationCorrelationID,
                result: .failure,
                stage: .nativeWorkTerminal
            )
            throw error
        }
    }

    private func rollbackDemandRegistration(
        contextKey: WorktreeAnnotationPlacementContextKey,
        demandGeneration: WorktreeAnnotationDemandGeneration
    ) {
        guard activeDemandGenerationByContextKey[contextKey] == demandGeneration else { return }
        activeDemandGenerationByContextKey.removeValue(forKey: contextKey)
    }

    func recordNativeAnnotationWork(
        operationCorrelationID: String,
        result: BridgeAnnotationLifecycleTraceEvent.Result,
        stage: BridgeAnnotationLifecycleTraceEvent.Stage
    ) async {
        await lifecycleTraceRecorder?.record(
            .init(
                operationCorrelationID: operationCorrelationID,
                result: result,
                sourceGeneration: projectionRevision,
                stage: stage,
                surface: nil
            )
        )
    }

}

extension WorktreeAnnotationServiceActor: WorktreeAnnotationOutputServiceAccess {}
