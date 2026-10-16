import GRDB

extension WorkspaceLocalMigrations {
    static func registerSessionsHookCleanup(in migrator: inout DatabaseMigrator) {
        // GRDB disables enforcement before the transaction and checks it before
        // commit. Dropping the old parent must not cascade into question rows.
        migrator.registerMigration("027_sessions_hook_admission_cleanup", foreignKeyChecks: .deferred) { database in
            try reopenLaunchEndedBindings(database)
            try rebuildRetainedEvidence(database)
            for table in ["sessions_message", "sessions_result", "sessions_loss", "sessions_attention"] {
                try database.execute(sql: "DROP TABLE \(table)")
            }
            guard try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw SessionsCleanupMigrationError.invalidForeignKeys
            }
        }
    }

    private static func reopenLaunchEndedBindings(_ database: Database) throws {
        try database.execute(
            sql: """
                UPDATE sessions_pane_binding AS binding
                SET status = 'active', ended_at = NULL
                WHERE binding.status = 'ended'
                  AND EXISTS (
                      SELECT 1 FROM sessions_operation AS operation
                      WHERE operation.commit_revision = binding.committed_revision
                        AND operation.operation_kind = 'prepareForLaunch')
                  AND NOT EXISTS (
                      SELECT 1 FROM sessions_pane_binding AS later
                      WHERE later.pane_id = binding.pane_id
                        AND later.committed_revision > binding.committed_revision)
                """)
        try database.execute(
            sql: """
                UPDATE sessions_source AS source
                SET status = 'active', ended_at = NULL
                WHERE source.status = 'ended'
                  AND EXISTS (
                      SELECT 1 FROM sessions_pane_binding AS binding
                      JOIN sessions_operation AS operation ON operation.commit_revision = binding.committed_revision
                      WHERE binding.binding_generation_id = source.binding_generation_id
                        AND binding.status = 'active' AND binding.ended_at IS NULL
                        AND source.committed_revision = binding.committed_revision
                        AND operation.operation_kind = 'prepareForLaunch')
                """)
    }

    private static func rebuildRetainedEvidence(_ database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE sessions_evidence_retained (
                    occurrence_id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES sessions_conversation(id) ON DELETE RESTRICT,
                    binding_generation_id TEXT NOT NULL REFERENCES sessions_pane_binding(binding_generation_id) ON DELETE RESTRICT,
                    source_id TEXT REFERENCES sessions_source(id) ON DELETE RESTRICT,
                    source_generation_id TEXT NOT NULL,
                    turn_id TEXT,
                    subject_kind TEXT NOT NULL,
                    subject_identifier TEXT,
                    evidence_kind TEXT NOT NULL,
                    origin TEXT NOT NULL,
                    status_effect TEXT NOT NULL,
                    occurred_at REAL NOT NULL,
                    committed_revision INTEGER NOT NULL REFERENCES sessions_operation(commit_revision) ON DELETE RESTRICT,
                    admission_sequence INTEGER,
                    provider_event TEXT,
                    tool_name TEXT,
                    tool_call_id TEXT,
                    failure_summary TEXT,
                    elicitation_id TEXT,
                    prompt_summary TEXT,
                    has_questions INTEGER NOT NULL DEFAULT 0
                )
                """)
        try database.execute(
            sql: """
                INSERT INTO sessions_evidence_retained (
                    occurrence_id, conversation_id, binding_generation_id, source_id,
                    source_generation_id, turn_id, subject_kind, subject_identifier, evidence_kind,
                    origin, status_effect, occurred_at, committed_revision, admission_sequence,
                    provider_event, tool_name, tool_call_id, failure_summary, elicitation_id, prompt_summary, has_questions
                ) SELECT
                    occurrence_id, conversation_id, binding_generation_id, source_id,
                    source_generation_id, turn_id, subject_kind, subject_identifier, evidence_kind,
                    origin, CASE freshness WHEN 'live' THEN 'applied' ELSE 'recordedOnly' END,
                    occurred_at, committed_revision, admission_sequence,
                    provider_event, tool_name, tool_call_id, failure_summary, elicitation_id, prompt_summary, has_questions
                FROM sessions_evidence
                """)
        try database.execute(sql: "DROP TABLE sessions_evidence")
        try database.execute(sql: "ALTER TABLE sessions_evidence_retained RENAME TO sessions_evidence")
        try database.execute(
            sql: """
                CREATE INDEX idx_sessions_evidence_reduction
                ON sessions_evidence(conversation_id, binding_generation_id, turn_id, occurred_at, occurrence_id)
                """)
        guard try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw SessionsCleanupMigrationError.invalidForeignKeys
        }
    }
}

private enum SessionsCleanupMigrationError: Error {
    case invalidForeignKeys
}
