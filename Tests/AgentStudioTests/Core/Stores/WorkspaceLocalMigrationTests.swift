import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("WorkspaceLocalMigrationTests")
struct WorkspaceLocalMigrationTests {
    @Test("drawer visibility migration shows drawers for an existing main window")
    func drawerVisibilityMigrationDefaultsExistingWindowToShown() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.bootRequiredMigrator.migrate(
            databaseQueue,
            upTo: "007_add_per_screen_sidebar_organization"
        )
        let windowId = UUIDv7.generate().uuidString
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_window_state(
                        window_id, window_role, sidebar_width, filter_text,
                        is_filter_visible, sidebar_collapsed, sidebar_surface, updated_at
                    ) VALUES (?, 'main', 250, '', 0, 0, 'panes', 1)
                    """,
                arguments: [windowId]
            )
        }

        try WorkspaceLocalMigrations.migrateBootRequired(databaseQueue)

        let showsDrawers = try databaseQueue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT panes_shows_drawers FROM local_window_state WHERE window_id = ?",
                arguments: [windowId]
            )
        }
        #expect(showsDrawers == 1)
    }

    @Test("boot-required migrations exclude optional Sessions and IPC schemas")
    func bootRequiredMigrationsExcludeOptionalSchemas() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()

        try WorkspaceLocalMigrations.migrateBootRequired(databaseQueue)

        let result = try databaseQueue.read { database in
            (
                try WorkspaceLocalMigrations.bootRequiredMigrator.completedMigrations(database),
                try database.tableExists("sessions_conversation"),
                try database.tableExists("local_ipc_credential")
            )
        }
        #expect(result.0 == expectedBootRequiredLocalMigrationIdentifiers)
        #expect(!result.1)
        #expect(!result.2)
    }

    @Test("boot-required subset tolerates applied optional migrations without changing data")
    func bootRequiredSubsetToleratesAppliedOptionalMigrations() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        let preservedWorkspaceID = UUIDv7.generate().uuidString
        try databaseQueue.write { database in
            try database.execute(
                sql: "INSERT INTO local_workspace_cursor(workspace_id, updated_at) VALUES (?, 1)",
                arguments: [preservedWorkspaceID]
            )
        }

        try WorkspaceLocalMigrations.migrateBootRequired(databaseQueue)

        let result = try databaseQueue.read { database in
            (
                try WorkspaceLocalMigrations.migrator.completedMigrations(database),
                try String.fetchOne(database, sql: "SELECT workspace_id FROM local_workspace_cursor")
            )
        }
        #expect(result.0 == expectedFullLocalMigrationIdentifiers)
        #expect(result.1 == preservedWorkspaceID)
    }

    @Test("fresh local database creates exactly the clean product schema")
    func freshLocalDatabaseCreatesExactlyTheCleanProductSchema() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()

        try WorkspaceLocalMigrations.migrate(databaseQueue)

        let tableNames = try databaseQueue.read { database in
            try Set(
                String.fetchAll(
                    database,
                    sql: """
                        SELECT name
                        FROM sqlite_master
                        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                        """
                )
            )
        }
        let expectedTableNames: Set<String> = [
            "local_workspace_cursor",
            "local_tab_cursor",
            "local_arrangement_cursor",
            "local_drawer_cursor",
            "local_arrangement_drawer_cursor",
            "local_window_state",
            "local_window_sidebar_collapsed_group",
            "local_entity_recency",
            "local_workspace_entity_recency",
            "local_repository_activity",
            "local_repository_activity_cursor",
            "local_notification_inbox_collapsed_group",
            "local_notification_inbox_item",
            "local_editor_preferences",
            "local_repo_explorer_preferences",
            "local_inbox_notification_preferences",
            "cache_metadata",
            "cache_repo_enrichment",
            "cache_worktree_enrichment",
            "annotation_session",
            "annotation_thread",
            "annotation_message",
            "annotation_message_draft",
            "annotation_output_attempt",
            "annotation_output_attempt_message",
            "annotation_output_event",
            "local_recovery_provenance",
            "sessions_conversation",
            "sessions_pane_binding",
            "sessions_source",
            "sessions_evidence",
            "sessions_message",
            "sessions_attention",
            "sessions_result",
            "sessions_operation",
            "sessions_loss",
            "local_ipc_credential",
            "pane_context_cli_outbox_cursor",
            "local_drawer_presentation",
        ]

        #expect(tableNames == expectedTableNames)
        #expect(!tableNames.contains("local_persistence_lane_marker"))
        #expect(!tableNames.contains("local_workspace_sqlite_snapshot_status"))
        #expect(!tableNames.contains("cache_notification_count"))
    }

    @Test("clean local schema includes the collapsed sidebar group hard cut")
    func cleanLocalSchemaIncludesCollapsedSidebarGroupHardCut() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()

        try WorkspaceLocalMigrations.migrate(databaseQueue)
        try WorkspaceLocalMigrations.migrate(databaseQueue)

        let completedMigrations = try databaseQueue.read { database in
            try WorkspaceLocalMigrations.migrator.completedMigrations(database)
        }

        #expect(completedMigrations == expectedFullLocalMigrationIdentifiers)
    }

    @Test("repository activity migration stores facts and one checked boolean only")
    func repositoryActivityMigrationStoresFactsAndOneCheckedBooleanOnly() throws {
        // Arrange
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()

        // Act
        try WorkspaceLocalMigrations.migrate(databaseQueue)

        // Assert
        let schema = try databaseQueue.read { database in
            let tableSQL = try Row.fetchAll(
                database,
                sql: """
                    SELECT name, sql
                    FROM sqlite_master
                    WHERE type = 'table'
                      AND name IN ('local_repository_activity', 'local_repository_activity_cursor')
                    ORDER BY name
                    """
            ).reduce(into: [String: String]()) { result, row in
                result[row["name"] as String] = row["sql"] as String
            }
            let columnsByTable = try Dictionary(
                uniqueKeysWithValues: tableSQL.keys.map { tableName in
                    let columns = try Row.fetchAll(
                        database,
                        sql: "PRAGMA table_info(\(tableName))"
                    ).map { row in
                        "\(row["name"] as String):\(row["type"] as String)"
                    }
                    return (tableName, columns)
                }
            )
            return (tableSQL, columnsByTable)
        }

        #expect(
            schema.1["local_repository_activity"]
                == [
                    "repository_stable_key:TEXT",
                    "last_qualifying_activity_at:REAL",
                    "continuous_coverage_started_at:REAL",
                    "updated_at:REAL",
                    "owned_promotion_attempt_id:TEXT",
                    "owned_promotion_started_at:REAL",
                    "owned_promotion_unsettled:INTEGER",
                ]
        )
        #expect(
            schema.1["local_repository_activity_cursor"]
                == [
                    "volume_identifier:TEXT",
                    "last_event_id:INTEGER",
                    "updated_at:REAL",
                ]
        )
        let activitySQL = schema.0["local_repository_activity"] ?? ""
        let cursorSQL = schema.0["local_repository_activity_cursor"] ?? ""
        #expect(activitySQL.contains("CHECK (owned_promotion_unsettled IN (0, 1))"))
        #expect(activitySQL.components(separatedBy: "CHECK (").count - 1 == 1)
        #expect(!cursorSQL.contains("CHECK ("))
        #expect(!activitySQL.contains(" state "))
        #expect(!activitySQL.contains(" status "))
        #expect(!activitySQL.contains(" disposition "))
        #expect(!cursorSQL.contains(" state "))
        #expect(!cursorSQL.contains(" status "))
        #expect(!cursorSQL.contains(" disposition "))
    }

    @Test("repository activity migration preserves a nonempty pre-006 local database")
    func repositoryActivityMigrationPreservesNonemptyPre006Database() throws {
        // Arrange
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "005_move_repo_grouping_to_window_sidebar_memory"
        )
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_entity_recency(
                        entity_kind, entity_key, interaction_kind, last_interacted_at
                    ) VALUES ('repository', 'aaaaaaaaaaaaaaaa', 'opened', 100)
                    """
            )
        }

        // Act
        try WorkspaceLocalMigrations.migrate(databaseQueue)

        // Assert
        let state = try databaseQueue.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM local_entity_recency"),
                try database.tableExists("local_repository_activity"),
                try database.tableExists("local_repository_activity_cursor")
            )
        }
        #expect(state.0 == 1)
        #expect(state.1)
        #expect(state.2)
    }

    @Test("per-screen grouping belongs only to main-window sidebar memory")
    func perScreenGroupingBelongsOnlyToMainWindowSidebarMemory() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()

        try WorkspaceLocalMigrations.migrate(databaseQueue)

        let columnNamesByTable = try databaseQueue.read { database in
            try Dictionary(
                uniqueKeysWithValues: ["local_window_state", "local_repo_explorer_preferences"].map { tableName in
                    let columnNames = try Row.fetchAll(
                        database,
                        sql: "PRAGMA table_info(\(tableName))"
                    ).map { row in
                        row["name"] as String
                    }
                    return (tableName, Set(columnNames))
                }
            )
        }

        #expect(columnNamesByTable["local_window_state"]?.contains("repos_grouping_mode") == true)
        #expect(columnNamesByTable["local_window_state"]?.contains("panes_grouping_mode") == true)
        #expect(columnNamesByTable["local_window_state"]?.contains("repo_grouping_mode") == false)
        #expect(
            columnNamesByTable["local_repo_explorer_preferences"]?.contains("grouping_mode") == false
        )
    }

    @Test("migration 005 copies the existing grouping selection into the main window row before drop")
    func migrationCopiesExistingGroupingModeIntoMainWindowRow() throws {
        // F4: a real pre-005 on-disk database owns the grouping selection on
        // local_repo_explorer_preferences.grouping_mode; local_window_state does not yet have
        // repo_grouping_mode. Simulate that exact shape by migrating only through 004, then
        // manually reproducing the legacy column and a seeded All Panes / By Tab selection, so the
        // upgrade path is proven to preserve it rather than silently reset every existing user to
        // By Repo.
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "004_remove_persisted_pull_request_counts"
        )
        let workspaceId = UUIDv7.generate().uuidString
        let windowId = UUIDv7.generate().uuidString
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    ALTER TABLE local_repo_explorer_preferences
                    ADD COLUMN grouping_mode TEXT NOT NULL DEFAULT 'repo'
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO local_repo_explorer_preferences(
                        workspace_id, sort_order, visibility_mode, grouping_mode, updated_at
                    ) VALUES (?, 'ascending', 'all', 'tab', 1)
                    """,
                arguments: [workspaceId]
            )
            try database.execute(
                sql: """
                    INSERT INTO local_window_state(
                        window_id, window_role, sidebar_width, window_frame_json, filter_text,
                        is_filter_visible, sidebar_collapsed, sidebar_surface, updated_at
                    ) VALUES (?, 'main', 240, NULL, '', 0, 0, 'repos', 1)
                    """,
                arguments: [windowId]
            )
        }

        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "005_move_repo_grouping_to_window_sidebar_memory"
        )

        let repoGroupingMode = try databaseQueue.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT repo_grouping_mode FROM local_window_state WHERE window_role = 'main'"
            )
        }
        #expect(repoGroupingMode == "tab")
    }

    @Test("N1 tie-breaker: migration 005 breaks equal updated_at ties by workspace_id")
    func migrationBreaksEqualUpdatedAtTiesByWorkspaceId() throws {
        // N1 tie-breaker (owner ruling, pass 3): two legacy workspace rows can share the exact
        // same updated_at (e.g. both written in the same batch/import), in which case `ORDER BY
        // updated_at DESC` alone leaves the winner to SQLite's unspecified row order. The
        // deterministic secondary key is the table's own primary key, workspace_id DESC.
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "004_remove_persisted_pull_request_counts"
        )
        let candidateAId = UUIDv7.generate().uuidString
        let candidateBId = UUIDv7.generate().uuidString
        // Determine winner by workspace_id value alone (not by generation/insertion order), then
        // insert the lexicographically SMALLER id first and the LARGER id second. This decouples
        // "which row sorts higher by workspace_id" from "which row was inserted/scanned last", so
        // a query that silently falls back to SQLite's unspecified tie order (e.g. favoring the
        // most-recently-inserted row) cannot coincidentally reproduce the correct answer -- only
        // the explicit `workspace_id DESC` tie-break can.
        let greaterWorkspaceId = max(candidateAId, candidateBId)
        let lesserWorkspaceId = min(candidateAId, candidateBId)
        let expectedWinnerMode = greaterWorkspaceId == candidateAId ? "pane" : "tab"
        let windowId = UUIDv7.generate().uuidString
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    ALTER TABLE local_repo_explorer_preferences
                    ADD COLUMN grouping_mode TEXT NOT NULL DEFAULT 'repo'
                    """
            )
            // Identical updated_at on both rows -- only workspace_id can break the tie. Insert the
            // lesser id first and the greater id LAST, so a naive/unfixed query that (in this
            // SQLite build) happens to favor the most-recently-inserted row on ties would pick the
            // WRONG (lesser) winner, proving the fix -- not insertion order -- drives the result.
            try database.execute(
                sql: """
                    INSERT INTO local_repo_explorer_preferences(
                        workspace_id, sort_order, visibility_mode, grouping_mode, updated_at
                    ) VALUES (?, 'ascending', 'all', ?, 500)
                    """,
                arguments: [lesserWorkspaceId, lesserWorkspaceId == candidateAId ? "pane" : "tab"]
            )
            try database.execute(
                sql: """
                    INSERT INTO local_repo_explorer_preferences(
                        workspace_id, sort_order, visibility_mode, grouping_mode, updated_at
                    ) VALUES (?, 'ascending', 'all', ?, 500)
                    """,
                arguments: [greaterWorkspaceId, greaterWorkspaceId == candidateAId ? "pane" : "tab"]
            )
            try database.execute(
                sql: """
                    INSERT INTO local_window_state(
                        window_id, window_role, sidebar_width, window_frame_json, filter_text,
                        is_filter_visible, sidebar_collapsed, sidebar_surface, updated_at
                    ) VALUES (?, 'main', 240, NULL, '', 0, 0, 'repos', 1)
                    """,
                arguments: [windowId]
            )
        }

        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "005_move_repo_grouping_to_window_sidebar_memory"
        )

        let repoGroupingMode = try databaseQueue.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT repo_grouping_mode FROM local_window_state WHERE window_role = 'main'"
            )
        }
        #expect(repoGroupingMode == expectedWinnerMode)
    }

    @Test("N1: migration 005 picks the most-recently-updated legacy workspace row when several exist")
    func migrationPicksMostRecentlyUpdatedLegacyGroupingAmongMultipleWorkspaces() throws {
        // N1 (re-audit): local_repo_explorer_preferences is keyed by workspace_id, so a real
        // pre-005 database can hold more than one legacy row -- the original single-row fix's
        // unqualified `LIMIT 1` picked an arbitrary winner among them. The deterministic rule
        // (owner ruling) is the most-recently-updated legacy row, since the active-workspace
        // selection lives in a separate database (core.sqlite) this local migration cannot reach.
        // Seed an OLDER row with 'pane' and a NEWER row with 'tab'; the newer one must win
        // regardless of insertion order or workspace_id ordering.
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "004_remove_persisted_pull_request_counts"
        )
        let olderWorkspaceId = UUIDv7.generate().uuidString
        let newerWorkspaceId = UUIDv7.generate().uuidString
        let windowId = UUIDv7.generate().uuidString
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    ALTER TABLE local_repo_explorer_preferences
                    ADD COLUMN grouping_mode TEXT NOT NULL DEFAULT 'repo'
                    """
            )
            // Older row, inserted second (workspace_id ordering and insertion order must not
            // determine the winner -- only updated_at may).
            try database.execute(
                sql: """
                    INSERT INTO local_repo_explorer_preferences(
                        workspace_id, sort_order, visibility_mode, grouping_mode, updated_at
                    ) VALUES (?, 'ascending', 'all', 'pane', 100)
                    """,
                arguments: [olderWorkspaceId]
            )
            try database.execute(
                sql: """
                    INSERT INTO local_repo_explorer_preferences(
                        workspace_id, sort_order, visibility_mode, grouping_mode, updated_at
                    ) VALUES (?, 'ascending', 'all', 'tab', 200)
                    """,
                arguments: [newerWorkspaceId]
            )
            try database.execute(
                sql: """
                    INSERT INTO local_window_state(
                        window_id, window_role, sidebar_width, window_frame_json, filter_text,
                        is_filter_visible, sidebar_collapsed, sidebar_surface, updated_at
                    ) VALUES (?, 'main', 240, NULL, '', 0, 0, 'repos', 1)
                    """,
                arguments: [windowId]
            )
        }

        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "005_move_repo_grouping_to_window_sidebar_memory"
        )

        let repoGroupingMode = try databaseQueue.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT repo_grouping_mode FROM local_window_state WHERE window_role = 'main'"
            )
        }
        #expect(repoGroupingMode == "tab")
    }

    @Test("migration 007 maps legacy modes and preserves sort direction independently")
    func migration007MapsLegacyModesAndPreservesSortDirectionIndependently() throws {
        for scenario in migration007Scenarios {
            let migrated = try migrateSidebarOrganizationScenario(scenario)
            assertMigratedSidebarOrganization(migrated, matches: scenario)
        }
    }

    @Test("pull request cache hard cut drops legacy persisted counts")
    func pullRequestCacheHardCutDropsLegacyPersistedCounts() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "003_invert_sidebar_group_memory"
        )
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO cache_pull_request_count(worktree_id, repo_id, count, updated_at)
                    VALUES (?, ?, 3, 1)
                    """,
                arguments: [UUIDv7.generate().uuidString, UUIDv7.generate().uuidString]
            )
        }

        try WorkspaceLocalMigrations.migrate(databaseQueue)

        let legacyTableExists = try databaseQueue.read { database in
            try database.tableExists("cache_pull_request_count")
        }
        #expect(!legacyTableExists)
    }

    @Test("sidebar group hard cut resets legacy expanded rows and stores collapsed groups")
    func sidebarGroupHardCutResetsLegacyExpandedRows() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "002_replace_recent_targets_with_entity_recency"
        )
        let windowId = UUIDv7.generate().uuidString
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_window_state(
                        window_id, window_role, sidebar_width, window_frame_json, filter_text,
                        is_filter_visible, sidebar_collapsed, sidebar_surface, updated_at
                    ) VALUES (?, 'main', 240, NULL, '', 0, 0, 'repos', 1)
                    """,
                arguments: [windowId]
            )
            try database.execute(
                sql: """
                    INSERT INTO local_window_sidebar_expanded_group(window_id, group_key)
                    VALUES (?, 'repo:legacy')
                    """,
                arguments: [windowId]
            )
        }

        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "003_invert_sidebar_group_memory"
        )

        let migratedState = try databaseQueue.read { database in
            (
                try database.tableExists("local_window_sidebar_expanded_group"),
                try database.tableExists("local_window_sidebar_collapsed_group"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM local_window_sidebar_collapsed_group") ?? -1
            )
        }
        #expect(!migratedState.0)
        #expect(migratedState.1)
        #expect(migratedState.2 == 0)
    }

    @Test("entity recency hard cut discards legacy target rows during migration")
    func entityRecencyHardCutDiscardsLegacyTargetRows() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "001_create_application_local_schema"
        )
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_recent_workspace_target(
                        workspace_id, id, path, display_title, subtitle,
                        repo_id, worktree_id, kind, last_opened_at
                    ) VALUES (?, 'legacy', '/tmp/legacy', 'Legacy', '', NULL, NULL, 'cwdOnly', 1)
                    """,
                arguments: [UUID().uuidString]
            )
        }

        try WorkspaceLocalMigrations.migrator.migrate(
            databaseQueue,
            upTo: "002_replace_recent_targets_with_entity_recency"
        )

        let migratedState = try databaseQueue.read { database in
            let legacyTableCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM sqlite_master
                    WHERE type = 'table' AND name = 'local_recent_workspace_target'
                    """
            )
            let applicationRowCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM local_entity_recency"
            )
            let workspaceRowCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM local_workspace_entity_recency"
            )
            return (legacyTableCount, applicationRowCount, workspaceRowCount)
        }

        #expect(migratedState.0 == 0)
        #expect(migratedState.1 == 0)
        #expect(migratedState.2 == 0)
    }

    @Test("workspace cursor keys isolate rows in one database")
    func workspaceCursorKeysIsolateRowsInOneDatabase() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        let firstWorkspaceId = UUID().uuidString
        let secondWorkspaceId = UUID().uuidString
        let sharedTabId = UUID().uuidString

        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_tab_cursor(workspace_id, tab_id, active_arrangement_id, updated_at)
                    VALUES (?, ?, NULL, 1), (?, ?, NULL, 2)
                    """,
                arguments: [firstWorkspaceId, sharedTabId, secondWorkspaceId, sharedTabId]
            )
        }

        let workspaceIds = try databaseQueue.read { database in
            try String.fetchAll(database, sql: "SELECT workspace_id FROM local_tab_cursor ORDER BY updated_at")
        }
        #expect(workspaceIds == [firstWorkspaceId, secondWorkspaceId])
    }

    @Test("window role is one stable main row and child rows cascade")
    func windowRoleIsOneStableMainRowAndChildRowsCascade() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        let windowId = UUID().uuidString

        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_window_state(
                        window_id, window_role, sidebar_width, window_frame_json, filter_text,
                        is_filter_visible, sidebar_collapsed, sidebar_surface, updated_at
                    ) VALUES (?, 'main', 240, NULL, '', 0, 0, 'repos', 1)
                    """,
                arguments: [windowId]
            )
            try database.execute(
                sql: "INSERT INTO local_window_sidebar_collapsed_group(window_id, group_key) VALUES (?, 'repo:test')",
                arguments: [windowId]
            )
        }

        expectLocalDatabaseError(containing: "UNIQUE constraint failed") {
            try databaseQueue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO local_window_state(
                            window_id, window_role, sidebar_width, window_frame_json, filter_text,
                            is_filter_visible, sidebar_collapsed, sidebar_surface, updated_at
                        ) VALUES (?, 'main', 250, NULL, '', 0, 0, 'inbox', 2)
                        """,
                    arguments: [UUID().uuidString]
                )
            }
        }

        try databaseQueue.write { database in
            try database.execute(sql: "DELETE FROM local_window_state WHERE window_id = ?", arguments: [windowId])
        }
        let childCount = try databaseQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM local_window_sidebar_collapsed_group") ?? -1
        }
        #expect(childCount == 0)
    }

    @Test("main window first use creates one stable UUIDv7 identity")
    func mainWindowFirstUseCreatesOneStableUUIDv7Identity() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        let repository = WorkspaceLocalRepository(workspaceId: UUIDv7.generate(), databaseWriter: databaseQueue)

        try repository.replaceWindowState(
            .init(sidebarWidth: 300, windowFrame: nil),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let firstStoredWindowId: String? = try databaseQueue.read { database in
            try String.fetchOne(database, sql: "SELECT window_id FROM local_window_state")
        }
        let firstWindowId = try #require(firstStoredWindowId)

        let reopenedRepository = WorkspaceLocalRepository(
            workspaceId: UUIDv7.generate(),
            databaseWriter: databaseQueue
        )
        try reopenedRepository.replaceWindowState(
            .init(sidebarWidth: 320, windowFrame: nil),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let reopenedStoredWindowId: String? = try databaseQueue.read { database in
            try String.fetchOne(database, sql: "SELECT window_id FROM local_window_state")
        }
        let reopenedWindowId = try #require(reopenedStoredWindowId)

        let parsedWindowId = try #require(UUID(uuidString: firstWindowId))
        #expect(UUIDv7.isV7(parsedWindowId))
        #expect(reopenedWindowId == firstWindowId)
    }

    @Test("SQLite enforces structural values without product enum checks")
    func sqliteEnforcesStructuralValuesWithoutProductEnumChecks() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString

        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_entity_recency(
                        entity_kind, entity_key, interaction_kind, last_interacted_at
                    ) VALUES ('futureKind', 'future-key', 'futureInteraction', 1)
                    """,
                arguments: []
            )
            try database.execute(
                sql: """
                    INSERT INTO local_workspace_entity_recency(
                        workspace_id, entity_kind, entity_key, interaction_kind, last_interacted_at
                    ) VALUES (?, 'futureKind', 'future-key', 'futureInteraction', 1)
                    """,
                arguments: [workspaceId]
            )
            try database.execute(
                sql: """
                    INSERT INTO local_notification_inbox_item(
                        workspace_id, id, timestamp, kind, title, source_kind,
                        claim_pane_id, claim_lane, claim_semantic, claim_session_id,
                        is_read, is_dismissed_from_pane_inbox
                    ) VALUES (?, 'notification', 1, 'futureKind', 'Title', 'global', NULL, 'futureLane', NULL, NULL, 0, 0)
                    """,
                arguments: [workspaceId]
            )
        }

        expectLocalDatabaseError(containing: "CHECK constraint failed") {
            try databaseQueue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO local_drawer_cursor(workspace_id, drawer_id, is_expanded, updated_at)
                        VALUES (?, ?, 2, 1)
                        """,
                    arguments: [workspaceId, UUID().uuidString]
                )
            }
        }
        expectLocalDatabaseError(containing: "CHECK constraint failed") {
            try databaseQueue.write { database in
                try database.execute(
                    sql: "INSERT INTO cache_metadata(singleton_id, source_revision) VALUES (2, 0)"
                )
            }
        }
    }
}

