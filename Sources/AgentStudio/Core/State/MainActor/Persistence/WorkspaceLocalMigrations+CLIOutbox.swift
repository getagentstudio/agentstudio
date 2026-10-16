import GRDB

extension WorkspaceLocalMigrations {
    static func registerCLIOutboxCursor(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("019_create_pane_context_cli_outbox_cursor") { database in
            try database.execute(
                sql: """
                    CREATE TABLE pane_context_cli_outbox_cursor (
                        store_id TEXT PRIMARY KEY NOT NULL,
                        last_handled_id INTEGER NOT NULL
                    )
                    """)
        }
    }
}
