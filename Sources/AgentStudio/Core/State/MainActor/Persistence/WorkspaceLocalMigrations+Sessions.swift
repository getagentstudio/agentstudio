import GRDB

extension WorkspaceLocalMigrations {
    static func registerSessionsSchema(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("011_create_sessions_ingestion_schema") { database in
            for statement in sessionsSchemaStatements {
                try database.execute(sql: statement)
            }
        }
        migrator.registerMigration("020_sessions_status_and_replay") { database in
            try database.execute(sql: "ALTER TABLE sessions_operation ADD COLUMN fingerprint_version INTEGER")
            try database.execute(sql: "ALTER TABLE sessions_operation ADD COLUMN source_occurred_at REAL")
            try database.execute(sql: "ALTER TABLE sessions_evidence ADD COLUMN admission_sequence INTEGER")
            try database.execute(sql: "ALTER TABLE sessions_evidence ADD COLUMN source_occurred_at REAL")
            try database.execute(sql: "ALTER TABLE sessions_pane_binding ADD COLUMN resume_hint TEXT")
            try database.execute(sql: "ALTER TABLE sessions_pane_binding ADD COLUMN owner_pane_id TEXT")
            for column in [
                "provider_event", "tool_name", "tool_call_id", "failure_summary", "elicitation_id", "prompt_summary",
            ] {
                try database.execute(sql: "ALTER TABLE sessions_evidence ADD COLUMN \(column) TEXT")
            }
            try database.execute(
                sql: "ALTER TABLE sessions_evidence ADD COLUMN has_questions INTEGER NOT NULL DEFAULT 0")
            try database.execute(
                sql: """
                    CREATE TABLE sessions_provider_question (
                        occurrence_id TEXT NOT NULL REFERENCES sessions_evidence(occurrence_id) ON DELETE CASCADE,
                        question_index INTEGER NOT NULL,
                        question TEXT NOT NULL, header TEXT NOT NULL,
                        multi_select INTEGER NOT NULL CHECK (multi_select IN (0, 1)),
                        PRIMARY KEY (occurrence_id, question_index)
                    )
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE sessions_provider_question_option (
                        occurrence_id TEXT NOT NULL, question_index INTEGER NOT NULL,
                        option_index INTEGER NOT NULL, label TEXT NOT NULL, description TEXT NOT NULL,
                        PRIMARY KEY (occurrence_id, question_index, option_index),
                        FOREIGN KEY (occurrence_id, question_index)
                            REFERENCES sessions_provider_question(occurrence_id, question_index) ON DELETE CASCADE
                    )
                    """)
        }
    }

    static func registerSessionsPermissionHandling(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("026_sessions_permission_handling") { database in
            try database.execute(sql: "ALTER TABLE sessions_evidence ADD COLUMN permission_handling TEXT")
        }
    }