private struct Migration007Scenario: Sendable {
    let legacyMode: String
    let expectedSurface: String
    let expectedPaneGrouping: String
    let legacyGroupKey: String
    let expectedGroupKeys: Set<String>
}

private struct Migration007Snapshot {
    let window: Row
    let preferences: Row
    let windowColumns: Set<String>
    let preferenceColumns: Set<String>
    let collapsedGroupKeys: Set<String>
}

private let migration007Scenarios = [
    Migration007Scenario(
        legacyMode: "repo",
        expectedSurface: "repos",
        expectedPaneGrouping: "repo",
        legacyGroupKey: "remote:org/repo",
        expectedGroupKeys: [
            "repos:pinnedRepositories:remote:org/repo",
            "repos:openRepositories:remote:org/repo",
            "repos:repositories:remote:org/repo",
        ]
    ),
    Migration007Scenario(
        legacyMode: "pane",
        expectedSurface: "panes",
        expectedPaneGrouping: "repo",
        legacyGroupKey: "pane-repo:10000000-0000-0000-0000-000000000001",
        expectedGroupKeys: [
            "panes:pinnedPanes:repo:10000000-0000-0000-0000-000000000001",
            "panes:panes:repo:10000000-0000-0000-0000-000000000001",
        ]
    ),
    Migration007Scenario(
        legacyMode: "tab",
        expectedSurface: "panes",
        expectedPaneGrouping: "tab",
        legacyGroupKey: "tab:10000000-0000-0000-0000-000000000002",
        expectedGroupKeys: [
            "panes:pinnedPanes:tab:10000000-0000-0000-0000-000000000002",
            "panes:panes:tab:10000000-0000-0000-0000-000000000002",
        ]
    ),
]

