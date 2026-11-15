import Foundation
import GRDB

extension WorkspaceCoreRepository {
    @concurrent nonisolated func terminalSessionID(for paneId: UUID) async throws -> ZmxSessionID? {
        try await databaseWriter.read { database in
            guard
                let rawID = try String.fetchOne(
                    database, sql: "SELECT zmx_session_id FROM pane_content_terminal WHERE pane_id = ?",
                    arguments: [paneId.uuidString])
            else { return nil }
            guard let sessionID = ZmxSessionID(restoring: rawID) else {
                throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
            }
            return sessionID
        }
    }
}