    private static let sessionsSchemaStatements: [String] = [
        """
        CREATE TABLE sessions_conversation (
            id TEXT PRIMARY KEY,
            provider_identifier TEXT NOT NULL,
            provider_conversation_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_reported_at REAL NOT NULL,
            UNIQUE (provider_identifier, provider_conversation_id)
        );
        """,
        """
        CREATE INDEX idx_sessions_conversation_recent
        ON sessions_conversation(last_reported_at DESC, id ASC);
        """,
        """
        CREATE TABLE sessions_operation (
            commit_revision INTEGER PRIMARY KEY AUTOINCREMENT,
            operation_scope TEXT NOT NULL,
            correlation_id TEXT NOT NULL,
            operation_kind TEXT NOT NULL CHECK (operation_kind IN (
                'bind',
                'message',
                'evidence',
                'deliberateNeedsYou',
                'clearDeliberateNeedsYou',
                'deliberateDone',
                'sourceEnded',
                'messageAcknowledgment',
                'prepareForLaunch',
                'loss'
            )),
            semantic_fingerprint TEXT NOT NULL,
            outcome_kind TEXT NOT NULL,
            outcome_entity_id TEXT,
            outcome_occurrence_id TEXT,
            binding_generation_id TEXT,
            created_at REAL NOT NULL,
            UNIQUE (operation_scope, correlation_id)
        );
        """,
        """
        CREATE INDEX idx_sessions_operation_correlation
        ON sessions_operation(correlation_id, operation_scope);
        """,
        """
        CREATE TABLE sessions_pane_binding (
            binding_generation_id TEXT PRIMARY KEY,
            pane_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL
                REFERENCES sessions_conversation(id) ON DELETE RESTRICT,
            source_generation_id TEXT NOT NULL,
            origin TEXT NOT NULL CHECK (origin IN ('reported', 'agentReported')),
            status TEXT NOT NULL CHECK (status IN ('active', 'ended')),
            transition_occurrence_id TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            committed_revision INTEGER NOT NULL
                REFERENCES sessions_operation(commit_revision) ON DELETE RESTRICT,
            CHECK (
                (status = 'active' AND ended_at IS NULL)
                OR (status = 'ended' AND ended_at IS NOT NULL)
            )
        );
        """,
        """
        CREATE UNIQUE INDEX idx_sessions_pane_binding_one_active_per_pane
        ON sessions_pane_binding(pane_id)
        WHERE status = 'active';
        """,
        """
        CREATE INDEX idx_sessions_pane_binding_conversation_history
        ON sessions_pane_binding(conversation_id, started_at DESC, binding_generation_id ASC);
        """,
        """
        CREATE TABLE sessions_source (
            id TEXT PRIMARY KEY,
            binding_generation_id TEXT NOT NULL
                REFERENCES sessions_pane_binding(binding_generation_id) ON DELETE RESTRICT,
            source_identifier TEXT NOT NULL,
            source_generation_id TEXT NOT NULL UNIQUE,
            provider_identifier TEXT NOT NULL,
            provider_version TEXT NOT NULL,
            provider_mode TEXT NOT NULL,
            qualification TEXT NOT NULL CHECK (qualification IN (
                'qualified', 'unverified', 'unavailable'
            )),
            status TEXT NOT NULL CHECK (status IN ('active', 'ended', 'lost')),
            last_cursor TEXT,
            started_at REAL NOT NULL,
            ended_at REAL,
            committed_revision INTEGER NOT NULL
                REFERENCES sessions_operation(commit_revision) ON DELETE RESTRICT,
            CHECK (
                (status = 'active' AND ended_at IS NULL)
                OR (status IN ('ended', 'lost') AND ended_at IS NOT NULL)
            )
        );
        """,
        """
        CREATE INDEX idx_sessions_source_binding_status
        ON sessions_source(binding_generation_id, status, started_at DESC);
        """,
        """
        CREATE TABLE sessions_attention (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL
                REFERENCES sessions_conversation(id) ON DELETE RESTRICT,
            binding_generation_id TEXT NOT NULL
                REFERENCES sessions_pane_binding(binding_generation_id) ON DELETE RESTRICT,
            source_id TEXT
                REFERENCES sessions_source(id) ON DELETE RESTRICT,
            source_generation_id TEXT NOT NULL,
            source_kind TEXT NOT NULL CHECK (source_kind IN ('provider', 'deliberate')),
            turn_id TEXT,
            subject_key TEXT NOT NULL,
            request_id TEXT NOT NULL,
            attention_kind TEXT NOT NULL CHECK (attention_kind IN (
                'permission', 'question', 'elicitation', 'deliberate'
            )),
            origin TEXT NOT NULL CHECK (origin IN ('reported', 'agentReported', 'estimated')),
            freshness TEXT NOT NULL CHECK (freshness IN ('live', 'late', 'historical')),
            explanation_text TEXT,
            disposition TEXT NOT NULL CHECK (disposition IN ('current', 'resolved', 'stale')),
            opened_occurrence_id TEXT NOT NULL,
            resolution_occurrence_id TEXT,
            opened_at REAL NOT NULL,
            resolved_at REAL,
            committed_revision INTEGER NOT NULL
                REFERENCES sessions_operation(commit_revision) ON DELETE RESTRICT,
            CHECK (
                (disposition = 'current' AND resolved_at IS NULL AND resolution_occurrence_id IS NULL)
                OR (disposition IN ('resolved', 'stale'))
            )
        );
        """,
        """
        CREATE UNIQUE INDEX idx_sessions_attention_request_context
        ON sessions_attention(
            binding_generation_id,
            source_generation_id,
            (turn_id IS NULL),
            IFNULL(turn_id, ''),
            subject_key,
            request_id
        );
        """,
        """
        CREATE UNIQUE INDEX idx_sessions_attention_one_current_deliberate
        ON sessions_attention(conversation_id, binding_generation_id)
        WHERE source_kind = 'deliberate' AND disposition = 'current';
        """,
        """
        CREATE INDEX idx_sessions_attention_current
        ON sessions_attention(conversation_id, disposition, opened_at DESC);
        """,
        """
        CREATE TABLE sessions_message (
            occurrence_id TEXT PRIMARY KEY,
            pane_id TEXT NOT NULL,
            conversation_id TEXT
                REFERENCES sessions_conversation(id) ON DELETE RESTRICT,
            binding_generation_id TEXT
                REFERENCES sessions_pane_binding(binding_generation_id) ON DELETE RESTRICT,
            source_generation_id TEXT,
            notification_kind TEXT NOT NULL CHECK (notification_kind IN (
                'message', 'needsYou', 'done'
            )),
            exact_text TEXT,
            attribution TEXT NOT NULL CHECK (attribution IN ('attributed', 'unattributed')),
            freshness TEXT NOT NULL CHECK (freshness IN ('live', 'late', 'historical')),
            attention_id TEXT
                REFERENCES sessions_attention(id) ON DELETE RESTRICT,
            is_seen INTEGER NOT NULL DEFAULT 0 CHECK (is_seen IN (0, 1)),
            seen_at REAL,
            reported_at REAL NOT NULL,
            committed_revision INTEGER NOT NULL
                REFERENCES sessions_operation(commit_revision) ON DELETE RESTRICT,
            CHECK (
                (attribution = 'attributed' AND conversation_id IS NOT NULL AND binding_generation_id IS NOT NULL)
                OR (attribution = 'unattributed' AND conversation_id IS NULL AND binding_generation_id IS NULL)
            ),
            CHECK (
                (notification_kind IN ('message', 'needsYou') AND exact_text IS NOT NULL)
                OR (notification_kind = 'done' AND exact_text IS NULL)
            ),
            CHECK ((is_seen = 0 AND seen_at IS NULL) OR (is_seen = 1 AND seen_at IS NOT NULL))
        );
        """,
        """
        CREATE INDEX idx_sessions_message_conversation_page
        ON sessions_message(conversation_id, reported_at DESC, occurrence_id ASC);
        """,
        """
        CREATE INDEX idx_sessions_message_unattributed_page
        ON sessions_message(attribution, reported_at DESC, occurrence_id ASC)
        WHERE attribution = 'unattributed';
        """,
        """
        CREATE INDEX idx_sessions_message_unseen
        ON sessions_message(conversation_id, reported_at DESC)
        WHERE is_seen = 0;
        """,
        """
        CREATE TABLE sessions_evidence (
            occurrence_id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL
                REFERENCES sessions_conversation(id) ON DELETE RESTRICT,
            binding_generation_id TEXT NOT NULL
                REFERENCES sessions_pane_binding(binding_generation_id) ON DELETE RESTRICT,
            source_id TEXT
                REFERENCES sessions_source(id) ON DELETE RESTRICT,
            source_generation_id TEXT NOT NULL,
            turn_id TEXT,
            subject_kind TEXT NOT NULL CHECK (subject_kind IN ('root', 'tool', 'subagent')),
            subject_identifier TEXT,
            evidence_kind TEXT NOT NULL CHECK (evidence_kind IN (
                'activityStarted',
                'completed',
                'aborted',
                'needsYouOpened',
                'needsYouResolved'
            )),
            attention_id TEXT
                REFERENCES sessions_attention(id) ON DELETE RESTRICT,
            origin TEXT NOT NULL CHECK (origin IN ('reported', 'agentReported', 'estimated')),
            freshness TEXT NOT NULL CHECK (freshness IN ('live', 'late', 'historical')),
            occurred_at REAL NOT NULL,
            committed_revision INTEGER NOT NULL
                REFERENCES sessions_operation(commit_revision) ON DELETE RESTRICT,
            CHECK (
                (subject_kind = 'root' AND subject_identifier IS NULL)
                OR (subject_kind IN ('tool', 'subagent') AND subject_identifier IS NOT NULL)
            )
        );
        """,
        """
        CREATE INDEX idx_sessions_evidence_reduction
        ON sessions_evidence(
            conversation_id,
            binding_generation_id,
            turn_id,
            occurred_at,
            occurrence_id
        );
        """,
        """
        CREATE TABLE sessions_result (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL
                REFERENCES sessions_conversation(id) ON DELETE RESTRICT,
            binding_generation_id TEXT NOT NULL
                REFERENCES sessions_pane_binding(binding_generation_id) ON DELETE RESTRICT,
            source_id TEXT
                REFERENCES sessions_source(id) ON DELETE RESTRICT,
            source_generation_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            subject_key TEXT NOT NULL,
            completion_occurrence_id TEXT NOT NULL,
            origin TEXT NOT NULL CHECK (origin IN ('reported', 'agentReported', 'estimated')),
            freshness TEXT NOT NULL CHECK (freshness IN ('live', 'late', 'historical')),
            is_seen INTEGER NOT NULL DEFAULT 0 CHECK (is_seen IN (0, 1)),
            seen_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            committed_revision INTEGER NOT NULL
                REFERENCES sessions_operation(commit_revision) ON DELETE RESTRICT,
            UNIQUE (binding_generation_id, turn_id, subject_key),
            CHECK ((is_seen = 0 AND seen_at IS NULL) OR (is_seen = 1 AND seen_at IS NOT NULL))
        );
        """,
        """
        CREATE INDEX idx_sessions_result_conversation_page
        ON sessions_result(conversation_id, updated_at DESC, id ASC);
        """,
        """
        CREATE TABLE sessions_loss (
            id TEXT PRIMARY KEY,
            pane_id TEXT NOT NULL,
            conversation_id TEXT
                REFERENCES sessions_conversation(id) ON DELETE RESTRICT,
            binding_generation_id TEXT,
            source_generation_id TEXT,
            provider_identifier TEXT,
            event_kind TEXT NOT NULL,
            outcome_kind TEXT NOT NULL CHECK (outcome_kind IN ('throttled', 'rejected')),
            reason_code TEXT NOT NULL CHECK (reason_code IN ('paneQueueFull', 'globalQueueFull')),
            lost_count INTEGER NOT NULL CHECK (lost_count > 0),
            occurred_at REAL NOT NULL,
            committed_revision INTEGER NOT NULL
                REFERENCES sessions_operation(commit_revision) ON DELETE RESTRICT
        );
        """,
        """
        CREATE INDEX idx_sessions_loss_recent
        ON sessions_loss(occurred_at DESC, id ASC);
        """,
    ]
}
