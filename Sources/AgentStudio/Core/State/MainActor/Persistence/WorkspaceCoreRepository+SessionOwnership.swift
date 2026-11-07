import AgentStudioInfrastructure
import Foundation
import GRDB

/// Resolve release eligibility after all selected undo entries have finished, within their transaction.
func readUndoCloseRetirement(rawCloseID: String, database: Database) throws -> WorkspaceUndoCloseRetirement {
    guard let closeID = UUID(uuidString: rawCloseID) else { throw WorkspaceUndoJournalFailure.invalidStoredIdentifier }
    let members = try readUndoCloseMembers(closeID: closeID, database: database)
    var unownedPaneIDs = Set<UUID>()
    for member in members {
        let isOwned =
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM pane WHERE id = ?)
                        OR EXISTS (
                            SELECT 1 FROM workspace_undo_close_member AS member
                            JOIN workspace_undo_close AS operation ON operation.close_id = member.close_id
                            WHERE member.pane_id = ? AND operation.state = 'available'
                        )
                    """, arguments: [member.paneID.uuidString, member.paneID.uuidString]) ?? true
        if !isOwned { unownedPaneIDs.insert(member.paneID) }
    }
    return .init(closeID: closeID, members: members, unownedPaneIDs: unownedPaneIDs)
}

extension WorkspaceCoreRepository {
    func terminalSessionNeedsIdentity(_ sessionID: ZmxSessionID) throws -> Bool {
        try databaseWriter.read { database in
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM workspace_terminal_session_ownership
                        WHERE session_id = ? AND cleanup_state = 'pending' AND process_identity IS NULL)
                    """, arguments: [sessionID.rawValue]) ?? false
        }
    }

    func terminalSessionIsPending(_ sessionID: ZmxSessionID, identity: Data?) throws -> Bool {
        try databaseWriter.read { database in
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM workspace_terminal_session_ownership
                        WHERE session_id = ? AND cleanup_state = 'pending' AND process_identity IS ?)
                    """, arguments: [sessionID.rawValue, identity]) ?? false
        }
    }

    func terminalSessionCleanupBatch(after sessionID: ZmxSessionID?) throws -> [WorkspaceTerminalSessionCleanupWork] {
        try databaseWriter.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT session_id, process_identity, zmx_protocol_version
                    FROM workspace_terminal_session_ownership
                    WHERE cleanup_state = 'pending'
                        AND (? IS NULL OR session_id > ?)
                    ORDER BY session_id LIMIT ?
                    """,
                arguments: [
                    sessionID?.rawValue, sessionID?.rawValue, AppPolicies.WorkspacePersistence.sessionCleanupBatchSize,
                ]
            ).map { row in
                let rawID: String = row["session_id"]
                guard let sessionID = ZmxSessionID(restoring: rawID) else {
                    throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
                }
                let protocolVersion: Int? = row["zmx_protocol_version"]
                if protocolVersion != Int(ZmxProtocol.version) {
                    return .stopIncompatible(sessionID, identity: row["process_identity"])
                }
                if let identity: Data = row["process_identity"] { return .retire(sessionID, identity: identity) }
                return .observeIdentity(sessionID)
            }
        }
    }

    func recordTerminalSessionCleanupFailure(
        sessionID: ZmxSessionID, expectedIdentity: Data?, failure: ZmxSessionControlFailure
    ) throws {
        try databaseWriter.write { database in
            try database.execute(
                sql: """
                    UPDATE workspace_terminal_session_ownership SET last_cleanup_error = ?
                    WHERE session_id = ? AND cleanup_state = 'pending'
                        AND process_identity IS ? AND last_cleanup_error IS NOT ?
                    """, arguments: [failure.rawValue, sessionID.rawValue, expectedIdentity, failure.rawValue])
        }
    }

    /// Persist first process evidence for an already-correlated application session.
    /// A repeated identical observation is idempotent; a new incarnation cannot replace it.
    func recordTerminalSessionIdentity(sessionID: ZmxSessionID, identity: Data) throws -> Bool {
        guard !identity.isEmpty else { return false }
        return try databaseWriter.write { database in
            try database.execute(
                sql: """
                    UPDATE workspace_terminal_session_ownership SET process_identity = ?, last_cleanup_error = NULL
                    WHERE session_id = ? AND cleanup_state IN ('owned', 'pending') AND process_identity IS NULL
                    """, arguments: [identity, sessionID.rawValue])
            return try Bool.fetchOne(
                database,
                sql: """
                    SELECT process_identity = ? FROM workspace_terminal_session_ownership
                    WHERE session_id = ? AND cleanup_state IN ('owned', 'pending')
                    """, arguments: [identity, sessionID.rawValue]) ?? false
        }
    }

    /// Complete matching pending evidence, or a NULL-evidence session whose endpoint was confirmed absent.
    func completeTerminalSessionCleanup(
        sessionID: ZmxSessionID, expectedIdentity: Data?, completedAt: Date
    ) throws -> Bool {
        guard expectedIdentity?.isEmpty != true, completedAt.timeIntervalSince1970.isFinite else { return false }
        return try databaseWriter.write { database in
            try database.execute(
                sql: """
                    UPDATE workspace_terminal_session_ownership
                    SET cleanup_state = 'completed', cleanup_completed_at = ?, last_cleanup_error = NULL
                    WHERE session_id = ? AND cleanup_state = 'pending' AND process_identity IS ?
                    """, arguments: [completedAt.timeIntervalSince1970, sessionID.rawValue, expectedIdentity])
            return try Int.fetchOne(database, sql: "SELECT changes()") == 1
        }
    }

    func nextUndoDeadline(bootID: String) throws -> Int64? {
        try databaseWriter.read { database in
            try Int64.fetchOne(
                database,
                sql: """
                    SELECT min(deadline_uptime_ns) FROM workspace_undo_close
                    WHERE state = 'available' AND deadline_boot_id = ?
                    """, arguments: [bootID])
        }
    }

    func workspaceIDsWithAvailableUndo() throws -> [UUID] {
        try databaseWriter.read { database in
            try String.fetchAll(
                database,
                sql:
                    "SELECT DISTINCT workspace_id FROM workspace_undo_close WHERE state = 'available' ORDER BY workspace_id"
            )
            .map { rawID in
                guard let workspaceID = UUID(uuidString: rawID) else {
                    throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
                }
                return workspaceID
            }
        }
    }

    func reconcileUnownedTerminalSessions(at time: WorkspaceUndoJournalTime) throws {
        try validateUndoJournalTime(time)
        try databaseWriter.write { database in
            try markUnownedTerminalSessionsForCleanup(database, finishedUndoWorkspaceID: nil, requestedAt: time.utc)
        }
    }

    func pendingTerminalSessionIDs() throws -> Set<ZmxSessionID> {
        try databaseWriter.read { database in
            Set(
                try String.fetchAll(
                    database,
                    sql: "SELECT session_id FROM workspace_terminal_session_ownership WHERE cleanup_state = 'pending'"
                )
                .map { rawID in
                    guard let sessionID = ZmxSessionID(restoring: rawID) else {
                        throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
                    }
                    return sessionID
                })
        }
    }
}

