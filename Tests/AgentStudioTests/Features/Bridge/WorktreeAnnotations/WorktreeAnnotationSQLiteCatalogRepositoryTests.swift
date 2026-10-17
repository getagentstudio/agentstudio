import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation SQLite catalog repository")
struct WorktreeAnnotationSQLiteCatalogRepositoryTests {
    @Test("session range read returns complete current children and certifies a later cascade absence")
    func sessionRangeReadCoversCascadeDeletion() throws {
        let fixture = try WorktreeAnnotationCatalogRepositoryFixture()
        let sessionID = WorktreeAnnotationSessionID.generate()
        let threadID = WorktreeAnnotationThreadID.generate()
        let messageID = WorktreeAnnotationMessageID.generate()
        try fixture.insertSession(id: sessionID, worktreeID: "worktree-range")
        try fixture.insertThread(id: threadID, sessionID: sessionID)
        try fixture.insertMessage(id: messageID, threadID: threadID)

        let before = try fixture.repository.fetchCatalogRange(
            worktreeID: "worktree-range",
            range: .session(sessionID)
        )
        #expect(Set(before.keys) == [.session(sessionID), .thread(threadID), .message(messageID)])

        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: "DELETE FROM annotation_session WHERE id = ?",
                arguments: [sessionID.databaseValue]
            )
        }
        let after = try fixture.repository.fetchCatalogRange(
            worktreeID: "worktree-range",
            range: .session(sessionID)
        )
        #expect(after.isEmpty)
    }

    @Test("keyed catalog read returns current rows and omits deleted or foreign keys")
    func keyedCatalogReadUsesOneCurrentTransaction() throws {
        let fixture = try WorktreeAnnotationCatalogRepositoryFixture()
        let sessionID = WorktreeAnnotationSessionID.generate()
        let foreignSessionID = WorktreeAnnotationSessionID.generate()
        let threadID = WorktreeAnnotationThreadID.generate()
        let messageID = WorktreeAnnotationMessageID.generate()
        let missingMessageID = WorktreeAnnotationMessageID.generate()
        try fixture.insertSession(id: sessionID, worktreeID: "worktree-current", semanticRevision: 0, createdAt: 1)
        try fixture.insertSession(
            id: foreignSessionID, worktreeID: "worktree-foreign", semanticRevision: 1, createdAt: 1)
        try fixture.insertThread(id: threadID, sessionID: sessionID, scope: .located, createdOrdinal: 0)
        try fixture.insertMessage(id: messageID, threadID: threadID, ordinal: 0)

        let rows = try fixture.repository.fetchCurrentCatalogEntries(
            worktreeID: "worktree-current",
            keys: [
                .session(sessionID), .session(foreignSessionID), .thread(threadID),
                .message(messageID), .message(missingMessageID),
            ]
        )

        #expect(rows.count == 3)
        let expectedSession = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        #expect(rows[.session(sessionID)] == expectedSession)
        #expect(rows[.session(foreignSessionID)] == nil)
        #expect(rows[.thread(threadID)] != nil)
        #expect(rows[.message(messageID)] != nil)
        #expect(rows[.message(missingMessageID)] == nil)
    }

    @Test("empty worktree returns an empty body-free catalog capture")
    func emptyWorktreeReturnsEmptyCapture() throws {
        let fixture = try WorktreeAnnotationCatalogRepositoryFixture()

        let capture = try fixture.repository.fetchCatalogCapture(worktreeID: "worktree-empty")

        #expect(capture.worktreeID == "worktree-empty")
        #expect(capture.sessions.isEmpty)
        #expect(capture.threads.isEmpty)
        #expect(capture.messages.isEmpty)
    }

    @Test("catalog rows have deterministic session and parent ordinal order")
    func catalogRowsHaveDeterministicOrder() throws {
        let fixture = try WorktreeAnnotationCatalogRepositoryFixture()
        let laterSessionID = WorktreeAnnotationSessionID.generate()
        let earlierSessionID = WorktreeAnnotationSessionID.generate()
        let tiedSessionIDs = [WorktreeAnnotationSessionID.generate(), WorktreeAnnotationSessionID.generate()]
        let firstThreadID = WorktreeAnnotationThreadID.generate()
        let secondThreadID = WorktreeAnnotationThreadID.generate()
        let earlierSessionThreadID = WorktreeAnnotationThreadID.generate()
        let firstMessageID = WorktreeAnnotationMessageID.generate()
        let secondMessageID = WorktreeAnnotationMessageID.generate()

        try fixture.insertSession(
            id: laterSessionID,
            worktreeID: "worktree-order",
            semanticRevision: 4,
            createdAt: 30
        )
        try fixture.insertSession(
            id: earlierSessionID,
            worktreeID: "worktree-order",
            semanticRevision: 2,
            createdAt: 10
        )
        for tiedSessionID in tiedSessionIDs.reversed() {
            try fixture.insertSession(
                id: tiedSessionID,
                worktreeID: "worktree-order",
                semanticRevision: 3,
                createdAt: 20
            )
        }
        try fixture.insertThread(
            id: secondThreadID,
            sessionID: laterSessionID,
            scope: .wholeFile,
            createdOrdinal: 1
        )
        try fixture.insertThread(
            id: firstThreadID,
            sessionID: laterSessionID,
            scope: .located,
            createdOrdinal: 0
        )
        try fixture.insertThread(
            id: earlierSessionThreadID,
            sessionID: earlierSessionID,
            scope: .session,
            createdOrdinal: 0
        )
        try fixture.insertMessage(id: secondMessageID, threadID: firstThreadID, ordinal: 1)
        try fixture.insertMessage(id: firstMessageID, threadID: firstThreadID, ordinal: 0)

        let capture = try fixture.repository.fetchCatalogCapture(worktreeID: "worktree-order")

        let tiedSessionIDsInOrder = tiedSessionIDs.sorted { $0.databaseValue < $1.databaseValue }
        #expect(
            capture.sessions.map(\.sessionID)
                == [earlierSessionID] + tiedSessionIDsInOrder + [laterSessionID]
        )
        #expect(capture.sessions.map(\.semanticRevision) == [2, 3, 3, 4])
        let expectedThreadRows = [
            (earlierSessionID, earlierSessionThreadID, WorktreeAnnotationThreadScope.session, 0),
            (laterSessionID, firstThreadID, WorktreeAnnotationThreadScope.located, 0),
            (laterSessionID, secondThreadID, WorktreeAnnotationThreadScope.wholeFile, 1),
        ].sorted { first, second in
            if first.0.databaseValue != second.0.databaseValue {
                return first.0.databaseValue < second.0.databaseValue
            }
            if first.3 != second.3 {
                return first.3 < second.3
            }
            return first.1.databaseValue < second.1.databaseValue
        }
        #expect(capture.threads.map(\.threadID) == expectedThreadRows.map { $0.1 })
        #expect(capture.threads.map(\.scope) == expectedThreadRows.map { $0.2 })
        #expect(capture.threads.map(\.createdOrdinal) == expectedThreadRows.map { $0.3 })
        #expect(capture.messages.map(\.messageID) == [firstMessageID, secondMessageID])
        #expect(capture.messages.map(\.ordinal) == [0, 1])
    }

    @Test("catalog capture excludes every foreign worktree relationship")
    func catalogCaptureExcludesForeignWorktreeRelationships() throws {
        let fixture = try WorktreeAnnotationCatalogRepositoryFixture()
        let localSessionID = WorktreeAnnotationSessionID.generate()
        let foreignSessionID = WorktreeAnnotationSessionID.generate()
        let localThreadID = WorktreeAnnotationThreadID.generate()
        let foreignThreadID = WorktreeAnnotationThreadID.generate()
        let localMessageID = WorktreeAnnotationMessageID.generate()
        let foreignMessageID = WorktreeAnnotationMessageID.generate()
        try fixture.insertSession(id: localSessionID, worktreeID: "worktree-local")
        try fixture.insertSession(id: foreignSessionID, worktreeID: "worktree-foreign")
        try fixture.insertThread(id: localThreadID, sessionID: localSessionID)
        try fixture.insertThread(id: foreignThreadID, sessionID: foreignSessionID)
        try fixture.insertMessage(id: localMessageID, threadID: localThreadID)
        try fixture.insertMessage(id: foreignMessageID, threadID: foreignThreadID)

        let capture = try fixture.repository.fetchCatalogCapture(worktreeID: "worktree-local")

        #expect(capture.sessions.map(\.sessionID) == [localSessionID])
        #expect(capture.threads.map(\.threadID) == [localThreadID])
        #expect(capture.messages.map(\.messageID) == [localMessageID])
    }

    @Test("malformed rich annotation columns do not affect catalog capture")
    func malformedRichColumnsDoNotAffectCatalogCapture() throws {
        let fixture = try WorktreeAnnotationCatalogRepositoryFixture()
        let sessionID = WorktreeAnnotationSessionID.generate()
        let threadID = WorktreeAnnotationThreadID.generate()
        let messageID = WorktreeAnnotationMessageID.generate()
        try fixture.insertSession(id: sessionID, worktreeID: "worktree-body-free")
        try fixture.insertThread(
            id: threadID,
            sessionID: sessionID,
            originJSON: "not-json"
        )
        try fixture.insertMessage(
            id: messageID,
            threadID: threadID,
            savedBody: nil,
            savedBodyUTF8Bytes: nil,
            savedRevision: nil
        )
        try fixture.insertMalformedDraft(messageID: messageID)
        try fixture.insertMalformedOutput(sessionID: sessionID, messageID: messageID)

        let capture = try fixture.repository.fetchCatalogCapture(worktreeID: "worktree-body-free")

        #expect(capture.sessions.map(\.sessionID) == [sessionID])
        #expect(capture.threads.map(\.threadID) == [threadID])
        #expect(capture.messages.map(\.messageID) == [messageID])
    }

    @Test("invalid catalog identity fails closed")
    func invalidCatalogIdentityFailsClosed() throws {
        let fixture = try WorktreeAnnotationCatalogRepositoryFixture()
        try fixture.insertRawSessionID("not-a-uuid", worktreeID: "worktree-invalid-identity")

        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try fixture.repository.fetchCatalogCapture(worktreeID: "worktree-invalid-identity")
        }
    }

    @Test("invalid catalog scope fails closed")
    func invalidCatalogScopeFailsClosed() throws {
        let fixture = try WorktreeAnnotationCatalogRepositoryFixture()
        let sessionID = WorktreeAnnotationSessionID.generate()
        let threadID = WorktreeAnnotationThreadID.generate()
        try fixture.insertSession(id: sessionID, worktreeID: "worktree-invalid-scope")
        try fixture.insertRawThreadScope(
            "future_scope",
            id: threadID,
            sessionID: sessionID
        )

        #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try fixture.repository.fetchCatalogCapture(worktreeID: "worktree-invalid-scope")
        }
    }
}

