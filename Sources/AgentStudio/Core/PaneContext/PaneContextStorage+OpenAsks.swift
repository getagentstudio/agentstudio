import Foundation
import GRDB

extension PaneContextStorage {
    static func openAskUpdate(_ database: Database, paneId: PaneId, sender: AgentMessageSender, advancing: Bool) throws
        -> PaneContextOpenAskUpdate?
    {
        guard case .session(_, _, let generation) = sender else { return nil }
        let key = writerKey(sender)
        if advancing {
            try database.execute(
                sql: """
                    INSERT INTO pane_answer_position(pane_id, session_ref, ask_sequence)
                    VALUES (?, ?, 1) ON CONFLICT(pane_id, session_ref)
                    DO UPDATE SET ask_sequence = ask_sequence + 1
                    """, arguments: [paneId.uuidString, key])
        }
        let sequence =
            try Int64.fetchOne(
                database, sql: "SELECT ask_sequence FROM pane_answer_position WHERE pane_id = ? AND session_ref = ?",
                arguments: [paneId.uuidString, key]) ?? 0
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT reason, COUNT(*) AS count FROM pane_request
                WHERE pane_id = ? AND sender_binding_generation = ? AND state = 'open'
                GROUP BY reason
                """, arguments: [paneId.uuidString, generation.uuidString])
        var approval = 0
        var question = 0
        var blocked = 0
        for row in rows {
            let name: String = try required(row, "reason")
            let count: Int = try required(row, "count")
            switch name {
            case "approval": approval = count
            case "question": question = count
            case "blocked": blocked = count
            default: throw PaneContextStorageFailure.decode("reason")
            }
        }
        return PaneContextOpenAskUpdate(
            bindingGenerationId: generation, sequence: sequence, approval: approval, question: question,
            blocked: blocked)
    }

    static func openAskUpdates(_ database: Database) throws -> [PaneContextOpenAskUpdate] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT DISTINCT pane_id, sender_kind, sender_pane_id, sender_provider,
                    sender_session_ref, sender_binding_generation
                FROM pane_request WHERE sender_kind = 'session'
                """)
        return try rows.compactMap { row in
            try openAskUpdate(
                database, paneId: PaneId(existingUUID: uuid(row, "pane_id")), sender: sender(row, prefix: "sender"),
                advancing: false)
        }
    }
}
