import AgentStudioSessions
import Foundation
import GRDB

/// App owns cursor SQL; Sessions supplies the same transaction as the effect.
struct CLIOutboxCursorCommitParticipant: SessionsCommitParticipant {
    let storeID: UUID
    let lastHandledID: Int64

    func commit(in database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO pane_context_cli_outbox_cursor (store_id, last_handled_id) VALUES (?, ?)
                ON CONFLICT(store_id) DO UPDATE SET
                    last_handled_id = MAX(pane_context_cli_outbox_cursor.last_handled_id, excluded.last_handled_id)
                """, arguments: [storeID.uuidString, lastHandledID])
    }

    static func read(in database: Database, storeID: UUID) throws -> Int64 {
        try Int64.fetchOne(
            database,
            sql: "SELECT last_handled_id FROM pane_context_cli_outbox_cursor WHERE store_id = ?",
            arguments: [storeID.uuidString]) ?? 0
    }
}
