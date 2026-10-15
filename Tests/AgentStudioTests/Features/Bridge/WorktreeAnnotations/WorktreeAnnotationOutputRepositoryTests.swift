import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation output repository")
struct WorktreeAnnotationOutputRepositoryTests {
    @Test("prepare persists strict canonical semantics, exact bytes, and ordered membership")
    func preparePersistsCanonicalSemanticsAndExactMaterialization() throws {
        let fixture = try makeOutputRepositoryFixture()

        let preparedMutation = try fixture.repository.prepareOutput(fixture.prepareProps())
        let prepared = preparedMutation.canonicalResult

        let preparedRevision = try contentSessionRevision(preparedMutation)
        #expect(preparedRevision == fixture.detail.session.semanticRevision + 1)
        #expect(prepared.canonicalSnapshot == .v2(fixture.snapshot))
        #expect(prepared.attempt.exactBytes == fixture.exactBytes)
        #expect(
            prepared.memberships == [
                .init(
                    messageID: fixture.message.id,
                    expectedSavedRevision: fixture.savedRevision,
                    batchOrdinal: 0
                )
            ]
        )
        let storedSnapshotJSON = try fixture.databaseQueue.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT snapshot_json FROM annotation_output_attempt WHERE id = ?",
                arguments: [fixture.attemptID.rawValue.uuidString]
            )
        }
        #expect(storedSnapshotJSON.map { Data($0.utf8) } == fixture.snapshotJSON)
        #expect(prepared.attempt.formatVersion == 2)
    }

    @Test(
        "listed comment staleness conflicts without durable output rows",
        arguments: ["revision", "deleted", "draft", "foreign"])
    func staleListedCommentConflictsWithoutOutputRows(_ mutation: String) throws {
        let fixture = try makeOutputRepositoryFixture()
        let props = try fixture.prepareProps()
        let foreignSessionID: WorktreeAnnotationSessionID?
        if mutation == "foreign" {
            foreignSessionID = try fixture.repository.createRootDraft(
                .init(
                    admission: .newSession,
                    repositoryID: "repository-1",
                    worktreeID: "worktree-other",
                    sourceFingerprint: .init(
                        repositoryID: "repository-1", worktreeID: "worktree-other",
                        fileSourceIdentity: "foreign-source", reviewComparisonOrigin: nil
                    ),
                    origin: try #require(fixture.detail.threads.first?.thread.origin),
                    body: "Foreign session draft", editToken: "foreign-editor",
                    now: Date(timeIntervalSince1970: 4)
                )
            ).canonicalResult.session.id
        } else {
            foreignSessionID = nil
        }
        try fixture.databaseQueue.write { database in
            switch mutation {
            case "revision":
                try database.execute(sql: "UPDATE annotation_message SET saved_revision = saved_revision + 1")
            case "deleted":
                try database.execute(sql: "DELETE FROM annotation_message")
            case "draft":
                try database.execute(
                    sql: """
                        INSERT INTO annotation_message_draft(message_id, body, body_utf8_bytes, draft_revision, updated_at)
                        VALUES (?, 'draft', 5, 0, 4)
                        """,
                    arguments: [fixture.message.id.databaseValue]
                )
            default:
                let foreignID = try #require(foreignSessionID)
                try database.execute(
                    sql: "UPDATE annotation_thread SET session_id = ?, created_ordinal = 2 WHERE id = ?",
                    arguments: [foreignID.databaseValue, fixture.detail.threads[0].thread.id.databaseValue]
                )
            }
        }

        #expect(
            throws: WorktreeAnnotationRepositoryError.conflict(
                currentRevision: fixture.detail.session.semanticRevision
            )
        ) {
            try fixture.repository.prepareOutput(props)
        }
        try fixture.databaseQueue.read { database in
            for tableName in [
                "annotation_output_attempt", "annotation_output_attempt_message", "annotation_output_event",
            ] {
                let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(tableName)")
                #expect(count == 0)
            }
        }
    }

    @Test("mutable source context and thread resolution do not invalidate listed comments")
    func mutableContextDoesNotInvalidateListedComments() throws {
        let fixture = try makeOutputRepositoryFixture()
        let props = try fixture.prepareProps()
        try fixture.databaseQueue.write { database in
            try database.execute(
                sql:
                    "UPDATE annotation_session SET semantic_revision = semantic_revision + 1, source_relationship = 'uncertain'"
            )
            try database.execute(sql: "UPDATE annotation_thread SET resolution = 'resolved'")
        }

        let prepared = try fixture.repository.prepareOutput(props).canonicalResult

        #expect(prepared.memberships.map(\.messageID) == [fixture.message.id])
        #expect(prepared.attempt.exactBytes == fixture.exactBytes)
    }

    @Test("new preparation rejects any non-v2 format declaration")
    func newPreparationRejectsV1FormatDeclaration() throws {
        let fixture = try makeOutputRepositoryFixture()
        let props = try fixture.prepareProps()

        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try fixture.repository.prepareOutput(
                .init(
                    attemptID: props.attemptID,
                    sessionID: props.sessionID,
                    outputKind: props.outputKind,
                    formatVersion: 1,
                    contentType: props.contentType,
                    canonicalSnapshot: props.canonicalSnapshot,
                    exactBytes: props.exactBytes,
                    markdownPresentation: props.markdownPresentation,
                    destinationPath: props.destinationPath,
                    repeatedFromAttemptID: nil,
                    selectedMessages: props.selectedMessages,
                    now: props.now
                )
            )
        }
    }

    @Test("historical v1 inspection and repeat preserve exact stored document and effect bytes")
    func historicalV1InspectionAndRepeatPreserveExactBytes() throws {
        let fixture = try makeOutputRepositoryFixture()
        let prepared = try fixture.repository.prepareOutput(fixture.prepareProps()).canonicalResult
        let unknown = try fixture.repository.markPreparedOutputAttemptsUnknown(
            now: Date(timeIntervalSince1970: 4)
        )
        #expect(unknown.canonicalResult == 1)
        let unknownRevision = try contentSessionRevision(unknown)
        let v2SnapshotJSONString = try #require(String(data: fixture.snapshotJSON, encoding: .utf8))
        let v1SnapshotJSONString = v2SnapshotJSONString.replacingOccurrences(
            of: "\"formatVersion\":2",
            with: "\"formatVersion\":1"
        )
        let v1SnapshotJSON = Data(v1SnapshotJSONString.utf8)
        let historicalExactBytes = Data("historical v1 exact bytes".utf8)
        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: """
                    UPDATE annotation_output_attempt
                    SET format_version = 1, snapshot_json = ?, exact_bytes = ?
                    WHERE id = ?
                    """,
                arguments: [
                    v1SnapshotJSONString,
                    historicalExactBytes,
                    prepared.attempt.id.databaseValue,
                ]
            )
        }

        let inspected = try fixture.repository.inspectOutputAttempt(attemptID: prepared.attempt.id)
        #expect(inspected.canonicalSnapshot.formatVersion == 1)
        #expect(inspected.attempt.exactBytes == historicalExactBytes)

        let repeatedAttemptID = WorktreeAnnotationOutputAttemptID(rawValue: testUUID(92))
        let repeatedMutation = try fixture.repository.repeatOutputAttempt(
            sourceAttemptID: prepared.attempt.id,
            repeatedAttemptID: repeatedAttemptID,
            destinationPath: nil,
            now: Date(timeIntervalSince1970: 5)
        )
        let repeated = repeatedMutation.canonicalResult
        #expect(try contentSessionRevision(repeatedMutation) == unknownRevision + 1)
        #expect(repeated.attempt.formatVersion == 1)
        #expect(repeated.attempt.exactBytes == historicalExactBytes)

        let storedRows = try fixture.databaseQueue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, format_version, snapshot_json, exact_bytes
                    FROM annotation_output_attempt
                    WHERE id IN (?, ?)
                    ORDER BY id
                    """,
                arguments: [prepared.attempt.id.databaseValue, repeatedAttemptID.databaseValue]
            )
        }
        #expect(storedRows.count == 2)
        for row in storedRows {
            #expect(row["format_version"] as Int == 1)
            #expect(Data((row["snapshot_json"] as String).utf8) == v1SnapshotJSON)
            #expect(row["exact_bytes"] as Data == historicalExactBytes)
        }
    }

    @Test("inspection fails closed when persisted canonical semantics are malformed")
    func inspectionFailsClosedForMalformedCanonicalSemantics() throws {
        let fixture = try makeOutputRepositoryFixture()
        _ = try fixture.repository.prepareOutput(fixture.prepareProps())
        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: "UPDATE annotation_output_attempt SET snapshot_json = ? WHERE id = ?",
                arguments: ["{\"formatVersion\":1,\"unexpected\":true}", fixture.attemptID.rawValue.uuidString]
            )
        }

        #expect(throws: (any Error).self) {
            try fixture.repository.inspectOutputAttempt(attemptID: fixture.attemptID)
        }
    }

    @Test("prepare rejects a snapshot whose durable message semantics do not match SQLite")
    func prepareRejectsSnapshotWithFabricatedDurableSemantics() throws {
        let fixture = try makeOutputRepositoryFixture()
        let persistedEntry = try #require(fixture.snapshot.entries.first)
        let fabricatedEntry = WorktreeAnnotationBatchSnapshotV2.Entry(
            batchOrdinal: persistedEntry.batchOrdinal,
            thread: .init(
                threadID: persistedEntry.threadID,
                resolution: .resolved,
                origin: persistedEntry.origin,
                placement: persistedEntry.placement
            ),
            message: .init(
                messageID: persistedEntry.messageID,
                messageOrdinal: persistedEntry.messageOrdinal,
                authorKind: .human,
                savedRevision: persistedEntry.savedRevision,
                bodyMarkdown: "Fabricated output body"
            )
        )
        let fabricatedSnapshot = WorktreeAnnotationBatchSnapshotV2(
            batchID: fixture.snapshot.batchID,
            createdAt: fixture.snapshot.createdAt,
            session: fixture.snapshot.session,
            entries: [fabricatedEntry]
        )

        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try fixture.repository.prepareOutput(
                fixture.prepareProps(
                    canonicalSnapshot: fabricatedSnapshot,
                    exactBytes: WorktreeAnnotationBatchProjector.markdownData(
                        for: fabricatedSnapshot,
                        presentation: outputRepositoryMarkdownPresentation
                    )
                )
            )
        }
    }

    @Test("one session admits only one prepared output attempt at a time")
    func prepareRejectsSecondInFlightAttemptForSession() throws {
        let fixture = try makeOutputRepositoryFixture()
        _ = try fixture.repository.prepareOutput(fixture.prepareProps())
        let threadID = try #require(fixture.detail.threads.first?.thread.id)
        var detailWithReply = try fixture.repository.createReplyDraft(
            .init(
                sessionID: fixture.detail.session.id,
                threadID: threadID,
                expectedThreadRevision: try #require(fixture.detail.threads.first?.thread.semanticRevision),
                body: "A distinct reply for the next output",
                editToken: "reply-editor",
                now: Date(timeIntervalSince1970: 4)
            )
        ).canonicalResult
        let replyDraft = try #require(detailWithReply.threads.first?.messages.last)
        detailWithReply = try fixture.repository.saveDraft(
            .init(
                sessionID: detailWithReply.session.id,
                messageID: replyDraft.id,
                editToken: "reply-editor",
                expectedMessageRevision: replyDraft.semanticRevision,
                expectedDraftRevision: 0,
                now: Date(timeIntervalSince1970: 5)
            )
        ).canonicalResult
        let reply = try #require(detailWithReply.threads.first?.messages.last)
        let replySavedRevision = try #require(reply.savedRevision)
        let nextAttemptID = WorktreeAnnotationOutputAttemptID(rawValue: testUUID(72))
        let nextSnapshot = try WorktreeAnnotationBatchProjector.makeSnapshot(
            .init(
                batchID: nextAttemptID,
                createdAt: Date(timeIntervalSince1970: 6),
                sessionDetail: detailWithReply,
                selectedMessages: [
                    .init(messageID: reply.id, expectedSavedRevision: replySavedRevision)
                ],
                placementsByThreadID: outputRepositoryPlacements(detailWithReply),
                sessionLabel: "Current review",
                worktreeLabel: "agent-studio.review-comments",
                comparisonLabel: nil
            )
        )

        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try fixture.repository.prepareOutput(
                .init(
                    attemptID: nextAttemptID,
                    sessionID: detailWithReply.session.id,
                    outputKind: .clipboardMarkdown,
                    formatVersion: nextSnapshot.formatVersion,
                    contentType: "text/markdown; charset=utf-8",
                    canonicalSnapshot: nextSnapshot,
                    exactBytes: WorktreeAnnotationBatchProjector.markdownData(
                        for: nextSnapshot,
                        presentation: outputRepositoryMarkdownPresentation
                    ),
                    markdownPresentation: outputRepositoryMarkdownPresentation,
                    destinationPath: nil,
                    repeatedFromAttemptID: nil,
                    selectedMessages: [
                        .init(messageID: reply.id, expectedSavedRevision: replySavedRevision)
                    ],
                    now: Date(timeIntervalSince1970: 6)
                )
            )
        }
    }

    @Test("finalization rejects an event kind that contradicts the prepared output kind")
    func finalizationRejectsMismatchedEventKind() throws {
        let fixture = try makeOutputRepositoryFixture()
        let prepared = try fixture.repository.prepareOutput(fixture.prepareProps()).canonicalResult

        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try fixture.repository.finalizeOutputAttempt(
                attemptID: prepared.attempt.id,
                eventKind: .exported,
                now: Date(timeIntervalSince1970: 4)
            )
        }
    }

    @Test("explicit repetition rejects attempts whose external effect is known")
    func explicitRepetitionRejectsKnownAttempts() throws {
        let preparedFixture = try makeOutputRepositoryFixture()
        let prepared = try preparedFixture.repository.prepareOutput(preparedFixture.prepareProps()).canonicalResult
        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try preparedFixture.repository.repeatOutputAttempt(
                sourceAttemptID: prepared.attempt.id,
                repeatedAttemptID: .init(rawValue: testUUID(72)),
                destinationPath: nil,
                now: Date(timeIntervalSince1970: 5)
            )
        }

        let succeededFixture = try makeOutputRepositoryFixture()
        let succeededPrepared = try succeededFixture.repository.prepareOutput(
            succeededFixture.prepareProps()
        ).canonicalResult
        let succeeded = try succeededFixture.repository.finalizeOutputAttempt(
            attemptID: succeededPrepared.attempt.id,
            eventKind: .copied,
            now: Date(timeIntervalSince1970: 4)
        ).canonicalResult
        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try succeededFixture.repository.repeatOutputAttempt(
                sourceAttemptID: succeeded.attempt.id,
                repeatedAttemptID: .init(rawValue: testUUID(73)),
                destinationPath: nil,
                now: Date(timeIntervalSince1970: 5)
            )
        }

        let cancelledFixture = try makeOutputRepositoryFixture()
        let cancelledPrepared = try cancelledFixture.repository.prepareOutput(
            cancelledFixture.prepareProps()
        ).canonicalResult
        let cancelled = try cancelledFixture.repository.cancelOutputAttempt(
            attemptID: cancelledPrepared.attempt.id,
            effectError: "cancelled",
            now: Date(timeIntervalSince1970: 4)
        ).canonicalResult
        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try cancelledFixture.repository.repeatOutputAttempt(
                sourceAttemptID: cancelled.attempt.id,
                repeatedAttemptID: .init(rawValue: testUUID(74)),
                destinationPath: nil,
                now: Date(timeIntervalSince1970: 5)
            )
        }

        let finalizationFailedFixture = try makeOutputRepositoryFixture()
        let finalizationPrepared = try finalizationFailedFixture.repository.prepareOutput(
            finalizationFailedFixture.prepareProps()
        ).canonicalResult
        let finalizationFailed = try finalizationFailedFixture.repository
            .markOutputAttemptFinalizationFailed(
                attemptID: finalizationPrepared.attempt.id,
                cleanupError: "history failed",
                now: Date(timeIntervalSince1970: 4)
            ).canonicalResult
        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try finalizationFailedFixture.repository.repeatOutputAttempt(
                sourceAttemptID: finalizationFailed.attempt.id,
                repeatedAttemptID: .init(rawValue: testUUID(75)),
                destinationPath: nil,
                now: Date(timeIntervalSince1970: 5)
            )
        }
    }

    @Test("history is bounded, newest first, and excludes cancelled attempts")
    func historyIsBoundedAndExcludesCancelledAttempts() throws {
        let fixture = try makeOutputRepositoryFixture()
        let cancelled = try fixture.repository.prepareOutput(fixture.prepareProps()).canonicalResult
        _ = try fixture.repository.cancelOutputAttempt(
            attemptID: cancelled.attempt.id,
            effectError: "clipboard unavailable",
            now: Date(timeIntervalSince1970: 4)
        )

        let unknownAttemptID = WorktreeAnnotationOutputAttemptID(rawValue: testUUID(73))
        let unknown = try fixture.repository.prepareOutput(
            fixture.prepareProps(attemptID: unknownAttemptID, now: Date(timeIntervalSince1970: 5))
        ).canonicalResult
        #expect(
            try fixture.repository.markPreparedOutputAttemptsUnknown(
                now: Date(timeIntervalSince1970: 6)
            ).canonicalResult == 1
        )
        let repeated = try fixture.repository.repeatOutputAttempt(
            sourceAttemptID: unknown.attempt.id,
            repeatedAttemptID: .init(rawValue: testUUID(74)),
            destinationPath: nil,
            now: Date(timeIntervalSince1970: 7)
        ).canonicalResult
        #expect(
            try fixture.repository.markPreparedOutputAttemptsUnknown(
                now: Date(timeIntervalSince1970: 8)
            ).canonicalResult == 1
        )

        let history = try fixture.repository.fetchOutputHistory(
            sessionID: fixture.detail.session.id,
            limit: 1
        )

        #expect(history.count == 1)
        #expect(history.first?.attemptID == repeated.attempt.id)
        #expect(history.first?.state == .unknown)
        #expect(history.first?.messageCount == 1)
        #expect(history.first?.canMarkNotHandled == false)
        #expect(history.first?.attemptID != cancelled.attempt.id)
    }

    @Test("finalization failure locks exact membership without handling or an output event")
    func finalizationFailureLocksWithoutHandling() throws {
        let fixture = try makeOutputRepositoryFixture()
        let prepared = try fixture.repository.prepareOutput(fixture.prepareProps())

        let failed = try fixture.repository.markOutputAttemptFinalizationFailed(
            attemptID: prepared.canonicalResult.attempt.id,
            cleanupError: "forced finalization failure",
            now: Date(timeIntervalSince1970: 4)
        )

        let preparedRevision = try contentSessionRevision(prepared)
        let failedRevision = try contentSessionRevision(failed)
        #expect(failedRevision == preparedRevision + 1)
        let message = try #require(
            fixture.repository.fetchSessionDetail(sessionID: fixture.detail.session.id)
                .threads.first?.messages.first
        )
        #expect(failed.canonicalResult.attempt.state == .finalizationFailed)
        #expect(failed.canonicalResult.event == nil)
        #expect(message.status == .locked)
        #expect(message.handled == false)
        #expect(
            try fixture.repository.fetchOutputHistory(sessionID: fixture.detail.session.id, limit: 10)
                .first?.canMarkNotHandled == false
        )
    }

    @Test("successful output locks agent membership without marking it handled")
    func successfulOutputLocksAgentWithoutHandling() throws {
        let fixture = try makeOutputRepositoryFixture()
        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: "UPDATE annotation_message SET author_kind = 'agent' WHERE id = ?",
                arguments: [fixture.message.id.databaseValue]
            )
        }
        let agentDetail = try fixture.repository.fetchSessionDetail(sessionID: fixture.detail.session.id)
        let prepared = try fixture.repository.prepareOutput(
            fixture.prepareProps(sessionDetail: agentDetail)
        )

        let finalized = try fixture.repository.finalizeOutputAttempt(
            attemptID: prepared.canonicalResult.attempt.id,
            eventKind: .copied,
            now: Date(timeIntervalSince1970: 4)
        )
        let preparedRevision = try contentSessionRevision(prepared)
        let finalizedRevision = try contentSessionRevision(finalized)
        #expect(finalizedRevision == preparedRevision + 1)

        let message = try #require(
            fixture.repository.fetchSessionDetail(sessionID: fixture.detail.session.id)
                .threads.first?.messages.first
        )
        #expect(message.authorKind == .agent)
        #expect(message.status == .locked)
        #expect(message.handled == false)
    }

    @Test("unknown recovery locks exact membership without handling or replay evidence")
    func unknownRecoveryLocksWithoutHandling() throws {
        let fixture = try makeOutputRepositoryFixture()
        let prepared = try fixture.repository.prepareOutput(fixture.prepareProps())

        let changed = try fixture.repository.markPreparedOutputAttemptsUnknown(
            now: Date(timeIntervalSince1970: 4)
        )
        #expect(changed.canonicalResult == 1)
        let preparedRevision = try contentSessionRevision(prepared)
        let changedRevision = try contentSessionRevision(changed)
        #expect(changedRevision == preparedRevision + 1)
        let unchanged = try fixture.repository.markPreparedOutputAttemptsUnknown(
            now: Date(timeIntervalSince1970: 5)
        )
        #expect(unchanged.canonicalResult == 0)
        #expect(unchanged.change == .noChange)

        let recovered = try fixture.repository.inspectOutputAttempt(attemptID: prepared.canonicalResult.attempt.id)
        let message = try #require(
            fixture.repository.fetchSessionDetail(sessionID: fixture.detail.session.id)
                .threads.first?.messages.first
        )
        #expect(recovered.attempt.state == .unknown)
        #expect(recovered.event == nil)
        #expect(message.status == .locked)
        #expect(message.handled == false)
        #expect(
            try fixture.repository.fetchOutputHistory(sessionID: fixture.detail.session.id, limit: 10)
                .first?.canMarkNotHandled == false
        )
    }

}

private struct OutputRepositoryFixture {
    let databaseQueue: DatabaseQueue
    let repository: WorktreeAnnotationSQLiteRepository
    let detail: WorktreeAnnotationSessionDetail
    let message: WorktreeAnnotationMessage
    let savedRevision: Int
    let attemptID: WorktreeAnnotationOutputAttemptID
    let snapshot: WorktreeAnnotationBatchSnapshotV2
    let snapshotJSON: Data
    let exactBytes: Data

    func prepareProps(
        attemptID: WorktreeAnnotationOutputAttemptID? = nil,
        now: Date = Date(timeIntervalSince1970: 3),
        sessionDetail: WorktreeAnnotationSessionDetail? = nil,
        canonicalSnapshot: WorktreeAnnotationBatchSnapshotV2? = nil,
        exactBytes: Data? = nil
    ) throws -> WorktreeAnnotationSQLiteRepository.PrepareOutputProps {
        let selectedAttemptID = attemptID ?? self.attemptID
        let selectedSessionDetail = sessionDetail ?? detail
        let selectedSnapshot =
            try canonicalSnapshot
            ?? WorktreeAnnotationBatchProjector.makeSnapshot(
                .init(
                    batchID: selectedAttemptID,
                    createdAt: now,
                    sessionDetail: selectedSessionDetail,
                    selectedMessages: [
                        .init(messageID: message.id, expectedSavedRevision: savedRevision)
                    ],
                    placementsByThreadID: outputRepositoryPlacements(detail),
                    sessionLabel: "Current review",
                    worktreeLabel: "agent-studio.review-comments",
                    comparisonLabel: nil
                )
            )
        return .init(
            attemptID: selectedAttemptID,
            sessionID: selectedSessionDetail.session.id,
            outputKind: .clipboardMarkdown,
            formatVersion: WorktreeAnnotationBatchSnapshotV2.currentFormatVersion,
            contentType: "text/markdown; charset=utf-8",
            canonicalSnapshot: selectedSnapshot,
            exactBytes: exactBytes
                ?? WorktreeAnnotationBatchProjector.markdownData(
                    for: selectedSnapshot,
                    presentation: outputRepositoryMarkdownPresentation
                ),
            markdownPresentation: outputRepositoryMarkdownPresentation,
            destinationPath: nil,
            repeatedFromAttemptID: nil,
            selectedMessages: [
                .init(messageID: message.id, expectedSavedRevision: savedRevision)
            ],
            now: now
        )
    }
}

private func makeOutputRepositoryFixture() throws -> OutputRepositoryFixture {
    let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
    try WorkspaceLocalMigrations.migrate(databaseQueue)
    let repository = WorktreeAnnotationSQLiteRepository(databaseWriter: databaseQueue)
    var detail = try repository.createRootDraft(
        .init(
            admission: .implicitOrSingle,
            repositoryID: "repository-1",
            worktreeID: "worktree-1",
            sourceFingerprint: .init(
                repositoryID: "repository-1",
                worktreeID: "worktree-1",
                fileSourceIdentity: "source-1",
                reviewComparisonOrigin: nil
            ),
            origin: .located(
                .init(
                    repositoryRelativePath: "Sources/Feature.swift",
                    startLine: 1,
                    endLine: 1,
                    sourceRole: .file,
                    diffSide: nil,
                    sourceIdentity: "source-1",
                    selectedExcerpt: "let value = 1",
                    contextBefore: nil,
                    contextAfter: nil
                )
            ),
            body: "Keep this behavior",
            editToken: "editor-1",
            now: Date(timeIntervalSince1970: 1)
        )
    ).canonicalResult
    let draftMessage = try #require(detail.threads.first?.messages.first)
    detail = try repository.saveDraft(
        .init(
            sessionID: detail.session.id,
            messageID: draftMessage.id,
            editToken: "editor-1",
            expectedMessageRevision: draftMessage.semanticRevision,
            expectedDraftRevision: 0,
            now: Date(timeIntervalSince1970: 2)
        )
    ).canonicalResult
    let message = try #require(detail.threads.first?.messages.first)
    let savedRevision = try #require(message.savedRevision)
    let attemptID = WorktreeAnnotationOutputAttemptID(rawValue: testUUID(71))
    let snapshot = try WorktreeAnnotationBatchProjector.makeSnapshot(
        .init(
            batchID: attemptID,
            createdAt: Date(timeIntervalSince1970: 3),
            sessionDetail: detail,
            selectedMessages: [
                .init(messageID: message.id, expectedSavedRevision: savedRevision)
            ],
            placementsByThreadID: outputRepositoryPlacements(detail),
            sessionLabel: "Current review",
            worktreeLabel: "agent-studio.review-comments",
            comparisonLabel: nil
        )
    )
    return try OutputRepositoryFixture(
        databaseQueue: databaseQueue,
        repository: repository,
        detail: detail,
        message: message,
        savedRevision: savedRevision,
        attemptID: attemptID,
        snapshot: snapshot,
        snapshotJSON: WorktreeAnnotationBatchProjector.jsonData(for: snapshot),
        exactBytes: WorktreeAnnotationBatchProjector.markdownData(
            for: snapshot,
            presentation: outputRepositoryMarkdownPresentation
        )
    )
}

private let outputRepositoryMarkdownPresentation = WorktreeAnnotationMarkdownPresentationContext(
    worktreeLabel: "agent-studio.review-comments",
    comparisonLabel: nil
)

private func outputRepositoryPlacements(
    _ detail: WorktreeAnnotationSessionDetail
) -> [WorktreeAnnotationThreadID: WorktreeAnnotationThreadPlacementProjection] {
    Dictionary(
        uniqueKeysWithValues: detail.threads.map { threadDetail in
            (
                threadDetail.thread.id,
                .init(
                    placement: .exact,
                    currentPath: "Sources/Feature.swift",
                    currentStartLine: 1,
                    currentEndLine: 1,
                    currentSourceIdentity: "source-1"
                )
            )
        }
    )
}

private func testUUID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", suffix))!
}

private func contentSessionRevision<TCanonicalResult: Sendable>(
    _ mutation: WorktreeAnnotationCommittedMutation<TCanonicalResult>
) throws -> Int {
    guard case .content(let sessionChanges) = mutation.change else {
        Issue.record("Expected content classification")
        return -1
    }
    return try #require(sessionChanges.first).semanticRevision
}
