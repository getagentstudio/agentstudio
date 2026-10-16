import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@testable import AgentStudioBridge

actor RepositoryBackedWorktreeAnnotationAccess: WorktreeAnnotationRepositoryAccess {
    let repository: WorktreeAnnotationSQLiteRepository
    private let beforeCatalogRangeRead: (@Sendable () async throws -> Void)?

    init(
        repository: WorktreeAnnotationSQLiteRepository,
        beforeCatalogRangeRead: (@Sendable () async throws -> Void)? = nil
    ) {
        self.repository = repository
        self.beforeCatalogRangeRead = beforeCatalogRangeRead
    }

    func discoverSessions(worktreeID: String) async throws -> [WorktreeAnnotationSession] {
        try repository.discoverSessions(worktreeID: worktreeID)
    }

    func fetchCatalogCapture(worktreeID: String) async throws -> WorktreeAnnotationCatalogCapture {
        try repository.fetchCatalogCapture(worktreeID: worktreeID)
    }

    func fetchCatalogRange(
        worktreeID: String,
        range: WorktreeAnnotationCatalogRange
    ) async throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] {
        try await beforeCatalogRangeRead?()
        return try repository.fetchCatalogRange(worktreeID: worktreeID, range: range)
    }

    func fetchSessionDetail(sessionID: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        try repository.fetchSessionDetail(sessionID: sessionID)
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.createRootDraft(props)
    }

    func flushDraft(_ props: WorktreeAnnotationSQLiteRepository.FlushDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        try repository.flushDraft(props)
    }

    func saveDraft(_ props: WorktreeAnnotationSQLiteRepository.SaveDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.saveDraft(props)
    }

    func revertDraft(_ props: WorktreeAnnotationSQLiteRepository.RevertDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        try repository.revertDraft(props)
    }

    func acquireEditToken(_ props: WorktreeAnnotationSQLiteRepository.AcquireEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.acquireEditToken(props)
    }

    func releaseEditToken(_ props: WorktreeAnnotationSQLiteRepository.ReleaseEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.releaseEditToken(props)
    }

    func createReplyDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateReplyDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.createReplyDraft(props)
    }

    func setThreadResolution(_ props: WorktreeAnnotationSQLiteRepository.SetThreadResolutionProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.setThreadResolution(props)
    }

    func setSessionLifecycle(_ props: WorktreeAnnotationSQLiteRepository.SetSessionLifecycleProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.setSessionLifecycle(props)
    }

    func setSourceRelationship(_ props: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.setSourceRelationship(props)
    }

    func prepareOutput(_ props: WorktreeAnnotationSQLiteRepository.PrepareOutputProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    {
        try repository.prepareOutput(props)
    }

    func inspectOutputAttempt(attemptID: WorktreeAnnotationOutputAttemptID) async throws
        -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    {
        try repository.inspectOutputAttempt(attemptID: attemptID)
    }

    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try repository.cancelOutputAttempt(attemptID: attemptID, now: now)
    }

    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try repository.finalizeOutputAttempt(
            attemptID: attemptID,
            eventKind: eventKind,
            destinationPath: destinationPath,
            now: now
        )
    }

    func markPreparedOutputAttemptsUnknown(now: Date) async throws
        -> WorktreeAnnotationCommittedMutation<Int>
    {
        try repository.markPreparedOutputAttemptsUnknown(now: now)
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws
        -> WorktreeAnnotationRecoveryProvenance?
    {
        try repository.fetchUnacknowledgedRecoveryProvenance()
    }

    func acknowledgeRecoveryProvenance(
        id: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        try repository.acknowledgeRecoveryProvenance(id: id, acknowledgedAt: acknowledgedAt)
    }
}
