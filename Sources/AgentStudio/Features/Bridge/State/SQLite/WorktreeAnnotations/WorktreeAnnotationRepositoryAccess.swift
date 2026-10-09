import AgentStudioCore
import Foundation

protocol WorktreeAnnotationRepositoryAccess: Sendable {
    func discoverSessions(worktreeID: String) async throws -> [WorktreeAnnotationSession]
    func discoverForeignLivingSessionCandidates(
        repositoryID: String,
        excludingWorktreeID: String
    ) async throws -> [WorktreeAnnotationSession]
    func fetchProjectionSnapshot(
        worktreeID: String,
        demandedSessionIDs: [WorktreeAnnotationSessionID]
    ) async throws -> WorktreeAnnotationRepositoryProjectionSnapshot
    func fetchSessionDetail(sessionID: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    func fetchCatalogCapture(worktreeID: String) async throws -> WorktreeAnnotationCatalogCapture
    func fetchCatalogRange(
        worktreeID: String,
        range: WorktreeAnnotationCatalogRange
    ) async throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]
    func fetchCurrentCatalogEntries(
        worktreeID: String,
        keys: Set<WorktreeAnnotationCatalogKey>
    ) async throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]
    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func flushDraft(_ props: WorktreeAnnotationSQLiteRepository.FlushDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    func saveDraft(_ props: WorktreeAnnotationSQLiteRepository.SaveDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func revertDraft(_ props: WorktreeAnnotationSQLiteRepository.RevertDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    func acquireEditToken(_ props: WorktreeAnnotationSQLiteRepository.AcquireEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func releaseEditToken(_ props: WorktreeAnnotationSQLiteRepository.ReleaseEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func createReplyDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateReplyDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func setThreadResolution(_ props: WorktreeAnnotationSQLiteRepository.SetThreadResolutionProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func setSessionLifecycle(_ props: WorktreeAnnotationSQLiteRepository.SetSessionLifecycleProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func setSourceRelationship(_ props: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func acceptCurrentAssociation(
        _ props: WorktreeAnnotationSQLiteRepository.AcceptCurrentAssociationProps
    ) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.AssociationMutationResult>
    func markMessagesViewed(_ props: WorktreeAnnotationSQLiteRepository.MarkMessagesViewedProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.ViewedMutationResult>
    func prepareOutput(_ props: WorktreeAnnotationSQLiteRepository.PrepareOutputProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    func inspectOutputAttempt(attemptID: WorktreeAnnotationOutputAttemptID) async throws
        -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    func repeatOutputAttempt(
        sourceAttemptID: WorktreeAnnotationOutputAttemptID,
        repeatedAttemptID: WorktreeAnnotationOutputAttemptID,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    func cancelOutputAttempt(attemptID: WorktreeAnnotationOutputAttemptID, now: Date) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        effectError: String,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    func markOutputAttemptFinalizationFailed(
        attemptID: WorktreeAnnotationOutputAttemptID,
        cleanupError: String,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    func fetchOutputHistory(
        sessionID: WorktreeAnnotationSessionID,
        limit: Int
    ) async throws -> [WorktreeAnnotationOutputHistorySummary]
    func clearOutputHandled(
        attemptID: WorktreeAnnotationOutputAttemptID,
        expectedSessionRevision: Int,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    func markPreparedOutputAttemptsUnknown(now: Date) async throws
        -> WorktreeAnnotationCommittedMutation<Int>
    func fetchUnacknowledgedRecoveryProvenance() async throws
        -> WorktreeAnnotationRecoveryProvenance?
    func acknowledgeRecoveryProvenance(
        id: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance
}

extension WorktreeAnnotationRepositoryAccess {
    func fetchCatalogRange(
        worktreeID: String,
        range: WorktreeAnnotationCatalogRange
    ) async throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] {
        _ = (worktreeID, range)
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func fetchCurrentCatalogEntries(
        worktreeID: String,
        keys: Set<WorktreeAnnotationCatalogKey>
    ) async throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] {
        _ = (worktreeID, keys)
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func fetchCatalogCapture(worktreeID: String) async throws -> WorktreeAnnotationCatalogCapture {
        _ = worktreeID
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func discoverForeignLivingSessionCandidates(
        repositoryID _: String,
        excludingWorktreeID _: String
    ) async throws -> [WorktreeAnnotationSession] { [] }

    func acceptCurrentAssociation(
        _ props: WorktreeAnnotationSQLiteRepository.AcceptCurrentAssociationProps
    ) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.AssociationMutationResult>
    {
        _ = props
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func fetchProjectionSnapshot(
        worktreeID: String,
        demandedSessionIDs: [WorktreeAnnotationSessionID]
    ) async throws -> WorktreeAnnotationRepositoryProjectionSnapshot {
        _ = (worktreeID, demandedSessionIDs)
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func markMessagesViewed(_ props: WorktreeAnnotationSQLiteRepository.MarkMessagesViewedProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.ViewedMutationResult>
    {
        _ = props
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func acquireEditToken(_ props: WorktreeAnnotationSQLiteRepository.AcquireEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func releaseEditToken(_ props: WorktreeAnnotationSQLiteRepository.ReleaseEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func repeatOutputAttempt(
        sourceAttemptID: WorktreeAnnotationOutputAttemptID,
        repeatedAttemptID: WorktreeAnnotationOutputAttemptID,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        _ = (sourceAttemptID, repeatedAttemptID, destinationPath, now)
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        effectError: String,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        _ = effectError
        return try await cancelOutputAttempt(attemptID: attemptID, now: now)
    }

    func markOutputAttemptFinalizationFailed(
        attemptID: WorktreeAnnotationOutputAttemptID,
        cleanupError: String,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        _ = (attemptID, cleanupError, destinationPath, now)
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func fetchOutputHistory(
        sessionID: WorktreeAnnotationSessionID,
        limit: Int
    ) async throws -> [WorktreeAnnotationOutputHistorySummary] {
        _ = (sessionID, limit)
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func clearOutputHandled(
        attemptID: WorktreeAnnotationOutputAttemptID,
        expectedSessionRevision: Int,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail> {
        _ = (attemptID, expectedSessionRevision, now)
        throw WorktreeAnnotationRepositoryError.invalidState
    }

}

struct WorktreeAnnotationRepositoryProjectionSnapshot: Equatable, Sendable {
    let details: [WorktreeAnnotationSessionDetail]
    let sessions: [WorktreeAnnotationSession]
}

package struct WorktreeAnnotationSQLiteDatastoreAdapter: WorktreeAnnotationRepositoryAccess {
    package let workspaceID: UUID
    package let datastore: WorkspaceSQLiteDatastoreActor

    package init(workspaceID: UUID, datastore: WorkspaceSQLiteDatastoreActor) {
        self.workspaceID = workspaceID
        self.datastore = datastore
    }

    func discoverSessions(worktreeID: String) async throws -> [WorktreeAnnotationSession] {
        try await restore { try $0.discoverSessions(worktreeID: worktreeID) }
    }

    func discoverForeignLivingSessionCandidates(
        repositoryID: String,
        excludingWorktreeID: String
    ) async throws -> [WorktreeAnnotationSession] {
        try await restore {
            try $0.discoverForeignLivingSessionCandidates(
                repositoryID: repositoryID,
                excludingWorktreeID: excludingWorktreeID
            )
        }
    }

    func fetchProjectionSnapshot(
        worktreeID: String,
        demandedSessionIDs: [WorktreeAnnotationSessionID]
    ) async throws -> WorktreeAnnotationRepositoryProjectionSnapshot {
        try await restore {
            try $0.fetchProjectionSnapshot(
                worktreeID: worktreeID,
                demandedSessionIDs: demandedSessionIDs
            )
        }
    }

    func fetchSessionDetail(sessionID: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        try await restore { try $0.fetchSessionDetail(sessionID: sessionID) }
    }

    func fetchCatalogCapture(worktreeID: String) async throws -> WorktreeAnnotationCatalogCapture {
        try await restore { try $0.fetchCatalogCapture(worktreeID: worktreeID) }
    }

    func fetchCatalogRange(
        worktreeID: String,
        range: WorktreeAnnotationCatalogRange
    ) async throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] {
        try await restore { try $0.fetchCatalogRange(worktreeID: worktreeID, range: range) }
    }

    func fetchCurrentCatalogEntries(
        worktreeID: String,
        keys: Set<WorktreeAnnotationCatalogKey>
    ) async throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] {
        try await restore {
            try $0.fetchCurrentCatalogEntries(worktreeID: worktreeID, keys: keys)
        }
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try await mutate { try $0.createRootDraft(props) }
    }

    func flushDraft(_ props: WorktreeAnnotationSQLiteRepository.FlushDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        try await mutate { try $0.flushDraft(props) }
    }

    func saveDraft(_ props: WorktreeAnnotationSQLiteRepository.SaveDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try await mutate { try $0.saveDraft(props) }
    }

    func revertDraft(_ props: WorktreeAnnotationSQLiteRepository.RevertDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        try await mutate { try $0.revertDraft(props) }
    }

    func acquireEditToken(_ props: WorktreeAnnotationSQLiteRepository.AcquireEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try await mutate { try $0.acquireEditToken(props) }
    }

    func releaseEditToken(_ props: WorktreeAnnotationSQLiteRepository.ReleaseEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try await mutate { try $0.releaseEditToken(props) }
    }

    func createReplyDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateReplyDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try await mutate { try $0.createReplyDraft(props) }
    }

    func setThreadResolution(_ props: WorktreeAnnotationSQLiteRepository.SetThreadResolutionProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try await mutate { try $0.setThreadResolution(props) }
    }

    func setSessionLifecycle(_ props: WorktreeAnnotationSQLiteRepository.SetSessionLifecycleProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try await mutate { try $0.setSessionLifecycle(props) }
    }

    func setSourceRelationship(_ props: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try await mutate { try $0.setSourceRelationship(props) }
    }

    func acceptCurrentAssociation(
        _ props: WorktreeAnnotationSQLiteRepository.AcceptCurrentAssociationProps
    ) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.AssociationMutationResult>
    {
        try await mutate { try $0.acceptCurrentAssociation(props) }
    }

    func markMessagesViewed(_ props: WorktreeAnnotationSQLiteRepository.MarkMessagesViewedProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.ViewedMutationResult>
    {
        try await mutate { try $0.markMessagesViewed(props) }
    }

    func prepareOutput(_ props: WorktreeAnnotationSQLiteRepository.PrepareOutputProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    {
        try await mutate { try $0.prepareOutput(props) }
    }

    func inspectOutputAttempt(attemptID: WorktreeAnnotationOutputAttemptID) async throws
        -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    {
        try await restore { try $0.inspectOutputAttempt(attemptID: attemptID) }
    }

    func repeatOutputAttempt(
        sourceAttemptID: WorktreeAnnotationOutputAttemptID,
        repeatedAttemptID: WorktreeAnnotationOutputAttemptID,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try await mutate { repository in
            try repository.repeatOutputAttempt(
                sourceAttemptID: sourceAttemptID,
                repeatedAttemptID: repeatedAttemptID,
                destinationPath: destinationPath,
                now: now
            )
        }
    }

    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try await cancelOutputAttempt(attemptID: attemptID, effectError: nil, now: now)
    }

    private func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        effectError: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try await mutate { repository in
            try repository.cancelOutputAttempt(
                attemptID: attemptID,
                effectError: effectError,
                now: now
            )
        }
    }

    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        effectError: String,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try await cancelOutputAttempt(
            attemptID: attemptID,
            effectError: Optional(effectError),
            now: now
        )
    }

    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try await mutate { repository in
            try repository.finalizeOutputAttempt(
                attemptID: attemptID,
                eventKind: eventKind,
                destinationPath: destinationPath,
                now: now
            )
        }
    }

    func markOutputAttemptFinalizationFailed(
        attemptID: WorktreeAnnotationOutputAttemptID,
        cleanupError: String,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try await mutate { repository in
            try repository.markOutputAttemptFinalizationFailed(
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
        try await restore { try $0.fetchOutputHistory(sessionID: sessionID, limit: limit) }
    }

    func clearOutputHandled(
        attemptID: WorktreeAnnotationOutputAttemptID,
        expectedSessionRevision: Int,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail> {
        try await mutate {
            try $0.clearOutputHandled(
                attemptID: attemptID,
                expectedSessionRevision: expectedSessionRevision,
                now: now
            )
        }
    }

    func markPreparedOutputAttemptsUnknown(now: Date) async throws
        -> WorktreeAnnotationCommittedMutation<Int>
    {
        try await mutate { try $0.markPreparedOutputAttemptsUnknown(now: now) }
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws
        -> WorktreeAnnotationRecoveryProvenance?
    {
        try await restore { try $0.fetchUnacknowledgedRecoveryProvenance() }
    }

    func acknowledgeRecoveryProvenance(
        id: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        try await mutate {
            try $0.acknowledgeRecoveryProvenance(id: id, acknowledgedAt: acknowledgedAt)
        }
    }

    private func restore<TOutput: Sendable>(
        _ operation: @escaping @Sendable (WorktreeAnnotationSQLiteRepository) throws -> TOutput
    ) async throws -> TOutput {
        let result = await datastore.performLocalRestoreOperation(
            workspaceId: workspaceID,
            { repository in
                try operation(WorktreeAnnotationSQLiteRepository(databaseWriter: repository.databaseWriter))
            }
        )
        switch result {
        case .completed(let output):
            return output
        case .unavailable(let failure):
            throw failure
        }
    }

    private func mutate<TOutput: Sendable>(
        _ operation: @escaping @Sendable (WorktreeAnnotationSQLiteRepository) throws -> TOutput
    ) async throws -> TOutput {
        try await datastore.performLocalSaveOperation(workspaceId: workspaceID) { repository in
            try operation(WorktreeAnnotationSQLiteRepository(databaseWriter: repository.databaseWriter))
        }
    }
}
