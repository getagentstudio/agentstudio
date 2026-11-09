import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Workspace browser migration ordering")
struct WorkspaceBrowserMigrationOrderingTests {
    @Test("browser migration follows main's 019 and preserves its protocol version and browser rows")
    func browserMigrationUpgradesMain019Database() throws {
        // Arrange: an actual database at main's final migration, with legacy browser data.
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrator.migrate(databaseQueue, upTo: "019_track_zmx_protocol_version")
        let workspaceId = UUIDv7.generate().uuidString
        let browserPaneId = UUIDv7.generate().uuidString
        try databaseQueue.write { database in
            #expect(try database.tableExists("pane_content_browser") == false)
            try database.execute(
                sql: "INSERT INTO workspace(id, name, created_at, updated_at) VALUES (?, 'Preserved', 1, 1)",
                arguments: [workspaceId])
            try database.execute(
                sql: """
                    INSERT INTO pane(
                        id, workspace_id, content_type, execution_backend, launch_directory, title, cwd,
                        residency_kind, kind, parent_pane_id, created_at, updated_at
                    )
                    VALUES (?, ?, 'browser', 'zmx', '/tmp', 'Browser', '/tmp', 'active', 'leaf', NULL, 1, 1)
                    """,
                arguments: [browserPaneId, workspaceId])
            try database.execute(
                sql: """
                    INSERT INTO pane_content_webview(pane_id, url, title, show_navigation)
                    VALUES (?, 'https://example.com/preserved', 'Preserved page', 0)
                    """,
                arguments: [browserPaneId])
            try database.execute(
                sql: """
                    INSERT INTO workspace_terminal_session_ownership(session_id, zmx_protocol_version)
                    VALUES ('preserved-session', 1)
                    """)
        }

        // Act: upgrade and repeat startup migration to check it runs once.
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        try WorkspaceCoreMigrations.migrate(databaseQueue)

        // Assert: main's state survives and the browser migration is recorded after 019.
        try databaseQueue.read { database in
            let completed = try WorkspaceCoreMigrations.migrator.completedMigrations(database)
            #expect(Array(completed.suffix(2)) == ["019_track_zmx_protocol_version", "020_browser_webviews"])
            #expect(
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT zmx_protocol_version FROM workspace_terminal_session_ownership
                        WHERE session_id = 'preserved-session'
                        """
                ) == 1)
            let browser = try #require(
                Row.fetchOne(
                    database, sql: "SELECT * FROM pane_content_browser WHERE pane_id = ?", arguments: [browserPaneId]))
            #expect(browser["active_webview_id"] as String == browserPaneId)
            #expect(browser["show_navigation"] as Int == 0)
            let webview = try #require(
                Row.fetchOne(
                    database,
                    sql: "SELECT * FROM pane_content_webview WHERE browser_pane_id = ?",
                    arguments: [browserPaneId]))
            #expect(webview["id"] as String == browserPaneId)
            #expect(webview["position"] as Int == 0)
            #expect(webview["url"] as String == "https://example.com/preserved")
            #expect(webview["title"] as String == "Preserved page")
            #expect(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
