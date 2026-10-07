import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions commit participant")
struct SessionsCommitParticipantTests {
    @Test("one hook commit runs its participant exactly once after evidence")
    func participantJoinsHookCommit() async throws {
        let fixture = try SessionsDatabaseFixture()
        let storeId = UUIDv7.generate()
        let repository = fixture.makeRepository()
        let hook = makeHookAdmission(
            paneId: UUIDv7.generate(), eventName: .toolActivity, signal: .toolActivity(toolName: "Read"))
        let outcome = try await repository.applyHook(hook, commitParticipant: HookCursorParticipant(storeId: storeId))
        let committed = try #require(committedHookCommit(from: outcome))
        #expect(committed.disposition == .bound)
        let state = try await fixture.sqliteAccess.read { database in
            [
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_operation"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_evidence"),
                try Int.fetchOne(
                    database, sql: "SELECT last_handled_id FROM pane_context_cli_outbox_cursor WHERE store_id = ?",
                    arguments: [storeId.uuidString]),
            ]
        }
        #expect(state == [1, 1, 1])
    }

    @Test("participant failure rolls back the hook binding, evidence, revision and cursor")
    func participantFailureRollsBackAllEffects() async throws {
        let fixture = try SessionsDatabaseFixture()
        let hook = makeHookAdmission(paneId: UUIDv7.generate())
        await #expect(throws: HookCursorFailure.self) {
            try await fixture.makeRepository().applyHook(
                hook,
                commitParticipant: HookCursorParticipant(storeId: UUIDv7.generate(), fails: true))
        }
        let counts = try await fixture.sqliteAccess.read { database in
            try [
                "sessions_operation", "sessions_evidence", "sessions_pane_binding", "sessions_source",
                "pane_context_cli_outbox_cursor",
            ].map {
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \($0)")
            }
        }
        #expect(counts == [0, 0, 0, 0, 0])
    }
}

private struct HookCursorFailure: Error {}
private struct HookCursorParticipant: SessionsCommitParticipant {
    let storeId: UUID
    var fails = false
    func commit(in database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO pane_context_cli_outbox_cursor(store_id, last_handled_id) VALUES (?, 1)
                ON CONFLICT(store_id) DO UPDATE SET last_handled_id = last_handled_id + 1
                """, arguments: [storeId.uuidString])
        if fails { throw HookCursorFailure() }
    }
}
