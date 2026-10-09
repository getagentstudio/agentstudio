import Foundation
import GRDB

extension WorktreeAnnotationSQLiteRepository {
    struct OutputMessageSelection: Equatable, Sendable {
        let messageID: WorktreeAnnotationMessageID
        let expectedSavedRevision: Int
    }

    struct PrepareOutputProps: Sendable {
        let attemptID: WorktreeAnnotationOutputAttemptID
        let sessionID: WorktreeAnnotationSessionID
        let outputKind: WorktreeAnnotationOutputKind
        let formatVersion: Int
        let contentType: String
        let canonicalSnapshot: WorktreeAnnotationBatchSnapshotV2
        let exactBytes: Data
        let markdownPresentation: WorktreeAnnotationMarkdownPresentationContext?
        let destinationPath: String?
        let repeatedFromAttemptID: WorktreeAnnotationOutputAttemptID?
        let selectedMessages: [OutputMessageSelection]
        let expectedSessionRevision: Int?
        let expectedProjectionRevision: Int?
        let now: Date

        init(
            attemptID: WorktreeAnnotationOutputAttemptID,
            sessionID: WorktreeAnnotationSessionID,
            outputKind: WorktreeAnnotationOutputKind,
            formatVersion: Int,
            contentType: String,
            canonicalSnapshot: WorktreeAnnotationBatchSnapshotV2,
            exactBytes: Data,
            markdownPresentation: WorktreeAnnotationMarkdownPresentationContext?,
            destinationPath: String?,
            repeatedFromAttemptID: WorktreeAnnotationOutputAttemptID?,
            selectedMessages: [OutputMessageSelection],
            expectedSessionRevision: Int? = nil,
            expectedProjectionRevision: Int? = nil,
            now: Date
        ) {
            self.attemptID = attemptID
            self.sessionID = sessionID
            self.outputKind = outputKind
            self.formatVersion = formatVersion
            self.contentType = contentType
            self.canonicalSnapshot = canonicalSnapshot
            self.exactBytes = exactBytes
            self.markdownPresentation = markdownPresentation
            self.destinationPath = destinationPath
            self.repeatedFromAttemptID = repeatedFromAttemptID
            self.selectedMessages = selectedMessages
            self.expectedSessionRevision = expectedSessionRevision
            self.expectedProjectionRevision = expectedProjectionRevision
            self.now = now
        }
    }

    struct OutputAttemptMembership: Equatable, Sendable {
        let messageID: WorktreeAnnotationMessageID
        let expectedSavedRevision: Int
        let batchOrdinal: Int
    }

    struct PreparedOutput: Equatable, Sendable {
        let attempt: WorktreeAnnotationOutputAttempt
        let canonicalSnapshot: WorktreeAnnotationStoredBatchDocument
        let memberships: [OutputAttemptMembership]
        let event: WorktreeAnnotationOutputEvent?

        var selectedSavedRevisions: [Int] {
            memberships.map(\.expectedSavedRevision)
        }
    }

    func prepareOutput(_ props: PrepareOutputProps) throws
        -> WorktreeAnnotationCommittedMutation<PreparedOutput>
    {
        let snapshotJSONString = try validateOutputPreparation(props)
        return try databaseWriter.write { database in
            let preparedOutput = try insertPreparedOutput(
                database,
                props: props,
                snapshotJSONString: snapshotJSONString
            )
            try advanceSession(database, sessionID: props.sessionID, now: props.now)
            return try outputContentMutation(
                database,
                canonicalResult: preparedOutput,
                sessionID: props.sessionID
            )
        }
    }