private let migration007InactiveModeKeys: Set<String> = [
    "repos:pinnedRepositories:remote:inactive/group",
    "repos:openRepositories:remote:inactive/group",
    "repos:repositories:remote:inactive/group",
    "panes:pinnedPanes:repo:10000000-0000-0000-0000-000000000003",
    "panes:panes:repo:10000000-0000-0000-0000-000000000003",
    "panes:pinnedPanes:tab:10000000-0000-0000-0000-000000000004",
    "panes:panes:tab:10000000-0000-0000-0000-000000000004",
]

private func migrateSidebarOrganizationScenario(
    _ scenario: Migration007Scenario
) throws -> Migration007Snapshot {
    let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
    try WorkspaceLocalMigrations.migrator.migrate(
        databaseQueue,
        upTo: "006_add_repository_local_activity_facts"
    )
    let workspaceId = UUIDv7.generate().uuidString
    let windowId = UUIDv7.generate().uuidString
    try databaseQueue.write { database in
        try seedMigration007Scenario(
            database,
            scenario: scenario,
            workspaceId: workspaceId,
            windowId: windowId
        )
    }
    try WorkspaceLocalMigrations.migrate(databaseQueue)
    return try databaseQueue.read { database in
        try readMigration007Snapshot(database, workspaceId: workspaceId)
    }
}

