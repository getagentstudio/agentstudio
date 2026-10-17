import GRDB

extension WorkspaceLocalMigrations {
    static func registerPaneActivitySchema(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("028_add_local_pane_activity") { database in
            try database.execute(
                sql: """
                    CREATE TABLE local_pane_activity (
                        pane_id TEXT PRIMARY KEY,
                        activity_at REAL NOT NULL,
                        source TEXT NOT NULL
                    )
                    """
            )
        }
    }
}