    private func validateOutputPreparation(_ props: PrepareOutputProps) throws -> String {
        guard !props.selectedMessages.isEmpty else { throw WorktreeAnnotationRepositoryError.emptySelection }
        guard Set(props.selectedMessages.map(\.messageID)).count == props.selectedMessages.count else {
            throw WorktreeAnnotationRepositoryError.duplicateSelection
        }
        guard props.repeatedFromAttemptID == nil else {
            throw WorktreeAnnotationRepositoryError.invalidState
        }
        let expectedContentType =
            props.outputKind == .clipboardMarkdown
            ? "text/markdown; charset=utf-8"
            : "application/json; charset=utf-8"
        guard props.formatVersion == WorktreeAnnotationBatchSnapshotV2.currentFormatVersion,
            props.contentType == expectedContentType,
            props.canonicalSnapshot.createdAt == WorktreeAnnotationBatchProjector.createdAtString(props.now)
        else {
            throw WorktreeAnnotationRepositoryError.invalidState
        }
        switch props.outputKind {
        case .clipboardMarkdown:
            guard props.destinationPath == nil, let markdownPresentation = props.markdownPresentation else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
            guard
                props.exactBytes
                    == WorktreeAnnotationBatchProjector.markdownData(
                        for: props.canonicalSnapshot,
                        presentation: markdownPresentation
                    )
            else { throw WorktreeAnnotationRepositoryError.invalidState }
        case .jsonFile:
            guard props.destinationPath?.isEmpty == false, props.markdownPresentation == nil else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
        }
        try WorktreeAnnotationBatchProjector.validate(props.canonicalSnapshot)
        guard props.canonicalSnapshot.batchID == props.attemptID,
            props.canonicalSnapshot.session.sessionID == props.sessionID,
            props.canonicalSnapshot.formatVersion == props.formatVersion,
            props.canonicalSnapshot.entries.map(\.messageID) == props.selectedMessages.map(\.messageID),
            props.canonicalSnapshot.entries.map(\.savedRevision)
                == props.selectedMessages.map(\.expectedSavedRevision)
        else {
            throw WorktreeAnnotationRepositoryError.invalidState
        }
        let snapshotJSON = try WorktreeAnnotationBatchProjector.jsonData(for: props.canonicalSnapshot)
        guard props.outputKind != .jsonFile || props.exactBytes == snapshotJSON else {
            throw WorktreeAnnotationRepositoryError.invalidState
        }

        return try Self.requireUTF8String(snapshotJSON)
    }

    private func insertPreparedOutput(
        _ database: Database,
        props: PrepareOutputProps,
        snapshotJSONString: String
    ) throws -> PreparedOutput {
        guard
            let currentSessionRevision = try Int.fetchOne(
                database,
                sql: "SELECT semantic_revision FROM annotation_session WHERE id = ?",
                arguments: [props.sessionID.databaseValue]
            )
        else {
            throw WorktreeAnnotationRepositoryError.notFound
        }
        if let expectedSessionRevision = props.expectedSessionRevision,
            currentSessionRevision != expectedSessionRevision
        {
            throw WorktreeAnnotationRepositoryError.conflict(
                currentRevision: currentSessionRevision
            )
        }
        try ensureNoPreparedOutputAttempt(database, sessionID: props.sessionID)
        try validateCanonicalSnapshotAgainstDurableState(database, props: props)
        for selection in props.selectedMessages {
            guard
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM annotation_message message
                        JOIN annotation_thread thread ON thread.id = message.thread_id
                        WHERE message.id = ? AND message.saved_revision = ?
                          AND message.saved_body IS NOT NULL
                          AND NOT EXISTS (
                              SELECT 1 FROM annotation_message_draft draft
                              WHERE draft.message_id = message.id
                          )
                          AND thread.session_id = ?
                        """,
                    arguments: [
                        selection.messageID.databaseValue,
                        selection.expectedSavedRevision,
                        props.sessionID.databaseValue,
                    ]
                ) == 1
            else {
                throw WorktreeAnnotationRepositoryError.notFound
            }
        }

        if let repeatedFromAttemptID = props.repeatedFromAttemptID {
            guard
                let priorBytes = try Data.fetchOne(
                    database,
                    sql: "SELECT exact_bytes FROM annotation_output_attempt WHERE id = ?",
                    arguments: [repeatedFromAttemptID.databaseValue]
                ), priorBytes == props.exactBytes
            else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
        }

        try database.execute(
            sql: """
                INSERT INTO annotation_output_attempt(
                    id, session_id, output_kind, state, format_version, content_type,
                    snapshot_json, exact_bytes, destination_path, repeated_from_attempt_id,
                    effect_error, cleanup_error, created_at, updated_at
                ) VALUES (?, ?, ?, 'prepared', ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
                """,
            arguments: [
                props.attemptID.databaseValue,
                props.sessionID.databaseValue,
                props.outputKind.rawValue,
                props.formatVersion,
                props.contentType,
                snapshotJSONString,
                props.exactBytes,
                props.destinationPath,
                props.repeatedFromAttemptID?.databaseValue,
                props.now.timeIntervalSince1970,
                props.now.timeIntervalSince1970,
            ]
        )
        for (ordinal, selection) in props.selectedMessages.enumerated() {
            try database.execute(
                sql: """
                    INSERT INTO annotation_output_attempt_message(
                        attempt_id, message_id, expected_saved_revision, batch_ordinal
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    props.attemptID.databaseValue,
                    selection.messageID.databaseValue,
                    selection.expectedSavedRevision,
                    ordinal,
                ]
            )
        }
        return try loadPreparedOutput(database, attemptID: props.attemptID)
    }

