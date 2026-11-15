import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation SQLite repository")
struct WorktreeAnnotationSQLiteRepositoryTests {
    @Test("empty flush removes a never-saved message and its empty thread atomically")
    func emptyFlushRemovesNeverSavedMessageAndThread() throws {
        let repository = try makeRepository()
        let detail = try makeRootDraft(repository: repository)
        let message = try #require(detail.threads.first?.messages.first)

        let committed = try repository.flushDraft(
            .init(
                sessionID: detail.session.id,
                messageID: message.id,
                editToken: "editor-root",
                expectedMessageRevision: message.semanticRevision,
                expectedDraftRevision: try #require(message.draft?.draftRevision),
                body: "  \n\t",
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult
        #expect(committed.detail.threads.isEmpty)
        #expect(committed.removedMessage?.messageID == message.id)
        #expect(committed.removedMessage?.messageRevision == message.semanticRevision)
        #expect(try repository.fetchSessionDetail(sessionID: detail.session.id).threads.isEmpty)
    }

    @Test("edit token acquire rejects live ownership and reclaims orphaned ownership with a revision fence")
    func editTokenAcquireReleaseAndOrphanReclaim() throws {
        let repository = try makeRepository()
        var detail = try makeRootDraft(repository: repository)
        let original = try #require(detail.threads.first?.messages.first)
        let originalDraft = try #require(original.draft)

        #expect(throws: WorktreeAnnotationRepositoryError.editTokenConflict) {
            try repository.acquireEditToken(
                .init(
                    sessionID: detail.session.id,
                    messageID: original.id,
                    editToken: "editor-other",
                    expectedMessageRevision: original.semanticRevision,
                    expectedDraftRevision: originalDraft.draftRevision,
                    liveEditTokens: ["editor-root"],
                    now: Date(timeIntervalSince1970: 2)
                )
            )
        }

        detail = try repository.acquireEditToken(
            .init(
                sessionID: detail.session.id,
                messageID: original.id,
                editToken: "editor-reclaimed",
                expectedMessageRevision: original.semanticRevision,
                expectedDraftRevision: originalDraft.draftRevision,
                liveEditTokens: [],
                now: Date(timeIntervalSince1970: 3)
            )
        ).canonicalResult
        let reclaimed = try #require(detail.threads.first?.messages.first?.draft)
        #expect(reclaimed.body == originalDraft.body)
        #expect(reclaimed.activeEditToken == "editor-reclaimed")
        #expect(reclaimed.draftRevision == originalDraft.draftRevision + 1)

        #expect(throws: WorktreeAnnotationRepositoryError.editTokenConflict) {
            try repository.flushDraft(
                .init(
                    sessionID: detail.session.id,
                    messageID: original.id,
                    editToken: "editor-root",
                    expectedMessageRevision: try #require(detail.threads.first?.messages.first?.semanticRevision),
                    expectedDraftRevision: originalDraft.draftRevision,
                    body: "late overwrite",
                    now: Date(timeIntervalSince1970: 4)
                )
            )
        }

        detail = try repository.releaseEditToken(
            .init(
                sessionID: detail.session.id,
                messageID: original.id,
                editToken: "editor-reclaimed",
                expectedMessageRevision: try #require(detail.threads.first?.messages.first?.semanticRevision),
                expectedDraftRevision: reclaimed.draftRevision,
                now: Date(timeIntervalSince1970: 5)
            )
        ).canonicalResult
        let released = try #require(detail.threads.first?.messages.first?.draft)
        #expect(released.activeEditToken == nil)
        #expect(released.draftRevision == reclaimed.draftRevision + 1)
    }