private func seedMigration007Scenario(
    _ database: Database,
    scenario: Migration007Scenario,
    workspaceId: String,
    windowId: String
) throws {
    try database.execute(
        sql: """
            INSERT INTO local_window_state(
                window_id, window_role, sidebar_width, window_frame_json, filter_text,
                is_filter_visible, sidebar_collapsed, sidebar_surface,
                repo_grouping_mode, updated_at
            ) VALUES (?, 'main', 250, NULL, 'saved filter', 1, 0, 'repos', ?, 10)
            """,
        arguments: [windowId, scenario.legacyMode]
    )
    try database.execute(
        sql: """
            INSERT INTO local_repo_explorer_preferences(
                workspace_id, sort_order, visibility_mode, updated_at
            ) VALUES (?, 'descending', 'all', 10)
            """,
        arguments: [workspaceId]
    )
    let legacyCollapsedKeys = [
        scenario.legacyGroupKey,
        "remote:inactive/group",
        "pane-repo:10000000-0000-0000-0000-000000000003",
        "tab:10000000-0000-0000-0000-000000000004",
    ]
    for groupKey in legacyCollapsedKeys {
        try database.execute(
            sql: "INSERT INTO local_window_sidebar_collapsed_group(window_id, group_key) VALUES (?, ?)",
            arguments: [windowId, groupKey]
        )
    }
}

