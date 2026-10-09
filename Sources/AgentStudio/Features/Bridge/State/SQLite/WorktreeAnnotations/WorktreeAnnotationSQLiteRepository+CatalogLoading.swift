import GRDB

extension WorktreeAnnotationSQLiteRepository {
    /// A complete range read is one SQLite snapshot. Empty means certified
    /// absence only after this call succeeds; callers keep their old rows on error.
    func fetchCatalogRange(
        worktreeID: String,
        range: WorktreeAnnotationCatalogRange
    ) throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] {
        switch range {
        case .worktree:
            let capture = try fetchCatalogCapture(worktreeID: worktreeID)
            var entries: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] = [:]
            for session in capture.sessions {
                entries[.session(session.sessionID)] = .session(
                    try .init(sessionID: session.sessionID, semanticRevision: session.semanticRevision)
                )
            }
            for thread in capture.threads {
                entries[.thread(thread.threadID)] = .thread(
                    try .init(
                        threadID: thread.threadID,
                        sessionID: thread.sessionID,
                        scope: thread.scope,
                        createdOrdinal: thread.createdOrdinal
                    )
                )
            }
            for message in capture.messages {
                entries[.message(message.messageID)] = .message(
                    try .init(
                        messageID: message.messageID,
                        threadID: message.threadID,
                        ordinal: message.ordinal
                    )
                )
            }
            return entries
        case .session(let sessionID):
            return try databaseWriter.read { database in
                var entries: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] = [:]
                let sessionRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, semantic_revision FROM annotation_session
                        WHERE id = ? AND worktree_id = ?
                        """,
                    arguments: [sessionID.databaseValue, worktreeID]
                )
                for row in sessionRows {
                    let id: WorktreeAnnotationSessionID = try decodeIdentity(row["id"] as String)
                    entries[.session(id)] = .session(
                        try .init(sessionID: id, semanticRevision: row["semantic_revision"])
                    )
                }
                let threadRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT thread.id, thread.session_id, thread.scope, thread.created_ordinal
                        FROM annotation_thread AS thread
                        JOIN annotation_session AS session ON session.id = thread.session_id
                        WHERE session.id = ? AND session.worktree_id = ?
                        """,
                    arguments: [sessionID.databaseValue, worktreeID]
                )
                for row in threadRows {
                    let id: WorktreeAnnotationThreadID = try decodeIdentity(row["id"] as String)
                    entries[.thread(id)] = .thread(
                        try .init(
                            threadID: id,
                            sessionID: decodeIdentity(row["session_id"] as String),
                            scope: decodeRawValue(row["scope"] as String),
                            createdOrdinal: row["created_ordinal"]
                        )
                    )
                }
                let messageRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT message.id, message.thread_id, message.ordinal
                        FROM annotation_message AS message
                        JOIN annotation_thread AS thread ON thread.id = message.thread_id
                        JOIN annotation_session AS session ON session.id = thread.session_id
                        WHERE session.id = ? AND session.worktree_id = ?
                        """,
                    arguments: [sessionID.databaseValue, worktreeID]
                )
                for row in messageRows {
                    let id: WorktreeAnnotationMessageID = try decodeIdentity(row["id"] as String)
                    entries[.message(id)] = .message(
                        try .init(
                            messageID: id,
                            threadID: decodeIdentity(row["thread_id"] as String),
                            ordinal: row["ordinal"]
                        )
                    )
                }
                return entries
            }
        }
    }

    /// Reads only requested catalog identities in one SQLite read transaction.
    /// Missing rows stay absent so N10 can emit their deletion tombstones.
    func fetchCurrentCatalogEntries(
        worktreeID: String,
        keys: Set<WorktreeAnnotationCatalogKey>
    ) throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] {
        try databaseWriter.read { database in
            var entries: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] = [:]
            for key in keys {
                switch key {
                case .session(let id):
                    guard
                        let row = try Row.fetchOne(
                            database,
                            sql: """
                                SELECT id, semantic_revision FROM annotation_session
                                WHERE id = ? AND worktree_id = ?
                                """,
                            arguments: [id.databaseValue, worktreeID]
                        )
                    else { continue }
                    entries[key] = .session(
                        try .init(
                            sessionID: decodeIdentity(row["id"] as String),
                            semanticRevision: row["semantic_revision"]
                        )
                    )
                case .thread(let id):
                    guard
                        let row = try Row.fetchOne(
                            database,
                            sql: """
                                SELECT thread.id, thread.session_id, thread.scope, thread.created_ordinal
                                FROM annotation_thread AS thread
                                JOIN annotation_session AS session ON session.id = thread.session_id
                                WHERE thread.id = ? AND session.worktree_id = ?
                                """,
                            arguments: [id.databaseValue, worktreeID]
                        )
                    else { continue }
                    entries[key] = .thread(
                        try .init(
                            threadID: decodeIdentity(row["id"] as String),
                            sessionID: decodeIdentity(row["session_id"] as String),
                            scope: decodeRawValue(row["scope"] as String),
                            createdOrdinal: row["created_ordinal"]
                        )
                    )
                case .message(let id):
                    guard
                        let row = try Row.fetchOne(
                            database,
                            sql: """
                                SELECT message.id, message.thread_id, message.ordinal
                                FROM annotation_message AS message
                                JOIN annotation_thread AS thread ON thread.id = message.thread_id
                                JOIN annotation_session AS session ON session.id = thread.session_id
                                WHERE message.id = ? AND session.worktree_id = ?
                                """,
                            arguments: [id.databaseValue, worktreeID]
                        )
                    else { continue }
                    entries[key] = .message(
                        try .init(
                            messageID: decodeIdentity(row["id"] as String),
                            threadID: decodeIdentity(row["thread_id"] as String),
                            ordinal: row["ordinal"]
                        )
                    )
                }
            }
            return entries
        }
    }

    func fetchCatalogCapture(worktreeID: String) throws -> WorktreeAnnotationCatalogCapture {
        try databaseWriter.read { database in
            let sessions = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, semantic_revision
                    FROM annotation_session
                    WHERE worktree_id = ?
                    ORDER BY created_at ASC, id ASC
                    """,
                arguments: [worktreeID]
            ).map { row in
                WorktreeAnnotationCatalogSessionRow(
                    sessionID: try decodeIdentity(row["id"] as String),
                    semanticRevision: row["semantic_revision"]
                )
            }
            let threads = try Row.fetchAll(
                database,
                sql: """
                    SELECT thread.id, thread.session_id, thread.scope, thread.created_ordinal
                    FROM annotation_thread AS thread
                    JOIN annotation_session AS session ON session.id = thread.session_id
                    WHERE session.worktree_id = ?
                    ORDER BY thread.session_id ASC, thread.created_ordinal ASC, thread.id ASC
                    """,
                arguments: [worktreeID]
            ).map { row in
                WorktreeAnnotationCatalogThreadRow(
                    threadID: try decodeIdentity(row["id"] as String),
                    sessionID: try decodeIdentity(row["session_id"] as String),
                    scope: try decodeRawValue(row["scope"] as String),
                    createdOrdinal: row["created_ordinal"]
                )
            }
            let messages = try Row.fetchAll(
                database,
                sql: """
                    SELECT message.id, message.thread_id, message.ordinal
                    FROM annotation_message AS message
                    JOIN annotation_thread AS thread ON thread.id = message.thread_id
                    JOIN annotation_session AS session ON session.id = thread.session_id
                    WHERE session.worktree_id = ?
                    ORDER BY message.thread_id ASC, message.ordinal ASC, message.id ASC
                    """,
                arguments: [worktreeID]
            ).map { row in
                WorktreeAnnotationCatalogMessageRow(
                    messageID: try decodeIdentity(row["id"] as String),
                    threadID: try decodeIdentity(row["thread_id"] as String),
                    ordinal: row["ordinal"]
                )
            }
            return WorktreeAnnotationCatalogCapture(
                worktreeID: worktreeID,
                sessions: sessions,
                threads: threads,
                messages: messages
            )
        }
    }
}
