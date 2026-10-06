import AgentStudioInfrastructure
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Sessions local schema migration")
struct WorkspaceLocalSessionsMigrationTests {
    @Test("upgrading existing local data adds Sessions without replacing retained rows")
    func upgradingPreservesExistingLocalRows() throws {
        let database = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "AgentStudio.sqlite.sessions-migration")
        try WorkspaceLocalMigrations.migrator.migrate(
            database, upTo: "007_add_per_screen_sidebar_organization"
        )
        try database.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO local_repository_activity (
                        repository_stable_key, continuous_coverage_started_at,
                        updated_at, owned_promotion_unsettled
                    ) VALUES ('retained-repository', 1, 2, 0)
                    """
            )
            #expect(try !connection.tableExists("sessions_message"))
        }

        try WorkspaceLocalMigrations.migrate(database)
        try WorkspaceLocalMigrations.migrate(database)

        try database.read { connection in
            let retainedKeys = try String.fetchAll(
                connection, sql: "SELECT repository_stable_key FROM local_repository_activity"
            )
            #expect(retainedKeys == ["retained-repository"])
            for table in [
                "sessions_conversation", "sessions_pane_binding", "sessions_source",
                "sessions_evidence", "sessions_provider_question", "sessions_provider_question_option",
                "sessions_operation",
            ] {
                #expect(try connection.tableExists(table))
            }
            for removed in ["sessions_message", "sessions_result", "sessions_loss", "sessions_attention"] {
                #expect(try !connection.tableExists(removed))
            }
            #expect(try String.fetchAll(connection, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
