import Foundation
import GRDB

extension WorkspaceCoreRepository {
    /// The graph and available undo journal are both durable owners. Neither
    /// visibility nor a native surface is an admission input to capture.
    @concurrent nonisolated func scrollbackPaneBindings(workspaceID: UUID) async throws -> [ScrollbackPaneBinding] {
        try Task.checkCancellation()
        let bindings = try await databaseWriter.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT terminal.pane_id AS pane_id, terminal.zmx_session_id AS session_id
                    FROM pane_content_terminal AS terminal
                    JOIN pane ON pane.id = terminal.pane_id
                    WHERE pane.workspace_id = ? AND terminal.zmx_session_id IS NOT NULL
                    UNION
                    SELECT member.pane_id AS pane_id, member.session_id AS session_id
                    FROM workspace_undo_close_member AS member
                    JOIN workspace_undo_close AS operation ON operation.close_id = member.close_id
                    WHERE operation.workspace_id = ? AND operation.state = 'available' AND member.session_id IS NOT NULL
                    ORDER BY pane_id
                    """, arguments: [workspaceID.uuidString, workspaceID.uuidString]
            ).map { row -> ScrollbackPaneBinding in
                let rawPaneID: String = row["pane_id"]
                let rawSessionID: String = row["session_id"]
                guard let paneUUID = UUID(uuidString: rawPaneID), let sessionID = ZmxSessionID(restoring: rawSessionID)
                else {
                    throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
                }
                return .init(paneID: PaneId(existingUUID: paneUUID), sessionID: sessionID)
            }
        }
        try Task.checkCancellation()
        return bindings
    }
}
