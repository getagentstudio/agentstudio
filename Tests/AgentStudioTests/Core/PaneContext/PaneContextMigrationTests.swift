import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane context local migrations")
struct PaneContextMigrationTests {
    @Test("All seven app-owned category tables are present", arguments: paneContextServiceTables)
    func appTablesExist(table: String) throws {
        let queue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        defer { try? queue.close() }

        try WorkspaceLocalMigrations.migrate(queue)

        let exists = try queue.read { try $0.tableExists(table) }
        #expect(exists)
    }

    @Test("Pane migrations preserve existing nonempty boot data and are idempotent")
    func additiveMigrationPreservesData() throws {
        let queue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        defer { try? queue.close() }
        try WorkspaceLocalMigrations.migrateBootRequired(queue)
        try queue.write { database in
            try database.execute(
                sql:
                    "INSERT INTO local_entity_recency(entity_kind, entity_key, interaction_kind, last_interacted_at) VALUES ('repository', 'preserved', 'opened', 1)"
            )
        }

        try WorkspaceLocalMigrations.migrate(queue)
        try WorkspaceLocalMigrations.migrate(queue)

        let result = try queue.read { database in
            (
                try String.fetchOne(database, sql: "SELECT entity_key FROM local_entity_recency"),
                try database.tableExists("pane_request")
            )
        }
        #expect(result.0 == "preserved")
        #expect(result.1)
    }

    @Test("Notice message identity is unique only for notice rows")
    func noticeIdentityHasPartialUniqueness() throws {
        let queue = try migratedQueue()
        defer { try? queue.close() }
        let indexes = try queue.read { database in
            try uniqueIndexes(database, table: "pane_event")
        }

        #expect(indexes.contains { $0.columns == ["pane_id", "position"] && !$0.partial })
        #expect(indexes.contains { $0.columns == ["pane_id", "message_id"] && $0.partial })
        #expect(!indexes.contains { $0.columns == ["pane_id", "message_id"] && !$0.partial })
    }

    @Test("Requests, current values, epochs, positions and retirement have the PD keys")
    func categoryKeysMatchContracts() throws {
        let queue = try migratedQueue()
        defer { try? queue.close() }
        let expectedKeys: [String: [String]] = [
            "pane_request": ["pane_id", "message_id"],
            "pane_state": ["pane_id", "kind"],
            "pane_write_order": ["pane_id", "writer_key", "stream"],
            "pane_epoch_claim": ["claim_id"],
            "pane_answer_position": ["pane_id", "session_ref"],
            "pane_retirement": ["pane_id"],
        ]
        for (table, key) in expectedKeys {
            let keys = try queue.read { try uniqueIndexes($0, table: table) }
            #expect(keys.contains { $0.columns == key && !$0.partial }, "Missing key on \(table)")
        }
    }

    @Test("New category schemas use text/integer columns and no domain CHECK or triggers")
    func schemaKeepsAdditiveEnumEvolution() throws {
        let queue = try migratedQueue()
        defer { try? queue.close() }
        for table in paneContextServiceTables {
            let result = try queue.read { database in
                (
                    try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))").map { $0["type"] as String },
                    try String.fetchOne(
                        database, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                        arguments: [table]),
                    try Int.fetchOne(
                        database, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?",
                        arguments: [table])
                )
            }
            try #require(!result.0.isEmpty)
            #expect(result.0.allSatisfy { ["TEXT", "INTEGER"].contains($0.uppercased()) })
            let sql = try #require(result.1).uppercased().filter { !$0.isWhitespace }
            #expect(!sql.contains("CHECK(KIND") && !sql.contains("CHECK(STATE") && !sql.contains("CHECK(RECEIPT"))
            #expect(result.2 == 0)
        }
    }

    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(queue)
        return queue
    }
}

let paneContextServiceTables = [
    "pane_state", "pane_request", "pane_event", "pane_write_order",
    "pane_epoch_claim", "pane_answer_position", "pane_retirement",
]

private struct PaneContextIndexShape: Sendable {
    let columns: [String]
    let partial: Bool
}

private func uniqueIndexes(_ database: Database, table: String) throws -> [PaneContextIndexShape] {
    var result: [PaneContextIndexShape] = []
    for row in try Row.fetchAll(database, sql: "PRAGMA index_list(\(table))") {
        guard row["unique"] as Int == 1 else { continue }
        let name = row["name"] as String
        let columns = try Row.fetchAll(database, sql: "PRAGMA index_info(\(name))").map { $0["name"] as String }
        result.append(PaneContextIndexShape(columns: columns, partial: row["partial"] as Int == 1))
    }
    return result
}
