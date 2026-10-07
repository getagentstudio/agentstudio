import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("IPC credential local schema migration")
struct WorkspaceLocalIPCCredentialMigrationTests {
    @Test("IPC credential migrations preserve initialized local data")
    func credentialMigrationsPreserveInitializedLocalData() throws {
        let database = try SQLiteDatabaseFactory.makeInMemoryQueue(
            label: "AgentStudio.sqlite.ipc-credential-migration"
        )
        try WorkspaceLocalMigrations.migrator.migrate(
            database,
            upTo: "011_create_sessions_ingestion_schema"
        )
        try seedPreIPCCredentialMigrationData(database)

        try WorkspaceLocalMigrations.migrate(database)
        try WorkspaceLocalMigrations.migrate(database)

        try database.read { connection in
            let completedMigrations = try WorkspaceLocalMigrations.migrator.completedMigrations(connection)
            #expect(completedMigrations.last == "019_create_pane_context_cli_outbox_cursor")
            for identifier in [
                "012_create_ipc_credential_schema",
                "013_create_opaque_pane_credential_records",
                "014_ipc_credentials_pane_only",
            ] {
                #expect(completedMigrations.filter { $0 == identifier }.count == 1)
            }
            #expect(try connection.tableExists("local_ipc_credential"))
            #expect(
                try String.fetchOne(
                    connection,
                    sql: "SELECT filter_text FROM local_window_state WHERE window_id = 'retained-window'"
                ) == "retained filter"
            )
            #expect(
                try String.fetchOne(
                    connection,
                    sql: "SELECT title FROM local_notification_inbox_item WHERE id = 'retained-inbox-item'"
                ) == "Retained Inbox Item"
            )
            #expect(
                try String.fetchOne(
                    connection,
                    sql: "SELECT provider_conversation_id FROM sessions_conversation WHERE id = 'retained-conversation'"
                ) == "provider-conversation"
            )
            #expect(
                try String.fetchOne(
                    connection,
                    sql: "SELECT outcome_kind FROM sessions_operation WHERE correlation_id = 'retained-correlation'"
                ) == "retainedOutcome"
            )
            #expect(try String.fetchAll(connection, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test("the credential schema stores pane verifiers and nothing runtime-scoped")
    func credentialSchemaKeepsOnlyPaneColumns() throws {
        let database = try migratedIPCCredentialDatabase()

        try database.write { connection in
            let columns = try Row.fetchAll(
                connection,
                sql: "PRAGMA table_info(local_ipc_credential)"
            ).map { $0["name"] as String }
            #expect(
                columns == [
                    "pane_id", "workspace_id", "credential_record_id", "verifier_sha256", "status",
                ]
            )
            let indexNames = try String.fetchAll(
                connection,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'local_ipc_credential'"
            )
            #expect(indexNames == ["idx_local_ipc_credential_pane_record"])

            try insertPaneCredential(connection, verifier: Data(repeating: 0xA5, count: 32))
            let verifierStorage = try #require(
                try Row.fetchOne(
                    connection,
                    sql: """
                        SELECT typeof(verifier_sha256) AS storage_type,
                            length(verifier_sha256) AS byte_count
                        FROM local_ipc_credential
                        """
                )
            )
            #expect(verifierStorage["storage_type"] as String == "blob")
            #expect(verifierStorage["byte_count"] as Int == 32)
        }
    }

    @Test("credential verifier requires a 32 byte SQLite blob")
    func credentialVerifierRejectsTextAndShortBlob() throws {
        let database = try migratedIPCCredentialDatabase()

        try database.write { connection in
            expectCredentialConstraintFailure {
                try insertPaneCredential(connection, verifierSQL: "'12345678901234567890123456789012'")
            }
            expectCredentialConstraintFailure {
                try insertPaneCredential(connection, verifier: Data(repeating: 0xA5, count: 31))
            }
        }
    }

    @Test("credential status accepts only the pane lifecycle")
    func credentialStatusAcceptsOnlyFiniteLifecycle() throws {
        let database = try migratedIPCCredentialDatabase()

        try database.write { connection in
            for status in ["registered", "revoked"] {
                try insertPaneCredential(
                    connection,
                    paneID: "pane-\(status)",
                    credentialRecordID: "record-\(status)",
                    verifier: Data(repeating: 0xA5, count: 32),
                    status: status
                )
            }
            expectCredentialConstraintFailure {
                try insertPaneCredential(
                    connection,
                    paneID: "pane-unknown",
                    credentialRecordID: "record-unknown",
                    status: "future"
                )
            }
            for missingColumn in ["pane_id", "workspace_id", "credential_record_id"] {
                expectCredentialConstraintFailure(containing: "NOT NULL constraint failed") {
                    try insertPaneCredentialWithNullColumn(connection, column: missingColumn)
                }
            }
        }
    }

    @Test("pane uniqueness uses the opaque record while distinct same-pane records coexist")
    func credentialUniquenessUsesOpaqueRecordIdentity() throws {
        let database = try migratedIPCCredentialDatabase()

        try database.write { connection in
            try insertPaneCredential(connection, workspaceID: "workspace-1")
            expectCredentialConstraintFailure(containing: "UNIQUE constraint failed") {
                try insertPaneCredential(connection, workspaceID: "workspace-2")
            }
            try insertPaneCredential(connection, credentialRecordID: "second-record")
            #expect(
                try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM local_ipc_credential") == 2
            )
        }
    }

    @Test("migration 014 keeps every pane row byte-for-byte and drops diagnostic rows")
    func migration014DropsDiagnosticRowsAndPreservesPaneRows() throws {
        let database = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "AgentStudio.sqlite.ipc-014")
        try WorkspaceLocalMigrations.migrator.migrate(
            database,
            upTo: "013_create_opaque_pane_credential_records"
        )
        let paneVerifiers = [Data(repeating: 0x01, count: 32), Data(repeating: 0x02, count: 32)]
        try database.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO local_ipc_credential VALUES
                    ('pane', 'pane-a', 'workspace-a', NULL, 'record-registered', NULL, ?, 'registered'),
                    ('pane', 'pane-b', 'workspace-a', NULL, 'record-revoked', NULL, ?, 'revoked'),
                    ('diagnostic', NULL, NULL, 'runtime-a', NULL, 'generation-a', ?, 'active')
                    """,
                arguments: StatementArguments(paneVerifiers + [Data(repeating: 0x03, count: 32)])
            )
        }

        try WorkspaceLocalMigrations.migrate(database)

        try database.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: """
                    SELECT pane_id, workspace_id, credential_record_id, verifier_sha256, status
                    FROM local_ipc_credential ORDER BY verifier_sha256
                    """
            )
            #expect(rows.count == 2)
            #expect(rows.map { $0["pane_id"] as String } == ["pane-a", "pane-b"])
            #expect(rows.map { $0["workspace_id"] as String } == ["workspace-a", "workspace-a"])
            #expect(
                rows.map { $0["credential_record_id"] as String } == ["record-registered", "record-revoked"]
            )
            #expect(rows.map { $0["verifier_sha256"] as Data } == paneVerifiers)
            #expect(rows.map { $0["status"] as String } == ["registered", "revoked"])
            #expect(
                try String.fetchAll(
                    connection,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'local_ipc_credential'"
                ) == ["idx_local_ipc_credential_pane_record"]
            )
            #expect(try !connection.tableExists("local_ipc_credential_013"))
        }
    }
}

private func seedPreIPCCredentialMigrationData(_ database: DatabaseQueue) throws {
    try database.write { connection in
        #expect(try !connection.tableExists("local_ipc_credential"))
        try connection.execute(
            sql: """
                INSERT INTO local_window_state(
                    window_id, window_role, sidebar_width, window_frame_json,
                    filter_text, is_filter_visible, sidebar_collapsed,
                    sidebar_surface, updated_at
                ) VALUES ('retained-window', 'main', 280, NULL, 'retained filter', 1, 0, 'repos', 10)
                """
        )
        try connection.execute(
            sql: """
                INSERT INTO local_notification_inbox_item(
                    workspace_id, id, timestamp, kind, title, source_kind,
                    is_read, is_dismissed_from_pane_inbox
                ) VALUES (
                    'retained-workspace', 'retained-inbox-item', 11,
                    'agentActivity', 'Retained Inbox Item', 'pane', 0, 0
                )
                """
        )
        try connection.execute(
            sql: """
                INSERT INTO sessions_conversation(
                    id, provider_identifier, provider_conversation_id,
                    created_at, last_reported_at
                ) VALUES (
                    'retained-conversation', 'fixture-provider',
                    'provider-conversation', 12, 13
                )
                """
        )
        try connection.execute(
            sql: """
                INSERT INTO sessions_operation(
                    operation_scope, correlation_id, operation_kind,
                    semantic_fingerprint, outcome_kind, created_at
                ) VALUES (
                    'retained-scope', 'retained-correlation', 'prepareForLaunch',
                    'retained-fingerprint', 'retainedOutcome', 14
                )
                """
        )
    }
}

private func migratedIPCCredentialDatabase() throws -> DatabaseQueue {
    let database = try SQLiteDatabaseFactory.makeInMemoryQueue(
        label: "AgentStudio.sqlite.ipc-credential-schema"
    )
    try WorkspaceLocalMigrations.migrate(database)
    return database
}

private func insertPaneCredential(
    _ database: Database,
    paneID: String = "pane-1",
    workspaceID: String = "workspace-1",
    credentialRecordID: String = "shared-record",
    verifier: Data = Data(repeating: 0xA5, count: 32),
    status: String = "registered"
) throws {
    try database.execute(
        sql: """
            INSERT INTO local_ipc_credential(
                pane_id, workspace_id, credential_record_id, verifier_sha256, status
            ) VALUES (?, ?, ?, ?, ?)
            """,
        arguments: [paneID, workspaceID, credentialRecordID, verifier, status]
    )
}

private func insertPaneCredential(_ database: Database, verifierSQL: String) throws {
    try database.execute(
        sql: """
            INSERT INTO local_ipc_credential(
                pane_id, workspace_id, credential_record_id, verifier_sha256, status
            ) VALUES ('pane-1', 'workspace-1', 'text-verifier-record', \(verifierSQL), 'registered')
            """
    )
}

private func insertPaneCredentialWithNullColumn(_ database: Database, column: String) throws {
    let paneID: String? = column == "pane_id" ? nil : "pane-null-\(column)"
    let workspaceID: String? = column == "workspace_id" ? nil : "workspace-1"
    let credentialRecordID: String? = column == "credential_record_id" ? nil : "record-null-\(column)"
    try database.execute(
        sql: """
            INSERT INTO local_ipc_credential(
                pane_id, workspace_id, credential_record_id, verifier_sha256, status
            ) VALUES (?, ?, ?, ?, 'registered')
            """,
        arguments: [paneID, workspaceID, credentialRecordID, Data(repeating: 0xC3, count: 32)]
    )
}

private func expectCredentialConstraintFailure(
    containing expectedMessage: String = "CHECK constraint failed",
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected credential schema constraint failure")
    } catch let error as DatabaseError {
        #expect(error.message?.contains(expectedMessage) == true)
    } catch {
        Issue.record("Expected SQLite constraint failure, received \(type(of: error))")
    }
}
