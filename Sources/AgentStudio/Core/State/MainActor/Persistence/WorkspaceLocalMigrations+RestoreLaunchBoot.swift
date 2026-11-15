import GRDB

extension WorkspaceLocalMigrations {
    static func registerRestoreLaunchBoot(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("031_create_terminal_restore_launch_boot") { database in
            try database.execute(
                sql: """
                    CREATE TABLE terminal_restore_launch_boot (
                        singleton INTEGER PRIMARY KEY,
                        boot_id TEXT NOT NULL,
                        recorded_at TEXT NOT NULL
                    )
                    """)
        }
    }
}