    @Test("orphan reclaim advances revision even when the caller presents the persisted token")
    func sameTokenOrphanReclaimStillAdvancesRevision() throws {
        let repository = try makeRepository()
        let detail = try makeRootDraft(repository: repository)
        let message = try #require(detail.threads.first?.messages.first)
        let draft = try #require(message.draft)

        let reclaimed = try repository.acquireEditToken(
            .init(
                sessionID: detail.session.id,
                messageID: message.id,
                editToken: try #require(draft.activeEditToken),
                expectedMessageRevision: message.semanticRevision,
                expectedDraftRevision: draft.draftRevision,
                liveEditTokens: [],
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult

        #expect(reclaimed.threads.first?.messages.first?.draft?.draftRevision == draft.draftRevision + 1)
    }

    @Test("discovery is worktree-global and several sessions require an explicit choice")
    func discoveryIsWorktreeGlobalAndSeveralSessionsRequireChoice() throws {
        let repository = try makeRepository()
        let sourceFingerprint = makeSourceFingerprint(worktreeID: "worktree-1")

        #expect(try repository.discoverSessions(worktreeID: "worktree-1").isEmpty)

        let first = try repository.createRootDraft(
            .init(
                admission: .implicitOrSingle,
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: sourceFingerprint,
                origin: .session,
                body: "First draft",
                editToken: "editor-a",
                now: Date(timeIntervalSince1970: 10)
            )
        ).canonicalResult
        let discovery = try repository.discoverSessions(worktreeID: "worktree-1")
        #expect(discovery.map(\.id) == [first.session.id])

        let completedFirst = try repository.setSessionLifecycle(
            .init(
                sessionID: first.session.id,
                lifecycle: .completed,
                expectedSessionRevision: first.session.semanticRevision,
                expectedOpenThreadCount: 1,
                confirmsUnresolvedWork: true,
                now: Date(timeIntervalSince1970: 15)
            )
        ).canonicalResult
        let second = try repository.createRootDraft(
            .init(
                admission: .newSession,
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: sourceFingerprint,
                origin: .session,
                body: "Second session",
                editToken: "editor-b",
                now: Date(timeIntervalSince1970: 20)
            )
        ).canonicalResult
        _ = try repository.setSessionLifecycle(
            .init(
                sessionID: completedFirst.session.id,
                lifecycle: .living,
                expectedSessionRevision: completedFirst.session.semanticRevision,
                expectedOpenThreadCount: 1,
                confirmsUnresolvedWork: false,
                now: Date(timeIntervalSince1970: 25)
            )
        )
        #expect(first.session.id != second.session.id)
        #expect(try repository.discoverSessions(worktreeID: "worktree-1").count == 2)

        #expect(
            throws: WorktreeAnnotationRepositoryError.sessionSelectionRequired(
                .init(
                    reason: .applicableSessionChoice,
                    candidateSessionIDs: [first.session.id, second.session.id]
                )
            )
        ) {
            try repository.createRootDraft(
                .init(
                    admission: .implicitOrSingle,
                    repositoryID: "repo-1",
                    worktreeID: "worktree-1",
                    sourceFingerprint: sourceFingerprint,
                    origin: .session,
                    body: "Ambiguous",
                    editToken: "editor-c",
                    now: Date(timeIntervalSince1970: 30)
                )
            )
        }

        let selected = try repository.createRootDraft(
            .init(
                admission: .selected(first.session.id),
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: sourceFingerprint,
                origin: .session,
                body: "Explicit continuation",
                editToken: "editor-c",
                now: Date(timeIntervalSince1970: 40)
            )
        ).canonicalResult
        #expect(selected.session.id == first.session.id)
        #expect(selected.threads.count == 2)
    }

    @Test("projection snapshot reads discovery and demanded details from one worktree")
    func projectionSnapshotIsWorktreeBound() throws {
        let repository = try makeRepository()
        let first = try makeRootDraft(repository: repository)
        let completedFirst = try repository.setSessionLifecycle(
            .init(
                sessionID: first.session.id,
                lifecycle: .completed,
                expectedSessionRevision: first.session.semanticRevision,
                expectedOpenThreadCount: 1,
                confirmsUnresolvedWork: true,
                now: Date(timeIntervalSince1970: 1.5)
            )
        ).canonicalResult
        let second = try repository.createRootDraft(
            .init(
                admission: .newSession,
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: makeSourceFingerprint(worktreeID: "worktree-1"),
                origin: .session,
                body: "Second session",
                editToken: "editor-second",
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult
        _ = try repository.setSessionLifecycle(
            .init(
                sessionID: completedFirst.session.id,
                lifecycle: .living,
                expectedSessionRevision: completedFirst.session.semanticRevision,
                expectedOpenThreadCount: 1,
                confirmsUnresolvedWork: false,
                now: Date(timeIntervalSince1970: 2.5)
            )
        )

        let snapshot = try repository.fetchProjectionSnapshot(
            worktreeID: "worktree-1",
            demandedSessionIDs: [second.session.id]
        )

        #expect(snapshot.sessions.map(\.id) == [first.session.id, second.session.id])
        #expect(snapshot.details.map(\.session.id) == [second.session.id])
        #expect(snapshot.details.first?.threads.first?.messages.first?.draft?.body == "Second session")

        #expect(throws: WorktreeAnnotationRepositoryError.notFound) {
            try repository.fetchProjectionSnapshot(
                worktreeID: "another-worktree",
                demandedSessionIDs: [first.session.id]
            )
        }
    }

    @Test("opposite-surface root admission preserves both source provenance axes")
    func oppositeSurfaceRootAdmissionMergesSourceFingerprint() throws {
        let repository = try makeRepository()
        let reviewComparisonOrigin = WorktreeAnnotationReviewComparisonOrigin(
            symbolicTarget: "HEAD",
            resolvedTargetOID: "target-oid",
            reviewedHeadOID: "head-oid",
            baseRole: "commonCommit",
            baseOID: "base-oid"
        )
        let reviewDetail = try repository.createRootDraft(
            .init(
                admission: .implicitOrSingle,
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: .init(
                    repositoryID: "repo-1",
                    worktreeID: "worktree-1",
                    fileSourceIdentity: nil,
                    reviewComparisonOrigin: reviewComparisonOrigin
                ),
                origin: .located(
                    .init(
                        repositoryRelativePath: "Sources/Review.swift",
                        startLine: 4,
                        endLine: 8,
                        sourceRole: .reviewHead,
                        diffSide: .additions,
                        sourceIdentity: "review-source-1",
                        selectedExcerpt: "let reviewed = true",
                        contextBefore: nil,
                        contextAfter: nil
                    )
                ),
                body: "Review draft",
                editToken: "editor-review",
                now: Date(timeIntervalSince1970: 1)
            )
        ).canonicalResult

        let mixedDetail = try repository.createRootDraft(
            .init(
                admission: .selected(reviewDetail.session.id),
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: makeSourceFingerprint(worktreeID: "worktree-1"),
                origin: .located(
                    .init(
                        repositoryRelativePath: "Sources/File.swift",
                        startLine: 10,
                        endLine: 12,
                        sourceRole: .file,
                        diffSide: nil,
                        sourceIdentity: "file-source-1",
                        selectedExcerpt: "let file = true",
                        contextBefore: nil,
                        contextAfter: nil
                    )
                ),
                body: "File draft",
                editToken: "editor-file",
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult

        #expect(mixedDetail.session.acceptedSourceFingerprint.fileSourceIdentity == "file-source-1")
        #expect(
            mixedDetail.session.acceptedSourceFingerprint.reviewComparisonOrigin
                == reviewComparisonOrigin
        )
    }

    @Test("relevant uncertain session blocks zero-session implicit creation")
    func uncertainSessionHasPriorityOverImplicitCreation() throws {
        let repository = try makeRepository()
        var detail = try makeRootDraft(repository: repository)
        detail = try repository.setSourceRelationship(
            .init(
                sessionID: detail.session.id,
                relationship: .uncertain,
                sourceFingerprint: nil,
                expectedSessionRevision: detail.session.semanticRevision,
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult

        #expect(
            throws: WorktreeAnnotationRepositoryError.sessionSelectionRequired(
                .init(
                    reason: .uncertainContinuityChoice,
                    candidateSessionIDs: [detail.session.id]
                )
            )
        ) {
            try repository.createRootDraft(
                .init(
                    admission: .implicitOrSingle,
                    repositoryID: "repo-1",
                    worktreeID: "worktree-1",
                    sourceFingerprint: makeSourceFingerprint(worktreeID: "worktree-1"),
                    origin: .session,
                    body: "Must choose continuity first",
                    editToken: "editor-new",
                    now: Date(timeIntervalSince1970: 3)
                )
            )
        }
        #expect(try repository.discoverSessions(worktreeID: "worktree-1").count == 1)
    }

    @Test("draft save revert replies and resolution use revisions and flat ordering")
    func draftSaveRevertRepliesAndResolutionUseRevisions() throws {
        let repository = try makeRepository()
        var detail = try makeRootDraft(repository: repository)
        let rootMessage = try #require(detail.threads.first?.messages.first)

        detail = try repository.saveDraft(
            .init(
                sessionID: detail.session.id,
                messageID: rootMessage.id,
                editToken: "editor-root",
                expectedMessageRevision: rootMessage.semanticRevision,
                expectedDraftRevision: 0,
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult
        let savedRoot = try #require(detail.threads.first?.messages.first)
        #expect(savedRoot.savedBody == "Root draft")
        #expect(savedRoot.savedRevision == 1)
        #expect(savedRoot.draft == nil)
        #expect(savedRoot.handled == false)

        detail = try repository.flushDraft(
            .init(
                sessionID: detail.session.id,
                messageID: savedRoot.id,
                editToken: "editor-root-v2",
                expectedMessageRevision: savedRoot.semanticRevision,
                expectedDraftRevision: nil,
                body: "Root edit",
                now: Date(timeIntervalSince1970: 3)
            )
        ).canonicalResult.detail
        let editedRoot = try #require(detail.threads.first?.messages.first)
        #expect(editedRoot.draft?.body == "Root edit")

        #expect(throws: WorktreeAnnotationRepositoryError.editTokenConflict) {
            try repository.flushDraft(
                .init(
                    sessionID: detail.session.id,
                    messageID: editedRoot.id,
                    editToken: "stale-editor",
                    expectedMessageRevision: editedRoot.semanticRevision,
                    expectedDraftRevision: editedRoot.draft?.draftRevision,
                    body: "Overwrite",
                    now: Date(timeIntervalSince1970: 4)
                )
            )
        }

        detail = try repository.revertDraft(
            .init(
                sessionID: detail.session.id,
                messageID: editedRoot.id,
                editToken: "editor-root-v2",
                expectedMessageRevision: editedRoot.semanticRevision,
                expectedDraftRevision: try #require(editedRoot.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 5)
            )
        ).canonicalResult.detail
        #expect(detail.threads.first?.messages.first?.draft == nil)

        let threadID = try #require(detail.threads.first?.thread.id)
        detail = try repository.createReplyDraft(
            .init(
                sessionID: detail.session.id,
                threadID: threadID,
                expectedThreadRevision: try #require(detail.threads.first?.thread.semanticRevision),
                body: "Flat reply",
                editToken: "editor-reply",
                now: Date(timeIntervalSince1970: 6)
            )
        ).canonicalResult
        #expect(detail.threads.first?.messages.map(\.ordinal) == [0, 1])

        detail = try repository.setThreadResolution(
            .init(
                sessionID: detail.session.id,
                threadID: threadID,
                resolution: .resolved,
                expectedThreadRevision: try #require(detail.threads.first?.thread.semanticRevision),
                now: Date(timeIntervalSince1970: 7)
            )
        ).canonicalResult
        #expect(detail.threads.first?.thread.resolution == .resolved)
        #expect(detail.threads.first?.messages.count == 2)

        #expect(
            throws: WorktreeAnnotationRepositoryError.conflict(
                currentRevision: try #require(detail.threads.first?.thread.semanticRevision)
            )
        ) {
            try repository.setThreadResolution(
                .init(
                    sessionID: detail.session.id,
                    threadID: threadID,
                    resolution: .open,
                    expectedThreadRevision: try #require(detail.threads.first?.thread.semanticRevision) - 1,
                    now: Date(timeIntervalSince1970: 8)
                )
            )
        }
    }

    @Test("output prepare preserves exact bytes and membership with idempotent terminal transitions")
    func outputPreparePreservesExactBytesAndMembership() throws {
        let repository = try makeRepository()
        var detail = try makeRootDraft(repository: repository)
        let root = try #require(detail.threads.first?.messages.first)
        detail = try repository.saveDraft(
            .init(
                sessionID: detail.session.id,
                messageID: root.id,
                editToken: "editor-root",
                expectedMessageRevision: root.semanticRevision,
                expectedDraftRevision: 0,
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult
        let savedMessage = try #require(detail.threads.first?.messages.first)
        let savedRevision = try #require(savedMessage.savedRevision)
        let firstAttemptID = WorktreeAnnotationOutputAttemptID.generate()
        let firstSnapshot = try makeOutputSnapshot(
            attemptID: firstAttemptID,
            detail: detail,
            messageID: savedMessage.id,
            savedRevision: savedRevision,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let markdownPresentation = testMarkdownPresentation()
        let exactBytes = WorktreeAnnotationBatchProjector.markdownData(
            for: firstSnapshot,
            presentation: markdownPresentation
        )

        var attempt = try repository.prepareOutput(
            .init(
                attemptID: firstAttemptID,
                sessionID: detail.session.id,
                outputKind: .clipboardMarkdown,
                formatVersion: 2,
                contentType: "text/markdown; charset=utf-8",
                canonicalSnapshot: firstSnapshot,
                exactBytes: exactBytes,
                markdownPresentation: markdownPresentation,
                destinationPath: nil,
                repeatedFromAttemptID: nil,
                selectedMessages: [
                    .init(messageID: savedMessage.id, expectedSavedRevision: savedRevision)
                ],
                now: Date(timeIntervalSince1970: 3)
            )
        )
        let preparedRevision = try repositoryTestContentSessionRevision(attempt)
        #expect(preparedRevision == detail.session.semanticRevision + 1)
        #expect(attempt.canonicalResult.attempt.exactBytes == exactBytes)
        #expect(attempt.canonicalResult.selectedSavedRevisions == [savedRevision])
        #expect(
            try repository.fetchSessionDetail(sessionID: detail.session.id).threads.first?.messages.first?.status
                == .editable)

        attempt = try repository.cancelOutputAttempt(
            attemptID: attempt.canonicalResult.attempt.id,
            now: Date(timeIntervalSince1970: 4)
        )
        let cancelledRevision = try repositoryTestContentSessionRevision(attempt)
        #expect(cancelledRevision == preparedRevision + 1)
        let repeatedCancellation = try repository.cancelOutputAttempt(
            attemptID: attempt.canonicalResult.attempt.id,
            now: Date(timeIntervalSince1970: 5)
        )
        #expect(attempt.canonicalResult.attempt.state == .cancelled)
        #expect(repeatedCancellation.canonicalResult == attempt.canonicalResult)
        #expect(repeatedCancellation.change == .noChange)
        #expect(
            try repository.fetchSessionDetail(sessionID: detail.session.id).threads.first?.messages.first?.status
                == .editable)

        try verifyFinalizedOutputLocksSavedMessage(
            repository: repository,
            detail: detail,
            savedMessage: savedMessage,
            savedRevision: savedRevision
        )
    }

    @Test("session lifecycle stays orthogonal to relationship and recovery acknowledgement retains its witness")
    func lifecycleRelationshipAndRecoveryWitnessRemainIndependent() throws {
        let repository = try makeRepository()
        var detail = try makeRootDraft(repository: repository)

        #expect(throws: WorktreeAnnotationRepositoryError.unresolvedWorkConfirmationRequired) {
            try repository.setSessionLifecycle(
                .init(
                    sessionID: detail.session.id,
                    lifecycle: .completed,
                    expectedSessionRevision: detail.session.semanticRevision,
                    expectedOpenThreadCount: 1,
                    confirmsUnresolvedWork: false,
                    now: Date(timeIntervalSince1970: 2)
                )
            )
        }
        detail = try repository.setSessionLifecycle(
            .init(
                sessionID: detail.session.id,
                lifecycle: .completed,
                expectedSessionRevision: detail.session.semanticRevision,
                expectedOpenThreadCount: 1,
                confirmsUnresolvedWork: true,
                now: Date(timeIntervalSince1970: 3)
            )
        ).canonicalResult
        detail = try repository.setSourceRelationship(
            .init(
                sessionID: detail.session.id,
                relationship: .detached,
                sourceFingerprint: nil,
                expectedSessionRevision: detail.session.semanticRevision,
                now: Date(timeIntervalSince1970: 4)
            )
        ).canonicalResult
        detail = try repository.setSessionLifecycle(
            .init(
                sessionID: detail.session.id,
                lifecycle: .living,
                expectedSessionRevision: detail.session.semanticRevision,
                expectedOpenThreadCount: 1,
                confirmsUnresolvedWork: false,
                now: Date(timeIntervalSince1970: 5)
            )
        ).canonicalResult
        #expect(detail.session.lifecycle == .living)
        #expect(detail.session.sourceRelationship == .detached)

        let witness = try repository.recordRecoveryProvenance(
            quarantinedFilenames: ["local.sqlite.corrupt-1", "local.sqlite-wal.corrupt-1"],
            reason: "integrity check failed",
            recoveredAt: Date(timeIntervalSince1970: 6)
        )
        #expect(try repository.fetchUnacknowledgedRecoveryProvenance() == witness)

        let acknowledged = try repository.acknowledgeRecoveryProvenance(
            id: witness.id,
            acknowledgedAt: Date(timeIntervalSince1970: 7)
        )
        #expect(acknowledged.acknowledgedAt == Date(timeIntervalSince1970: 7))
        #expect(try repository.fetchUnacknowledgedRecoveryProvenance() == nil)
        #expect(try repository.fetchRecoveryProvenance(id: witness.id) == acknowledged)
    }

    @Test("completed uncertain and detached sessions reject authoring until explicitly reopened and applicable")
    func nonWritableSessionAxesRejectAuthoringMutations() throws {
        let repository = try makeRepository()
        var detail = try makeRootDraft(repository: repository)
        let threadID = try #require(detail.threads.first?.thread.id)
        let rootMessage = try #require(detail.threads.first?.messages.first)

        detail = try repository.setSessionLifecycle(
            .init(
                sessionID: detail.session.id,
                lifecycle: .completed,
                expectedSessionRevision: detail.session.semanticRevision,
                expectedOpenThreadCount: 1,
                confirmsUnresolvedWork: true,
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult

        assertCompletedSessionRejectsAuthoring(
            repository: repository,
            detail: detail,
            rootMessage: rootMessage
        )

        detail = try repository.setSessionLifecycle(
            .init(
                sessionID: detail.session.id,
                lifecycle: .living,
                expectedSessionRevision: detail.session.semanticRevision,
                expectedOpenThreadCount: 1,
                confirmsUnresolvedWork: false,
                now: Date(timeIntervalSince1970: 4)
            )
        ).canonicalResult
        detail = try repository.setSourceRelationship(
            .init(
                sessionID: detail.session.id,
                relationship: .uncertain,
                sourceFingerprint: nil,
                expectedSessionRevision: detail.session.semanticRevision,
                now: Date(timeIntervalSince1970: 5)
            )
        ).canonicalResult

        #expect(throws: WorktreeAnnotationRepositoryError.sessionReadOnly) {
            try repository.createReplyDraft(
                .init(
                    sessionID: detail.session.id,
                    threadID: threadID,
                    expectedThreadRevision: try #require(detail.threads.first?.thread.semanticRevision),
                    body: "Paused reply",
                    editToken: "uncertain-reply",
                    now: Date(timeIntervalSince1970: 6)
                )
            )
        }

        detail = try repository.setSourceRelationship(
            .init(
                sessionID: detail.session.id,
                relationship: .detached,
                sourceFingerprint: nil,
                expectedSessionRevision: detail.session.semanticRevision,
                now: Date(timeIntervalSince1970: 7)
            )
        ).canonicalResult
        #expect(throws: WorktreeAnnotationRepositoryError.sessionReadOnly) {
            try repository.setThreadResolution(
                .init(
                    sessionID: detail.session.id,
                    threadID: threadID,
                    resolution: .resolved,
                    expectedThreadRevision: try #require(detail.threads.first?.thread.semanticRevision),
                    now: Date(timeIntervalSince1970: 8)
                )
            )
        }

        detail = try repository.setSourceRelationship(
            .init(
                sessionID: detail.session.id,
                relationship: .applicable,
                sourceFingerprint: makeSourceFingerprint(worktreeID: "worktree-1"),
                expectedSessionRevision: detail.session.semanticRevision,
                now: Date(timeIntervalSince1970: 9)
            )
        ).canonicalResult
        detail = try repository.createReplyDraft(
            .init(
                sessionID: detail.session.id,
                threadID: threadID,
                expectedThreadRevision: try #require(detail.threads.first?.thread.semanticRevision),
                body: "Authoring resumed",
                editToken: "resumed-reply",
                now: Date(timeIntervalSince1970: 10)
            )
        ).canonicalResult

        #expect(detail.threads.first?.messages.map(\.draft?.body) == ["Root draft", "Authoring resumed"])
    }
}

private func assertCompletedSessionRejectsAuthoring(
    repository: WorktreeAnnotationSQLiteRepository,
    detail: WorktreeAnnotationSessionDetail,
    rootMessage: WorktreeAnnotationMessage
) {
    #expect(throws: WorktreeAnnotationRepositoryError.sessionReadOnly) {
        try repository.createRootDraft(
            .init(
                admission: .selected(detail.session.id),
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: makeSourceFingerprint(worktreeID: "worktree-1"),
                origin: .session,
                body: "Must reopen first",
                editToken: "completed-root",
                now: Date(timeIntervalSince1970: 3)
            )
        )
    }
    #expect(throws: WorktreeAnnotationRepositoryError.sessionReadOnly) {
        try repository.flushDraft(
            .init(
                sessionID: detail.session.id,
                messageID: rootMessage.id,
                editToken: "editor-root",
                expectedMessageRevision: rootMessage.semanticRevision,
                expectedDraftRevision: 0,
                body: "Must reopen first",
                now: Date(timeIntervalSince1970: 3)
            )
        )
    }
}

private func verifyFinalizedOutputLocksSavedMessage(
    repository: WorktreeAnnotationSQLiteRepository,
    detail: WorktreeAnnotationSessionDetail,
    savedMessage: WorktreeAnnotationMessage,
    savedRevision: Int
) throws {
    let attemptID = WorktreeAnnotationOutputAttemptID.generate()
    let snapshot = try makeOutputSnapshot(
        attemptID: attemptID,
        detail: detail,
        messageID: savedMessage.id,
        savedRevision: savedRevision,
        createdAt: Date(timeIntervalSince1970: 6)
    )
    let markdownPresentation = testMarkdownPresentation()
    let exactBytes = WorktreeAnnotationBatchProjector.markdownData(
        for: snapshot,
        presentation: markdownPresentation
    )
    let attempt = try repository.prepareOutput(
        .init(
            attemptID: attemptID,
            sessionID: detail.session.id,
            outputKind: .clipboardMarkdown,
            formatVersion: 2,
            contentType: "text/markdown; charset=utf-8",
            canonicalSnapshot: snapshot,
            exactBytes: exactBytes,
            markdownPresentation: markdownPresentation,
            destinationPath: nil,
            repeatedFromAttemptID: nil,
            selectedMessages: [
                .init(messageID: savedMessage.id, expectedSavedRevision: savedRevision)
            ],
            now: Date(timeIntervalSince1970: 6)
        )
    )
    let finalized = try repository.finalizeOutputAttempt(
        attemptID: attempt.canonicalResult.attempt.id,
        eventKind: .copied,
        now: Date(timeIntervalSince1970: 7)
    )
    let repeatedFinalization = try repository.finalizeOutputAttempt(
        attemptID: attempt.canonicalResult.attempt.id,
        eventKind: .copied,
        now: Date(timeIntervalSince1970: 8)
    )
    try assertFinalizationRevisionSequence(attempt, finalized, repeatedFinalization)
    #expect(finalized.canonicalResult.attempt.state == .succeeded)
    let finalizedDetail = try repository.fetchSessionDetail(sessionID: detail.session.id)
    let outputMessage = finalizedDetail.threads.first?.messages.first
    #expect(outputMessage?.status == .locked)
    #expect(outputMessage?.handled == true)
    #expect(
        try repository.fetchOutputHistory(sessionID: detail.session.id, limit: 10)
            .first?.canMarkNotHandled == true
    )
    #expect(
        throws: WorktreeAnnotationRepositoryError.conflict(
            currentRevision: finalizedDetail.session.semanticRevision
        )
    ) {
        try repository.clearOutputHandled(
            attemptID: attempt.canonicalResult.attempt.id,
            expectedSessionRevision: finalizedDetail.session.semanticRevision - 1,
            now: Date(timeIntervalSince1970: 9)
        )
    }
    let clearedDetail = try repository.clearOutputHandled(
        attemptID: attempt.canonicalResult.attempt.id,
        expectedSessionRevision: finalizedDetail.session.semanticRevision,
        now: Date(timeIntervalSince1970: 9)
    )
    #expect(clearedDetail.canonicalResult.threads.first?.messages.first?.handled == false)
    #expect(clearedDetail.canonicalResult.threads.first?.messages.first?.status == .locked)
    #expect(
        try repository.fetchOutputHistory(sessionID: detail.session.id, limit: 10)
            .first?.canMarkNotHandled == false
    )
    #expect(
        try repository.inspectOutputAttempt(attemptID: attempt.canonicalResult.attempt.id)
            == finalized.canonicalResult
    )
    let rehandledDetail = try verifyLaterSuccessHandlesClearedRevision(
        repository: repository,
        clearedDetail: clearedDetail.canonicalResult,
        savedMessage: savedMessage,
        savedRevision: savedRevision,
        priorAttemptID: attempt.canonicalResult.attempt.id,
        markdownPresentation: markdownPresentation
    )
    #expect(throws: WorktreeAnnotationRepositoryError.messageLocked) {
        try repository.flushDraft(
            .init(
                sessionID: detail.session.id,
                messageID: savedMessage.id,
                editToken: "editor-after-output",
                expectedMessageRevision: try #require(
                    rehandledDetail.threads.first?.messages.first?.semanticRevision
                ),
                expectedDraftRevision: nil,
                body: "Must be a new reply",
                now: Date(timeIntervalSince1970: 13)
            )
        )
    }
}

