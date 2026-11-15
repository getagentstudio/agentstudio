import GRDB

extension WorkspaceLocalMigrations {
    static func registerRestoreOutboxIdentity(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("032_create_terminal_restore_outbox_identity") { database in
            try database.execute(
                sql: "CREATE TABLE terminal_restore_outbox_identity(store_id TEXT NULL, adopted_at TEXT NOT NULL)")
        }
    }
}
