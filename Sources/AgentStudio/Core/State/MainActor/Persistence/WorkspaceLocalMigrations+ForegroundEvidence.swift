import GRDB

extension WorkspaceLocalMigrations {
    static func registerForegroundEvidence(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("030_create_terminal_pane_foreground_evidence") { database in
            try database.execute(
                sql: """
                    CREATE TABLE terminal_pane_foreground_evidence (
                        pane_id TEXT PRIMARY KEY NOT NULL,
                        evidence_kind TEXT NOT NULL,
                        binding_generation_id TEXT,
                        observer_launch_id TEXT NOT NULL,
                        sequence INTEGER NOT NULL,
                        observed_at TEXT NOT NULL,
                        zmx_session_id TEXT,
                        program TEXT,
                        reported_provider TEXT,
                        reported_conversation_id TEXT,
                        unreadable_reason TEXT,
                        identity_version INTEGER,
                        boot_id TEXT,
                        daemon_pid INTEGER,
                        daemon_start_seconds INTEGER,
                        daemon_start_microseconds INTEGER,
                        leader_pid INTEGER,
                        leader_start_seconds INTEGER,
                        leader_start_microseconds INTEGER,
                        process_group_id INTEGER,
                        session_created_at INTEGER
                    )
                    """)
        }
    }
}