private func readMigration007Snapshot(
    _ database: Database,
    workspaceId: String
) throws -> Migration007Snapshot {
    let window = try #require(
        try Row.fetchOne(
            database,
            sql: """
                SELECT sidebar_surface, repos_grouping_mode, panes_grouping_mode,
                       repos_subgroup_mode, panes_subgroup_mode,
                       repos_shows_pinned, panes_shows_pinned, filter_text
                FROM local_window_state
                WHERE window_role = 'main'
                """
        )
    )
    let preferences = try #require(
        try Row.fetchOne(
            database,
            sql: """
                SELECT repos_sort_field, panes_sort_field,
                       repos_sort_direction, panes_sort_direction
                FROM local_repo_explorer_preferences
                WHERE workspace_id = ?
                """,
            arguments: [workspaceId]
        )
    )
    return Migration007Snapshot(
        window: window,
        preferences: preferences,
        windowColumns: try Set(
            String.fetchAll(database, sql: "SELECT name FROM pragma_table_info('local_window_state')")
        ),
        preferenceColumns: try Set(
            String.fetchAll(
                database,
                sql: "SELECT name FROM pragma_table_info('local_repo_explorer_preferences')"
            )
        ),
        collapsedGroupKeys: try Set(
            String.fetchAll(database, sql: "SELECT group_key FROM local_window_sidebar_collapsed_group")
        )
    )
}