private struct WorktreeAnnotationCatalogRepositoryFixture {
    let databaseQueue: DatabaseQueue
    let repository: WorktreeAnnotationSQLiteRepository

    init() throws {
        databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        repository = WorktreeAnnotationSQLiteRepository(databaseWriter: databaseQueue)
    }

    func insertSession(
        id: WorktreeAnnotationSessionID,
        worktreeID: String,
        semanticRevision: Int = 1,
        createdAt: Double = 1
    ) throws {
        try insertRawSessionID(
            id.databaseValue,
            worktreeID: worktreeID,
            semanticRevision: semanticRevision,
            createdAt: createdAt
        )
    }

    func insertRawSessionID(
        _ id: String,
        worktreeID: String,
        semanticRevision: Int = 1,
        createdAt: Double = 1
    ) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO annotation_session(
                        id, repository_id, worktree_id, lifecycle, source_relationship,
                        accepted_source_fingerprint_json, semantic_revision,
                        created_at, updated_at, completed_at
                    ) VALUES (?, 'repository', ?, 'living', 'applicable', '{}', ?, ?, ?, NULL)
                    """,
                arguments: [id, worktreeID, semanticRevision, createdAt, createdAt]
            )
        }
    }

    func insertThread(
        id: WorktreeAnnotationThreadID,
        sessionID: WorktreeAnnotationSessionID,
        scope: WorktreeAnnotationThreadScope = .located,
        createdOrdinal: Int = 0,
        originJSON: String = "{}"
    ) throws {
        try insertRawThreadScope(
            scope.rawValue,
            id: id,
            sessionID: sessionID,
            createdOrdinal: createdOrdinal,
            originJSON: originJSON
        )
    }

    func insertRawThreadScope(
        _ scope: String,
        id: WorktreeAnnotationThreadID,
        sessionID: WorktreeAnnotationSessionID,
        createdOrdinal: Int = 0,
        originJSON: String = "{}"
    ) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO annotation_thread(
                        id, session_id, scope, resolution, origin_json, created_ordinal,
                        semantic_revision, created_at, updated_at, resolved_at
                    ) VALUES (?, ?, ?, 'open', ?, ?, 0, 1, 1, NULL)
                    """,
                arguments: [
                    id.databaseValue,
                    sessionID.databaseValue,
                    scope,
                    originJSON,
                    createdOrdinal,
                ]
            )
        }
    }

    func insertMessage(
        id: WorktreeAnnotationMessageID,
        threadID: WorktreeAnnotationThreadID,
        ordinal: Int = 0,
        savedBody: String? = "saved",
        savedBodyUTF8Bytes: Int? = 5,
        savedRevision: Int? = 1
    ) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO annotation_message(
                        id, thread_id, ordinal, author_kind, saved_body, saved_body_utf8_bytes,
                        saved_revision, status, semantic_revision, created_at, updated_at
                    ) VALUES (?, ?, ?, 'human', ?, ?, ?, 'editable', 0, 1, 1)
                    """,
                arguments: [
                    id.databaseValue,
                    threadID.databaseValue,
                    ordinal,
                    savedBody,
                    savedBodyUTF8Bytes,
                    savedRevision,
                ]
            )
        }
    }

    func insertMalformedDraft(messageID: WorktreeAnnotationMessageID) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO annotation_message_draft(
                        message_id, active_edit_token, body, body_utf8_bytes,
                        draft_revision, updated_at
                    ) VALUES (?, 'sentinel-token', '', 0, 0, 1)
                    """,
                arguments: [messageID.databaseValue]
            )
        }
    }

    func insertMalformedOutput(
        sessionID: WorktreeAnnotationSessionID,
        messageID: WorktreeAnnotationMessageID
    ) throws {
        let attemptID = WorktreeAnnotationOutputAttemptID.generate()
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO annotation_output_attempt(
                        id, session_id, output_kind, state, format_version, content_type,
                        snapshot_json, exact_bytes, destination_path, repeated_from_attempt_id,
                        effect_error, cleanup_error, created_at, updated_at
                    ) VALUES (?, ?, 'clipboard_markdown', 'succeeded', 1, 'text/markdown',
                        'not-json', X'FF', '/sentinel/path', NULL, NULL, NULL, 1, 1)
                    """,
                arguments: [attemptID.databaseValue, sessionID.databaseValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO annotation_output_attempt_message(
                        attempt_id, message_id, expected_saved_revision, batch_ordinal
                    ) VALUES (?, ?, 1, 0)
                    """,
                arguments: [attemptID.databaseValue, messageID.databaseValue]
            )
        }
    }
}