    func repeatOutputAttempt(
        sourceAttemptID: WorktreeAnnotationOutputAttemptID,
        repeatedAttemptID: WorktreeAnnotationOutputAttemptID,
        destinationPath: String?,
        now: Date
    ) throws -> WorktreeAnnotationCommittedMutation<PreparedOutput> {
        try databaseWriter.write { database in
            let source = try loadPreparedOutput(database, attemptID: sourceAttemptID)
            guard source.attempt.state == .unknown else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
            try ensureNoPreparedOutputAttempt(
                database,
                sessionID: source.attempt.sessionID
            )
            switch source.attempt.outputKind {
            case .clipboardMarkdown:
                guard destinationPath == nil else {
                    throw WorktreeAnnotationRepositoryError.invalidState
                }
            case .jsonFile:
                guard destinationPath?.isEmpty == false else {
                    throw WorktreeAnnotationRepositoryError.invalidState
                }
            }
            let snapshotJSON = try source.canonicalSnapshot.jsonData()
            let snapshotJSONString = try Self.requireUTF8String(snapshotJSON)
            try database.execute(
                sql: """
                    INSERT INTO annotation_output_attempt(
                        id, session_id, output_kind, state, format_version, content_type,
                        snapshot_json, exact_bytes, destination_path, repeated_from_attempt_id,
                        effect_error, cleanup_error, created_at, updated_at
                    ) VALUES (?, ?, ?, 'prepared', ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
                    """,
                arguments: [
                    repeatedAttemptID.databaseValue,
                    source.attempt.sessionID.databaseValue,
                    source.attempt.outputKind.rawValue,
                    source.attempt.formatVersion,
                    source.attempt.contentType,
                    snapshotJSONString,
                    source.attempt.exactBytes,
                    destinationPath,
                    sourceAttemptID.databaseValue,
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                ]
            )
            for membership in source.memberships {
                try database.execute(
                    sql: """
                        INSERT INTO annotation_output_attempt_message(
                            attempt_id, message_id, expected_saved_revision, batch_ordinal
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        repeatedAttemptID.databaseValue,
                        membership.messageID.databaseValue,
                        membership.expectedSavedRevision,
                        membership.batchOrdinal,
                    ]
                )
            }
            try advanceSession(database, sessionID: source.attempt.sessionID, now: now)
            return try outputContentMutation(
                database,
                canonicalResult: loadPreparedOutput(database, attemptID: repeatedAttemptID),
                sessionID: source.attempt.sessionID
            )
        }
    }

    func inspectOutputAttempt(attemptID: WorktreeAnnotationOutputAttemptID) throws -> PreparedOutput {
        try databaseWriter.read { database in
            try loadPreparedOutput(database, attemptID: attemptID)
        }
    }

    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        effectError: String? = nil,
        now: Date
    ) throws -> WorktreeAnnotationCommittedMutation<PreparedOutput> {
        try databaseWriter.write { database in
            let current = try loadPreparedOutput(database, attemptID: attemptID)
            if current.attempt.state == .cancelled {
                return WorktreeAnnotationCommittedMutation(
                    canonicalResult: current,
                    change: .noChange
                )
            }
            guard current.attempt.state == .prepared else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
            try database.execute(
                sql: """
                    UPDATE annotation_output_attempt
                    SET state = 'cancelled', effect_error = ?, cleanup_error = NULL, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [effectError, now.timeIntervalSince1970, attemptID.databaseValue]
            )
            try advanceSession(database, sessionID: current.attempt.sessionID, now: now)
            return try outputContentMutation(
                database,
                canonicalResult: loadPreparedOutput(database, attemptID: attemptID),
                sessionID: current.attempt.sessionID
            )
        }
    }

    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String? = nil,
        now: Date
    ) throws -> WorktreeAnnotationCommittedMutation<PreparedOutput> {
        try databaseWriter.write { database in
            let current = try loadPreparedOutput(database, attemptID: attemptID)
            let expectedEventKind: WorktreeAnnotationOutputEventKind =
                current.attempt.outputKind == .clipboardMarkdown ? .copied : .exported
            guard eventKind == expectedEventKind else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
            if let event = current.event {
                guard event.eventKind == eventKind else {
                    throw WorktreeAnnotationRepositoryError.invalidState
                }
                return WorktreeAnnotationCommittedMutation(
                    canonicalResult: current,
                    change: .noChange
                )
            }
            guard current.attempt.state == .prepared || current.attempt.state == .finalizationFailed else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
            let recordedDestination = destinationPath ?? current.attempt.destinationPath
            switch current.attempt.outputKind {
            case .clipboardMarkdown:
                guard recordedDestination == nil else { throw WorktreeAnnotationRepositoryError.invalidState }
            case .jsonFile:
                guard recordedDestination?.isEmpty == false else {
                    throw WorktreeAnnotationRepositoryError.invalidState
                }
            }
            let eventID = WorktreeAnnotationOutputEventID.generate()
            try database.execute(
                sql: """
                    INSERT INTO annotation_output_event(id, attempt_id, event_kind, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    eventID.databaseValue,
                    attemptID.databaseValue,
                    eventKind.rawValue,
                    now.timeIntervalSince1970,
                ]
            )
            try database.execute(
                sql: """
                    UPDATE annotation_output_attempt
                    SET state = 'succeeded', destination_path = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [recordedDestination, now.timeIntervalSince1970, attemptID.databaseValue]
            )
            _ = try markOutputMessagesHandled(
                database,
                attemptID: attemptID,
                now: now
            )
            try advanceSession(database, sessionID: current.attempt.sessionID, now: now)
            return try outputContentMutation(
                database,
                canonicalResult: loadPreparedOutput(database, attemptID: attemptID),
                sessionID: current.attempt.sessionID
            )
        }
    }

