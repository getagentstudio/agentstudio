import Foundation
import GRDB

extension WorkspaceCoreRepository {
    /// The app-wide retain set includes drawer children and every available Undo
    /// member. The same ownership query scopes hydration to one workspace.
    func fetchRetainedPaneActivityPaneIDs(workspaceID: UUID? = nil) throws -> Set<UUID> {
        try databaseWriter.read { database in
            let paneIDs = try String.fetchAll(
                database,
                sql: """
                    SELECT id AS pane_id FROM pane
                    WHERE (? IS NULL OR workspace_id = ?)
                    UNION
                    SELECT member.pane_id
                    FROM workspace_undo_close_member AS member
                    JOIN workspace_undo_close AS close ON close.close_id = member.close_id
                    WHERE close.state = 'available' AND (? IS NULL OR close.workspace_id = ?)
                    """,
                arguments: [
                    workspaceID?.uuidString, workspaceID?.uuidString, workspaceID?.uuidString, workspaceID?.uuidString,
                ]
            )
            return try Set(
                paneIDs.map { rawID in
                    guard let paneID = UUID(uuidString: rawID) else {
                        throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
                    }
                    return paneID
                })
        }
    }
}