func markUnownedTerminalSessionsForCleanup(
    _ database: Database,
    finishedUndoWorkspaceID: UUID?,
    sessionID: ZmxSessionID? = nil,
    requestedAt: Date
) throws {
    try database.execute(
        sql: """
            UPDATE workspace_terminal_session_ownership
            SET cleanup_state = 'pending', cleanup_requested_at = ?
            WHERE cleanup_state = 'owned'
                AND (? IS NULL OR session_id = ?)
                AND (? IS NULL OR session_id IN (
                    SELECT member.session_id FROM workspace_undo_close_member AS member
                    JOIN workspace_undo_close AS operation ON operation.close_id = member.close_id
                    WHERE operation.workspace_id = ? AND operation.state IN ('evicted', 'expired', 'restored')
                ))
                AND NOT EXISTS (
                    SELECT 1 FROM pane_content_terminal AS terminal
                    WHERE terminal.zmx_session_id = workspace_terminal_session_ownership.session_id
                )
                AND NOT EXISTS (
                    SELECT 1 FROM workspace_undo_close_member AS member
                    JOIN workspace_undo_close AS operation ON operation.close_id = member.close_id
                    WHERE member.session_id = workspace_terminal_session_ownership.session_id
                        AND operation.state = 'available'
                )
            """,
        arguments: [
            requestedAt.timeIntervalSince1970, sessionID?.rawValue, sessionID?.rawValue,
            finishedUndoWorkspaceID?.uuidString, finishedUndoWorkspaceID?.uuidString,
        ]
    )
}

func terminalSessionsOwnedByWorkspace(_ workspaceID: UUID, database: Database) throws -> [ZmxSessionID] {
    try String.fetchAll(
        database,
        sql: """
            SELECT terminal.zmx_session_id FROM pane_content_terminal AS terminal
            JOIN pane ON pane.id = terminal.pane_id
            WHERE pane.workspace_id = ? AND terminal.zmx_session_id IS NOT NULL
            UNION
            SELECT member.session_id FROM workspace_undo_close_member AS member
            JOIN workspace_undo_close AS operation ON operation.close_id = member.close_id
            WHERE operation.workspace_id = ? AND operation.state = 'available' AND member.session_id IS NOT NULL
            """, arguments: [workspaceID.uuidString, workspaceID.uuidString]
    ).map { rawID in
        guard let sessionID = ZmxSessionID(restoring: rawID) else {
            throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
        }
        return sessionID
    }
}