    func markPreparedOutputAttemptsUnknown(now: Date) throws
        -> WorktreeAnnotationCommittedMutation<Int>
    {
        try databaseWriter.write { database in
            let preparedAttemptIDs = try String.fetchAll(
                database,
                sql: "SELECT id FROM annotation_output_attempt WHERE state = 'prepared' ORDER BY id ASC"
            )
            try database.execute(
                sql: "UPDATE annotation_output_attempt SET state = 'unknown', updated_at = ? WHERE state = 'prepared'",
                arguments: [now.timeIntervalSince1970]
            )
            let changedCount = database.changesCount
            var changedSessionIDs: Set<WorktreeAnnotationSessionID> = []
            for attemptID in preparedAttemptIDs {
                let typedAttemptID: WorktreeAnnotationOutputAttemptID = try decodeIdentity(attemptID)
                let sessionID = try requireOutputAttemptSessionID(database, attemptID: typedAttemptID)
                _ = try lockOutputMessages(
                    database,
                    attemptID: typedAttemptID,
                    now: now
                )
                changedSessionIDs.insert(sessionID)
            }
            guard changedCount > 0 else {
                return WorktreeAnnotationCommittedMutation(
                    canonicalResult: 0,
                    change: .noChange
                )
            }
            let orderedSessionIDs = changedSessionIDs.sorted {
                $0.rawValue.uuidString < $1.rawValue.uuidString
            }
            for sessionID in orderedSessionIDs {
                try advanceSession(database, sessionID: sessionID, now: now)
            }
            let sessionChanges = try orderedSessionIDs.map {
                try loadCommittedSessionChange(database, sessionID: $0)
            }
            return WorktreeAnnotationCommittedMutation(
                canonicalResult: changedCount,
                change: .content(sessionChanges: sessionChanges)
            )
        }
    }

