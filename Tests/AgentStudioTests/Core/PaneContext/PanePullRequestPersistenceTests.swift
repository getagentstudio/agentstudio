import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane PR persistence and migration")
struct PanePullRequestPersistenceTests {
    @Test("Migration 033 adds both PR tables without changing nonempty 032 pane context")
    func migrationPreserves032Rows() async throws {
        let result = try await withoutBlockingCooperativePool {
            // Arrange: a file containing the schema immediately before this feature.
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "pane-pr-migration-\(UUIDv7.generate())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let pool = try SQLiteDatabaseFactory.makeFileBackedPool(at: directory.appending(path: "local.sqlite"))
            defer { try? pool.close() }
            try WorkspaceLocalMigrations.migrator.migrate(pool, upTo: "032_create_terminal_restore_outbox_identity")
            let pane = PaneId.generateUUIDv7()
            let titleId = UUIDv7.generate().uuidString
            try pool.write { database in
                try database.execute(
                    sql:
                        "INSERT INTO pane_state(id, kind, pane_id, title, detail_revision) VALUES (?, 'agentTitle', ?, 'Keep me', 17)",
                    arguments: [titleId, pane.uuidString])
            }

            // Act: migrate twice to include replay/idempotency.
            try WorkspaceLocalMigrations.migrate(pool)
            try WorkspaceLocalMigrations.migrate(pool)

            // Assert: the old value, identity and revision are preserved; both new tables exist.
            return try pool.read { database in
                (
                    try String.fetchOne(
                        database, sql: "SELECT title FROM pane_state WHERE id = ?", arguments: [titleId]),
                    try Int.fetchOne(
                        database, sql: "SELECT detail_revision FROM pane_state WHERE id = ?", arguments: [titleId]),
                    try database.tableExists("pane_pull_request"),
                    try database.tableExists("pane_pull_request_contribution"),
                    try Row.fetchAll(database, sql: "PRAGMA foreign_key_list(pane_pull_request_contribution)").isEmpty
                )
            }
        }
        #expect(result.0 == "Keep me")
        #expect(result.1 == 17)
        #expect(result.2 && result.3 && result.4)
    }

    @Test("The same PR identities, authors and dates survive closing and reopening the real database")
    func storageReopensUnchanged() async throws {
        let fixture = try await PaneContextServiceFixture.make()
        let service = fixture.makeService()
        do {
            let identity = try ForgePullRequestIdentity(
                host: "github.com", owner: "Owner", repository: "Repo", number: 7)
            let author = PanePullRequestAuthor.paneAgent(sourcePaneId: .generateUUIDv7(), conversation: nil)
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: identity, author: author)
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: identity, author: .person)
            let before = try await service.listPullRequests(paneId: fixture.paneId)
            try #require(before.count == 1)
            #expect(before.first?.identity.owner == "owner")
            #expect(before.first?.identity.repository == "repo")
            await service.stop()

            let reopened = try await withoutBlockingCooperativePool {
                try fixture.databasePool.close()
                let pool = try SQLiteDatabaseFactory.makeFileBackedPool(
                    at: fixture.rootDirectory.appending(path: "local.sqlite"))
                defer { try? pool.close() }
                try WorkspaceLocalMigrations.migrate(pool)
                return try pool.read { try PaneContextStorage.pullRequests($0, paneId: fixture.paneId) }
            }
            let beforeRecords = try before.map {
                PanePullRequestRecord(
                    identity: $0.identity, createdAt: try #require($0.createdAt),
                    contributions: $0.contributions)
            }
            #expect(reopened == beforeRecords)
            try await withoutBlockingCooperativePool { try FileManager.default.removeItem(at: fixture.rootDirectory) }
        } catch {
            await service.stop()
            try? await fixture.removeFiles()
            throw error
        }
    }
}
