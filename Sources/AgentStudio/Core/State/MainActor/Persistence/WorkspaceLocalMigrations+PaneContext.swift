import GRDB

extension WorkspaceLocalMigrations {
    static func registerPaneContextSchema(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("021_pane_context_current_values") { database in
            try createCurrentValueTables(in: database)
        }
        migrator.registerMigration("022_pane_context_messages") { database in
            try createMessageTables(in: database)
            try createAskFormTables(in: database)
            try createAskAnswerTable(in: database)
        }
        migrator.registerMigration("023_pane_context_write_order") { database in
            try createWriteOrderTables(in: database)
        }
        migrator.registerMigration("024_pane_context_answer_positions") { database in
            try createAnswerPositionTable(in: database)
        }
        migrator.registerMigration("025_pane_context_retirement") { database in
            try createRetirementTable(in: database)
        }
    }

    private static func createCurrentValueTables(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE pane_state (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, pane_id TEXT NOT NULL,
                    writer_kind TEXT, writer_pane_id TEXT, writer_provider TEXT,
                    writer_session_ref TEXT, writer_binding_generation TEXT,
                    write_epoch INTEGER, write_counter TEXT, updated_at INTEGER,
                    title TEXT, summary TEXT, work_kind TEXT, work_text TEXT,
                    step_current INTEGER, step_total INTEGER, detail TEXT, expires_at INTEGER,
                    stale INTEGER NOT NULL DEFAULT 0 CHECK (stale IN (0, 1)),
                    detail_revision INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (pane_id, kind)
                )
                """)
        try database.execute(sql: actionTable("pane_state_action", parent: "pane_state"))
    }

    private static func createMessageTables(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE pane_request (
                    id TEXT PRIMARY KEY, pane_id TEXT NOT NULL, message_id TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    sender_kind TEXT NOT NULL, sender_pane_id TEXT, sender_provider TEXT,
                    sender_session_ref TEXT, sender_binding_generation TEXT,
                    importance TEXT NOT NULL, body TEXT NOT NULL, why TEXT,
                    sent_at INTEGER NOT NULL, source_occurred_at INTEGER, intent_source_occurred_at INTEGER,
                    reason TEXT NOT NULL, form_kind TEXT NOT NULL, placeholder TEXT,
                    allows_multiple INTEGER NOT NULL DEFAULT 0 CHECK (allows_multiple IN (0, 1)),
                    waiting TEXT NOT NULL, deadline INTEGER, state TEXT NOT NULL,
                    answered_by TEXT, answered_at INTEGER, answer_kind TEXT, answer_text TEXT,
                    answer_position INTEGER, receipt TEXT, receipt_at INTEGER,
                    settled_at INTEGER,
                    display_hidden INTEGER NOT NULL DEFAULT 0 CHECK (display_hidden IN (0, 1)),
                    UNIQUE (pane_id, message_id)
                )
                """)
        try database.execute(
            sql: """
                CREATE TABLE pane_event (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, pane_id TEXT NOT NULL,
                    position INTEGER NOT NULL, message_id TEXT, subject_id TEXT NOT NULL,
                    sender_kind TEXT NOT NULL, sender_pane_id TEXT, sender_provider TEXT,
                    sender_session_ref TEXT, sender_binding_generation TEXT,
                    importance TEXT, body TEXT, why TEXT, notice_state TEXT,
                    sent_at INTEGER NOT NULL, source_occurred_at INTEGER, intent_source_occurred_at INTEGER, settled_at INTEGER,
                    display_hidden INTEGER NOT NULL DEFAULT 0 CHECK (display_hidden IN (0, 1)),
                    UNIQUE (pane_id, position)
                )
                """)
        try database.execute(
            sql:
                "CREATE UNIQUE INDEX pane_event_notice_identity ON pane_event(pane_id, message_id) WHERE kind = 'notice'"
        )
        try database.execute(sql: actionTable("pane_request_action", parent: "pane_request"))
        try database.execute(sql: actionTable("pane_event_action", parent: "pane_event"))
    }

    private static func createAskFormTables(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE pane_request_choice (
                    request_id TEXT NOT NULL REFERENCES pane_request(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL, choice_id TEXT NOT NULL, label TEXT NOT NULL,
                    PRIMARY KEY (request_id, ordinal)
                )
                """)
        try database.execute(
            sql: """
                CREATE TABLE pane_request_property (
                    request_id TEXT NOT NULL REFERENCES pane_request(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL, name TEXT NOT NULL, title TEXT, description TEXT,
                    property_kind TEXT NOT NULL, min_length INTEGER, max_length INTEGER, format TEXT,
                    minimum TEXT, maximum TEXT,
                    enum_present INTEGER NOT NULL DEFAULT 0 CHECK (enum_present IN (0, 1)),
                    PRIMARY KEY (request_id, ordinal)
                )
                """)
        try database.execute(
            sql: """
                CREATE TABLE pane_request_required (
                    request_id TEXT NOT NULL REFERENCES pane_request(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL, name TEXT NOT NULL,
                    PRIMARY KEY (request_id, ordinal)
                )
                """)
        try database.execute(
            sql: """
                CREATE TABLE pane_request_property_choice (
                    request_id TEXT NOT NULL, property_ordinal INTEGER NOT NULL,
                    ordinal INTEGER NOT NULL, value TEXT NOT NULL,
                    PRIMARY KEY (request_id, property_ordinal, ordinal),
                    FOREIGN KEY (request_id, property_ordinal)
                        REFERENCES pane_request_property(request_id, ordinal) ON DELETE CASCADE
                )
                """)
    }

    private static func createAskAnswerTable(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE pane_request_answer_value (
                    request_id TEXT NOT NULL REFERENCES pane_request(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL, field_name TEXT, value_kind TEXT NOT NULL,
                    text_value TEXT, integer_value INTEGER,
                    PRIMARY KEY (request_id, ordinal)
                )
                """)
    }

    private static func createWriteOrderTables(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE pane_write_order (
                    pane_id TEXT NOT NULL, writer_key TEXT NOT NULL, stream TEXT NOT NULL,
                    current_epoch INTEGER NOT NULL, last_counter TEXT NOT NULL,
                    PRIMARY KEY (pane_id, writer_key, stream)
                )
                """)
        try database.execute(
            sql: """
                CREATE TABLE pane_epoch_claim (
                    claim_id TEXT PRIMARY KEY, pane_id TEXT NOT NULL, writer_key TEXT NOT NULL,
                    stream TEXT NOT NULL, epoch INTEGER NOT NULL, claimed_at INTEGER NOT NULL
                )
                """)
    }

    private static func createAnswerPositionTable(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE pane_answer_position (
                    pane_id TEXT NOT NULL, session_ref TEXT NOT NULL,
                    last_reported_position INTEGER NOT NULL DEFAULT 0,
                    ask_sequence INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (pane_id, session_ref)
                )
                """)
    }

    private static func createRetirementTable(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE pane_retirement (
                    pane_id TEXT PRIMARY KEY, retired_at INTEGER NOT NULL, purge_after INTEGER NOT NULL
                )
                """)
    }

    private static func actionTable(_ name: String, parent: String) -> String {
        """
        CREATE TABLE \(name) (
            parent_id TEXT NOT NULL REFERENCES \(parent)(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL, kind TEXT NOT NULL, path TEXT, line INTEGER,
            host TEXT, owner TEXT, repository TEXT, number INTEGER, target_pane_id TEXT,
            PRIMARY KEY (parent_id, ordinal)
        )
        """
    }
}
