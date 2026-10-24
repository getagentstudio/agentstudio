import AgentStudioInfrastructure
import Foundation
import GRDB

extension WorkspaceCoreRepository {
    func persistedPaneIds(workspaceId: UUID) async throws -> Set<UUID> {
        try await databaseWriter.read { database in
            try Set(
                String.fetchAll(
                    database, sql: "SELECT id FROM pane WHERE workspace_id = ?", arguments: [workspaceId.uuidString]
                ).map { value in
                    guard let paneId = UUID(uuidString: value) else {
                        throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
                    }
                    return paneId
                })
        }
    }

    func liveZmxSessionsByPane(workspaceId: UUID, performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil)
        async throws -> [UUID: ZmxSessionID]
    {
        try await databaseWriter.read { database in
            try AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
                .restoreForegroundGather, recorder: performanceTraceRecorder
            ) {
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT pane.id, terminal.zmx_session_id
                        FROM pane_content_terminal AS terminal JOIN pane ON pane.id = terminal.pane_id
                        WHERE pane.workspace_id = ? AND terminal.provider = 'zmx'
                        """, arguments: [workspaceId.uuidString])
                return try Dictionary(
                    uniqueKeysWithValues: rows.map { row in
                        let rawPane: String = row["id"]
                        let rawSession: String? = row["zmx_session_id"]
                        guard let paneId = UUID(uuidString: rawPane), let rawSession,
                            let sessionId = ZmxSessionID(restoring: rawSession)
                        else {
                            throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
                        }
                        return (paneId, sessionId)
                    })
            }
        }
    }
}