private func verifyLaterSuccessHandlesClearedRevision(
    repository: WorktreeAnnotationSQLiteRepository,
    clearedDetail: WorktreeAnnotationSessionDetail,
    savedMessage: WorktreeAnnotationMessage,
    savedRevision: Int,
    priorAttemptID: WorktreeAnnotationOutputAttemptID,
    markdownPresentation: WorktreeAnnotationMarkdownPresentationContext
) throws -> WorktreeAnnotationSessionDetail {
    let repeatedClearDetail = try repository.clearOutputHandled(
        attemptID: priorAttemptID,
        expectedSessionRevision: clearedDetail.session.semanticRevision,
        now: Date(timeIntervalSince1970: 10)
    )
    #expect(
        repeatedClearDetail.canonicalResult.session.semanticRevision
            == clearedDetail.session.semanticRevision
    )
    #expect(repeatedClearDetail.change == .noChange)
    let repeatedAttemptID = WorktreeAnnotationOutputAttemptID.generate()
    let repeatedSnapshot = try makeOutputSnapshot(
        attemptID: repeatedAttemptID,
        detail: clearedDetail,
        messageID: savedMessage.id,
        savedRevision: savedRevision,
        createdAt: Date(timeIntervalSince1970: 11)
    )
    let repeatedBytes = WorktreeAnnotationBatchProjector.markdownData(
        for: repeatedSnapshot,
        presentation: markdownPresentation
    )
    _ = try repository.prepareOutput(
        .init(
            attemptID: repeatedAttemptID,
            sessionID: clearedDetail.session.id,
            outputKind: .clipboardMarkdown,
            formatVersion: 2,
            contentType: "text/markdown; charset=utf-8",
            canonicalSnapshot: repeatedSnapshot,
            exactBytes: repeatedBytes,
            markdownPresentation: markdownPresentation,
            destinationPath: nil,
            repeatedFromAttemptID: nil,
            selectedMessages: [
                .init(messageID: savedMessage.id, expectedSavedRevision: savedRevision)
            ],
            now: Date(timeIntervalSince1970: 11)
        )
    )
    _ = try repository.finalizeOutputAttempt(
        attemptID: repeatedAttemptID,
        eventKind: .copied,
        now: Date(timeIntervalSince1970: 12)
    )
    let rehandledDetail = try repository.fetchSessionDetail(sessionID: clearedDetail.session.id)
    #expect(rehandledDetail.threads.first?.messages.first?.handled == true)
    return rehandledDetail
}