    func markOutputAttemptFinalizationFailed(
        attemptID: WorktreeAnnotationOutputAttemptID,
        cleanupError: String,
        destinationPath: String? = nil,
        now: Date
    ) throws -> WorktreeAnnotationCommittedMutation<PreparedOutput> {
        try databaseWriter.write { database in
            let current = try loadPreparedOutput(database, attemptID: attemptID)
            guard current.attempt.state == .prepared || current.attempt.state == .finalizationFailed else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
            let recordedDestination = destinationPath ?? current.attempt.destinationPath
            try database.execute(
                sql: """
                    UPDATE annotation_output_attempt
                    SET state = 'finalization_failed', destination_path = ?, cleanup_error = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [recordedDestination, cleanupError, now.timeIntervalSince1970, attemptID.databaseValue]
            )
            _ = try lockOutputMessages(
                database,
                attemptID: attemptID,
                now: now
            )
            try advanceSession(database, sessionID: current.attempt.sessionID, now: now)
            return try outputContentMutation(
                database,
                canonicalResult: loadPreparedOutput(database, attemptID: attemptID),
                sessionID: current.attempt.sessionID
            )
        }
    }

    func fetchOutputHistory(
        sessionID: WorktreeAnnotationSessionID,
        limit: Int
    ) throws -> [WorktreeAnnotationOutputHistorySummary] {
        guard limit > 0 else { throw WorktreeAnnotationRepositoryError.invalidState }
        return try databaseWriter.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT attempt.id, attempt.output_kind, attempt.state,
                           attempt.repeated_from_attempt_id, attempt.created_at, attempt.updated_at,
                           COUNT(membership.message_id) AS message_count,
                           MAX(
                               CASE
                                   WHEN attempt.state = 'succeeded'
                                    AND message.handled = 1
                                    AND message.saved_revision = membership.expected_saved_revision
                                   THEN 1 ELSE 0
                               END
                           ) AS can_mark_not_handled
                    FROM annotation_output_attempt attempt
                    JOIN annotation_output_attempt_message membership ON membership.attempt_id = attempt.id
                    JOIN annotation_message message ON message.id = membership.message_id
                    WHERE attempt.session_id = ? AND attempt.state != 'cancelled'
                    GROUP BY attempt.id
                    ORDER BY attempt.created_at DESC, attempt.id DESC
                    LIMIT ?
                    """,
                arguments: [sessionID.databaseValue, limit]
            ).map { row in
                try WorktreeAnnotationOutputHistorySummary(
                    attemptID: decodeIdentity(row["id"] as String),
                    sessionID: sessionID,
                    outputKind: decodeRawValue(row["output_kind"] as String),
                    state: decodeRawValue(row["state"] as String),
                    messageCount: row["message_count"],
                    repeatedFromAttemptID: try (row["repeated_from_attempt_id"] as String?).map(decodeIdentity),
                    canMarkNotHandled: row["can_mark_not_handled"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }
    }

    func clearOutputHandled(
        attemptID: WorktreeAnnotationOutputAttemptID,
        expectedSessionRevision: Int,
        now: Date
    ) throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail> {
        try databaseWriter.write { database in
            guard
                let attempt = try Row.fetchOne(
                    database,
                    sql: "SELECT session_id, state FROM annotation_output_attempt WHERE id = ?",
                    arguments: [attemptID.databaseValue]
                )
            else {
                throw WorktreeAnnotationRepositoryError.notFound
            }
            let sessionID: WorktreeAnnotationSessionID = try decodeIdentity(
                attempt["session_id"] as String
            )
            guard
                (attempt["state"] as String) == WorktreeAnnotationOutputAttemptState.succeeded.rawValue
            else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
            try validateSessionRevision(
                database,
                sessionID: sessionID,
                expectedRevision: expectedSessionRevision
            )
            try database.execute(
                sql: """
                    UPDATE annotation_message AS message
                    SET handled = 0, semantic_revision = semantic_revision + 1, updated_at = ?
                    WHERE author_kind = 'human' AND handled = 1 AND EXISTS (
                        SELECT 1
                        FROM annotation_output_attempt_message membership
                        WHERE membership.attempt_id = ?
                          AND membership.message_id = message.id
                          AND membership.expected_saved_revision = message.saved_revision
                    )
                    """,
                arguments: [now.timeIntervalSince1970, attemptID.databaseValue]
            )
            let changed = database.changesCount > 0
            if changed {
                try advanceSession(database, sessionID: sessionID, now: now)
            }
            let detail = try loadSessionDetail(database, sessionID: sessionID)
            return changed
                ? .content(detail)
                : WorktreeAnnotationCommittedMutation(
                    canonicalResult: detail,
                    change: .noChange
                )
        }
    }

    func loadPreparedOutput(
        _ database: Database,
        attemptID: WorktreeAnnotationOutputAttemptID
    ) throws -> PreparedOutput {
        guard
            let attemptRow = try Row.fetchOne(
                database,
                sql: "SELECT * FROM annotation_output_attempt WHERE id = ?",
                arguments: [attemptID.databaseValue]
            )
        else {
            throw WorktreeAnnotationRepositoryError.notFound
        }
        let membershipRows = try Row.fetchAll(
            database,
            sql: """
                SELECT message_id, expected_saved_revision, batch_ordinal
                FROM annotation_output_attempt_message
                WHERE attempt_id = ?
                ORDER BY batch_ordinal ASC
                """,
            arguments: [attemptID.databaseValue]
        )
        let eventRow = try Row.fetchOne(
            database,
            sql: "SELECT * FROM annotation_output_event WHERE attempt_id = ?",
            arguments: [attemptID.databaseValue]
        )
        let attempt = try decodeOutputAttempt(attemptRow)
        let snapshotJSON: String = attemptRow["snapshot_json"]
        let snapshot = try WorktreeAnnotationStoredBatchDocument.decodeJSON(
            Data(snapshotJSON.utf8),
            persistedFormatVersion: attempt.formatVersion
        )
        let memberships = try membershipRows.map { row in
            try OutputAttemptMembership(
                messageID: decodeIdentity(row["message_id"] as String),
                expectedSavedRevision: row["expected_saved_revision"],
                batchOrdinal: row["batch_ordinal"]
            )
        }
        guard snapshot.sessionID == attempt.sessionID,
            snapshot.formatVersion == attempt.formatVersion,
            snapshot.messageIDs == memberships.map(\.messageID),
            snapshot.savedRevisions == memberships.map(\.expectedSavedRevision),
            snapshot.batchOrdinals == memberships.map(\.batchOrdinal)
        else {
            throw WorktreeAnnotationRepositoryError.invalidState
        }
        return PreparedOutput(
            attempt: attempt,
            canonicalSnapshot: snapshot,
            memberships: memberships,
            event: try eventRow.map(decodeOutputEvent)
        )
    }

    func decodeOutputAttempt(_ row: Row) throws -> WorktreeAnnotationOutputAttempt {
        try WorktreeAnnotationOutputAttempt(
            id: decodeIdentity(row["id"] as String),
            sessionID: decodeIdentity(row["session_id"] as String),
            outputKind: decodeRawValue(row["output_kind"] as String),
            state: decodeRawValue(row["state"] as String),
            formatVersion: row["format_version"],
            contentType: row["content_type"],
            exactBytes: row["exact_bytes"],
            destinationPath: row["destination_path"],
            repeatedFromAttemptID: try (row["repeated_from_attempt_id"] as String?).map(decodeIdentity),
            effectError: row["effect_error"],
            cleanupError: row["cleanup_error"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    func decodeOutputEvent(_ row: Row) throws -> WorktreeAnnotationOutputEvent {
        try WorktreeAnnotationOutputEvent(
            id: decodeIdentity(row["id"] as String),
            attemptID: decodeIdentity(row["attempt_id"] as String),
            eventKind: decodeRawValue(row["event_kind"] as String),
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }

    private func ensureNoPreparedOutputAttempt(
        _ database: Database,
        sessionID: WorktreeAnnotationSessionID
    ) throws {
        let preparedAttemptCount =
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM annotation_output_attempt
                    WHERE session_id = ? AND state = 'prepared'
                    """,
                arguments: [sessionID.databaseValue]
            ) ?? 0
        guard preparedAttemptCount == 0 else {
            throw WorktreeAnnotationRepositoryError.invalidState
        }
    }

    private func validateCanonicalSnapshotAgainstDurableState(
        _ database: Database,
        props: PrepareOutputProps
    ) throws {
        let detail = try loadSessionDetail(database, sessionID: props.sessionID)
        let snapshot = props.canonicalSnapshot
        guard snapshot.session.sessionID == detail.session.id,
            snapshot.session.repositoryID == detail.session.repositoryID,
            snapshot.session.worktreeID == detail.session.worktreeID,
            snapshot.session.lifecycle == detail.session.lifecycle,
            snapshot.session.sourceRelationship == detail.session.sourceRelationship
        else {
            throw WorktreeAnnotationRepositoryError.invalidState
        }

        for entry in snapshot.entries {
            guard let threadDetail = detail.threads.first(where: { $0.thread.id == entry.threadID }),
                let message = threadDetail.messages.first(where: { $0.id == entry.messageID }),
                let savedBody = message.savedBody,
                let savedRevision = message.savedRevision,
                entry.messageOrdinal == message.ordinal,
                entry.message.author.kind.domainValue == message.authorKind,
                entry.savedRevision == savedRevision,
                entry.bodyMarkdown == savedBody,
                entry.resolution == threadDetail.thread.resolution,
                case .located(let locatedOrigin) = threadDetail.thread.origin,
                entry.origin
                    == (try WorktreeAnnotationBatchProjector.batchOrigin(
                        locatedOrigin,
                        fingerprint: detail.session.acceptedSourceFingerprint
                    ))
            else {
                throw WorktreeAnnotationRepositoryError.invalidState
            }
        }
    }

    private func lockOutputMessages(
        _ database: Database,
        attemptID: WorktreeAnnotationOutputAttemptID,
        now: Date
    ) throws -> Bool {
        try database.execute(
            sql: """
                UPDATE annotation_message
                SET status = 'locked', semantic_revision = semantic_revision + 1, updated_at = ?
                WHERE id IN (
                    SELECT message_id FROM annotation_output_attempt_message WHERE attempt_id = ?
                ) AND status != 'locked'
                """,
            arguments: [now.timeIntervalSince1970, attemptID.databaseValue]
        )
        return database.changesCount > 0
    }

    private func markOutputMessagesHandled(
        _ database: Database,
        attemptID: WorktreeAnnotationOutputAttemptID,
        now: Date
    ) throws -> Bool {
        try database.execute(
            sql: """
                UPDATE annotation_message AS message
                SET status = 'locked',
                    handled = CASE WHEN author_kind = 'human' THEN 1 ELSE handled END,
                    semantic_revision = semantic_revision + 1, updated_at = ?
                WHERE EXISTS (
                    SELECT 1
                    FROM annotation_output_attempt_message membership
                    WHERE membership.attempt_id = ?
                      AND membership.message_id = message.id
                      AND membership.expected_saved_revision = message.saved_revision
                ) AND (
                    status != 'locked'
                    OR (author_kind = 'human' AND handled = 0)
                )
                """,
            arguments: [now.timeIntervalSince1970, attemptID.databaseValue]
        )
        return database.changesCount > 0
    }

    private func outputContentMutation(
        _ database: Database,
        canonicalResult: PreparedOutput,
        sessionID: WorktreeAnnotationSessionID
    ) throws -> WorktreeAnnotationCommittedMutation<PreparedOutput> {
        WorktreeAnnotationCommittedMutation(
            canonicalResult: canonicalResult,
            change: .content(
                sessionChanges: [
                    try loadCommittedSessionChange(database, sessionID: sessionID)
                ]
            )
        )
    }

    private func loadCommittedSessionChange(
        _ database: Database,
        sessionID: WorktreeAnnotationSessionID
    ) throws -> WorktreeAnnotationCommittedSessionChange {
        guard
            let row = try Row.fetchOne(
                database,
                sql: "SELECT worktree_id, semantic_revision FROM annotation_session WHERE id = ?",
                arguments: [sessionID.databaseValue]
            )
        else {
            throw WorktreeAnnotationRepositoryError.notFound
        }
        return WorktreeAnnotationCommittedSessionChange(
            worktreeID: row["worktree_id"],
            sessionID: sessionID,
            semanticRevision: row["semantic_revision"]
        )
    }

    private func requireOutputAttemptSessionID(
        _ database: Database,
        attemptID: WorktreeAnnotationOutputAttemptID
    ) throws -> WorktreeAnnotationSessionID {
        guard
            let rawSessionID = try String.fetchOne(
                database,
                sql: "SELECT session_id FROM annotation_output_attempt WHERE id = ?",
                arguments: [attemptID.databaseValue]
            )
        else {
            throw WorktreeAnnotationRepositoryError.notFound
        }
        return try decodeIdentity(rawSessionID)
    }

    private static func unixMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.towardZero))
    }
}