private func assertMigratedSidebarOrganization(
    _ migrated: Migration007Snapshot,
    matches scenario: Migration007Scenario
) {
    #expect(migrated.window["sidebar_surface"] as String == scenario.expectedSurface)
    #expect(migrated.window["repos_grouping_mode"] as String == "repo")
    #expect(migrated.window["panes_grouping_mode"] as String == scenario.expectedPaneGrouping)
    #expect(migrated.window["repos_subgroup_mode"] as String == "none")
    #expect(migrated.window["panes_subgroup_mode"] as String == "activity")
    #expect(migrated.window["repos_shows_pinned"] as Int == 1)
    #expect(migrated.window["panes_shows_pinned"] as Int == 1)
    #expect(migrated.window["filter_text"] as String == "saved filter")
    #expect(migrated.preferences["repos_sort_field"] as String == "name")
    #expect(migrated.preferences["panes_sort_field"] as String == "name")
    #expect(migrated.preferences["repos_sort_direction"] as String == "descending")
    #expect(migrated.preferences["panes_sort_direction"] as String == "descending")
    #expect(!migrated.windowColumns.contains("repo_grouping_mode"))
    #expect(!migrated.preferenceColumns.contains("sort_order"))
    #expect(!migrated.preferenceColumns.contains("visibility_mode"))
    #expect(migrated.collapsedGroupKeys == scenario.expectedGroupKeys.union(migration007InactiveModeKeys))
}

private func expectLocalDatabaseError(containing expectedMessage: String, _ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected DatabaseError containing '\(expectedMessage)'")
    } catch let error as DatabaseError {
        #expect(error.message?.contains(expectedMessage) == true)
    } catch {
        Issue.record("Expected DatabaseError, got \(error)")
    }
}