private func makeOutputSnapshot(
    attemptID: WorktreeAnnotationOutputAttemptID,
    detail: WorktreeAnnotationSessionDetail,
    messageID: WorktreeAnnotationMessageID,
    savedRevision: Int,
    createdAt: Date
) throws -> WorktreeAnnotationBatchSnapshotV2 {
    try WorktreeAnnotationBatchProjector.makeSnapshot(
        .init(
            batchID: attemptID,
            createdAt: createdAt,
            sessionDetail: detail,
            selectedMessages: [
                .init(messageID: messageID, expectedSavedRevision: savedRevision)
            ],
            placementsByThreadID: Dictionary(
                uniqueKeysWithValues: detail.threads.map { threadDetail in
                    (
                        threadDetail.thread.id,
                        WorktreeAnnotationThreadPlacementProjection(
                            placement: .exact,
                            currentPath: "Sources/Feature.swift",
                            currentStartLine: 1,
                            currentEndLine: 1,
                            currentSourceIdentity: "file-source-1"
                        )
                    )
                }
            ),
            sessionLabel: "Current review",
            worktreeLabel: "agent-studio.review-comments",
            comparisonLabel: nil
        )
    )
}

private func testMarkdownPresentation() -> WorktreeAnnotationMarkdownPresentationContext {
    .init(worktreeLabel: "agent-studio.review-comments", comparisonLabel: nil)
}

private func repositoryTestContentSessionRevision<TCanonicalResult: Sendable>(
    _ mutation: WorktreeAnnotationCommittedMutation<TCanonicalResult>
) throws -> Int {
    guard case .content(let sessionChanges) = mutation.change else {
        Issue.record("Expected content classification")
        return -1
    }
    return try #require(sessionChanges.first).semanticRevision
}

private func assertFinalizationRevisionSequence(
    _ prepared: WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>,
    _ finalized: WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>,
    _ repeatedFinalization: WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
) throws {
    let preparedRevision = try repositoryTestContentSessionRevision(prepared)
    let finalizedRevision = try repositoryTestContentSessionRevision(finalized)
    #expect(finalizedRevision == preparedRevision + 1)
    #expect(repeatedFinalization.canonicalResult == finalized.canonicalResult)
    #expect(repeatedFinalization.change == .noChange)
}
