import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Agent Line message migration")
struct PaneContextAgentLineMigrationTests {
    @Test("upgrade clears every legacy line and its refs while preserving other stored facts")
    func clearsLegacyLinesWithoutRewritingOtherFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "line-migration-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "local.sqlite")
        let pool = try SQLiteDatabaseFactory.makeFileBackedPool(at: path)
        defer { try? pool.close() }
        try WorkspaceLocalMigrations.migrator.migrate(pool, upTo: "027_sessions_hook_admission_cleanup")
        try pool.write { database in
            try seedLegacyLines(database)
            try seedOtherFacts(database)
        }
        let preserved = try pool.read(preservedFacts)
        #expect(
            try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pane_state WHERE kind = 'agentLine'") } == 4
        )

        try WorkspaceLocalMigrations.migrate(pool)
        try WorkspaceLocalMigrations.migrate(pool)

        let migrated = try pool.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM pane_state WHERE kind = 'agentLine'"),
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM pane_state_action WHERE parent_id LIKE 'legacy-%'"),
                try preservedFacts(database),
                try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty
            )
        }
        #expect(migrated.0 == 0)
        #expect(migrated.1 == 0)
        #expect(migrated.2 == preserved)
        #expect(migrated.3)
        try pool.close()
        let reopened = try SQLiteDatabaseFactory.makeFileBackedPool(at: path)
        defer { try? reopened.close() }
        try WorkspaceLocalMigrations.migrate(reopened)
        #expect(try reopened.read(preservedFacts) == preserved)
        #expect(
            try reopened.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pane_state WHERE kind = 'agentLine'") }
                == 0)
    }

    @Test("a normally ordered message written after migration survives later migration calls")
    func newMessageSurvivesMigrationReplay() async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service, stream: .line)
            let request = PaneLineWriteRequest(
                paneId: fixture.paneId, writer: fixture.sender,
                line: .init(
                    summary: "A new message", work: .done, detail: nil,
                    refs: [.openFile(path: "/new-message-ref", line: 7)], lifetime: .untilReplaced),
                writeNumber: .init(epoch: epoch, counter: 1))
            #expect(await service.setLine(request) == .applied)
            let written = try #require(try await fixture.detail(service).agentLine)
            let ordering = try await fixture.databasePool.read { database in
                try preservedFacts(database)
            }

            let reopenedLine = try await withoutBlockingCooperativePool {
                let reopened = try SQLiteDatabaseFactory.makeFileBackedPool(
                    at: fixture.rootDirectory.appending(path: "local.sqlite"))
                defer { try? reopened.close() }
                try WorkspaceLocalMigrations.migrate(reopened)
                return try reopened.read { database in
                    try PaneContextStorage.line(database, paneId: fixture.paneId, now: fixture.time.now)
                }
            }

            #expect(reopenedLine == written)
            #expect(try await fixture.detail(service).agentLine == written)
            #expect(try await fixture.databasePool.read(preservedFacts) == ordering)
        }
    }

    private func seedLegacyLines(_ database: Database) throws {
        for (index, stale, expires, summary) in [
            (0, 0, Optional<Int64>.none, Optional("Active message")),
            (1, 1, Int64?(1), Optional("Expired message")),
            (2, 1, Optional<Int64>.none, Optional("Ended session message")),
            (3, 0, Optional<Int64>.none, Optional<String>.none),
        ] {
            try database.execute(
                sql: """
                    INSERT INTO pane_state
                    (id, kind, pane_id, writer_kind, writer_pane_id, writer_session_ref,
                     write_epoch, write_counter, updated_at, summary, work_kind, expires_at, stale)
                    VALUES (?, 'agentLine', ?, 'pane', ?, ?, 7, '11', 1234567, ?, 'done', ?, ?)
                    """,
                arguments: [
                    "legacy-\(index)", "pane-\(index)", "pane-\(index)", "writer-\(index)", summary, expires, stale,
                ])
            if summary != nil {
                try database.execute(
                    sql:
                        "INSERT INTO pane_state_action(parent_id, ordinal, kind, path) VALUES (?, 0, 'openFile', '/kept-ref')",
                    arguments: ["legacy-\(index)"])
            }
        }
    }

    private func seedOtherFacts(_ database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO pane_state(id, kind, pane_id, title, writer_kind, updated_at, write_epoch, write_counter)
                    VALUES ('title', 'agentTitle', 'pane', 'Keep title', 'pane', 123, 8, '19');
                INSERT INTO pane_state_action(parent_id, ordinal, kind, path) VALUES ('title', 0, 'openFile', '/title-ref');
                INSERT INTO pane_request
                    (id, pane_id, message_id, position, sender_kind, importance, body, sent_at, reason, form_kind, waiting, state, receipt)
                    VALUES ('ask', 'pane', 'ask-message', 1, 'pane', 'attention', 'Keep ask', 456, 'question', 'freeText', 'nonBlocking', 'open', 'notYetConfirmed');
                INSERT INTO pane_request_action(parent_id, ordinal, kind, path) VALUES ('ask', 0, 'openFile', '/ask-ref');
                INSERT INTO pane_event
                    (id, kind, pane_id, position, message_id, subject_id, sender_kind, importance, body, notice_state, sent_at)
                    VALUES ('notice', 'notice', 'pane', 2, 'notice-message', 'notice-message', 'pane', 'info', 'Keep notice', 'unread', 789);
                INSERT INTO pane_event_action(parent_id, ordinal, kind, path) VALUES ('notice', 0, 'openFile', '/notice-ref');
                INSERT INTO pane_write_order VALUES ('pane', 'writer', 'line', 7, '11');
                INSERT INTO pane_epoch_claim VALUES ('claim', 'pane', 'writer', 'line', 7, 123);
                INSERT INTO pane_answer_position VALUES ('pane', 'session', 9, 12);
                INSERT INTO pane_retirement VALUES ('retired-pane', 100, 200);
                INSERT INTO local_entity_recency VALUES ('repository', 'preserved', 'opened', 1);
                """)
    }
}

private func preservedFacts(_ database: Database) throws -> [String: [String]] {
    var result: [String: [String]] = [:]
    for table in [
        "pane_state", "pane_state_action", "pane_request", "pane_request_action", "pane_event", "pane_event_action",
        "pane_write_order", "pane_epoch_claim", "pane_answer_position", "pane_retirement", "local_entity_recency",
    ] {
        let names = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
        let columns = names.map { "quote(\($0))" }.joined(separator: " || ',' || ")
        let scope: String
        switch table {
        case "pane_state": scope = "WHERE kind != 'agentLine'"
        case "pane_state_action": scope = "WHERE parent_id NOT LIKE 'legacy-%'"
        default: scope = ""
        }
        result[table] = try String.fetchAll(database, sql: "SELECT \(columns) FROM \(table) \(scope) ORDER BY rowid")
    }
    return result
}
