import GRDB

package enum WorkspaceLocalMigrations {
    package static var bootRequiredMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerInitialBootRequiredMigrations(in: &migrator)
        registerLegacyGroupingMigration(in: &migrator)
        registerActivityAndAnnotationMigrations(in: &migrator)
        registerReviewedSubjectMigrations(in: &migrator)
        registerPerScreenSidebarOrganizationMigration(in: &migrator)
        registerPanesDrawerVisibilityMigration(in: &migrator)
        registerDrawerPresentationSchema(in: &migrator)
        return migrator
    }

    package static var migrator: DatabaseMigrator {
        var migrator = bootRequiredMigrator
        registerSessionsSchema(in: &migrator)
        registerIPCCredentialSchema(in: &migrator)
        registerOpaquePaneCredentialRecords(in: &migrator)
        registerPaneOnlyCredentialRecords(in: &migrator)
        registerCLIOutboxCursor(in: &migrator)
        return migrator
    }

    private static func registerInitialBootRequiredMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("001_create_application_local_schema") { database in
            for statement in createApplicationLocalSchemaStatements {
                try database.execute(sql: statement)
            }
        }
        migrator.registerMigration("002_replace_recent_targets_with_entity_recency") { database in
            try database.execute(sql: "DROP TABLE local_recent_workspace_target")
            try database.execute(
                sql: """
                    CREATE TABLE local_entity_recency (
                        entity_kind TEXT NOT NULL,
                        entity_key TEXT NOT NULL,
                        interaction_kind TEXT NOT NULL,
                        last_interacted_at REAL NOT NULL,
                        PRIMARY KEY (entity_kind, entity_key)
                    )
                    """
            )
            try database.execute(
                sql: """
                    CREATE INDEX idx_local_entity_recency_kind_time
                    ON local_entity_recency(
                        entity_kind,
                        last_interacted_at DESC,
                        entity_key ASC
                    )
                    """
            )
            try database.execute(
                sql: """
                    CREATE TABLE local_workspace_entity_recency (
                        workspace_id TEXT NOT NULL,
                        entity_kind TEXT NOT NULL,
                        entity_key TEXT NOT NULL,
                        interaction_kind TEXT NOT NULL,
                        last_interacted_at REAL NOT NULL,
                        PRIMARY KEY (workspace_id, entity_kind, entity_key)
                    )
                    """
            )
            try database.execute(
                sql: """
                    CREATE INDEX idx_local_workspace_entity_recency_scope_kind_time
                    ON local_workspace_entity_recency(
                        workspace_id,
                        entity_kind,
                        last_interacted_at DESC,
                        entity_key ASC
                    )
                    """
            )
        }
        migrator.registerMigration("003_invert_sidebar_group_memory") { database in
            guard try database.tableExists("local_window_sidebar_expanded_group") else { return }

            // Expanded rows cannot encode which absent groups were explicitly collapsed.
            // Reset this local presentation cache during the hard cut so every group starts open.
            try database.execute(sql: "DROP TABLE local_window_sidebar_expanded_group")
            try database.execute(
                sql: """
                        CREATE TABLE local_window_sidebar_collapsed_group (
                            window_id TEXT NOT NULL REFERENCES local_window_state(window_id) ON DELETE CASCADE,
                            group_key TEXT NOT NULL,
                            PRIMARY KEY (window_id, group_key)
                        )
                    """
            )
        }
        migrator.registerMigration("004_remove_persisted_pull_request_counts") { database in
            try database.execute(sql: "DROP TABLE IF EXISTS cache_pull_request_count")
        }
    }

    private static func registerLegacyGroupingMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("005_move_repo_grouping_to_window_sidebar_memory") { database in
            let windowColumnNames = try Set(
                String.fetchAll(
                    database,
                    sql: "SELECT name FROM pragma_table_info('local_window_state')"
                )
            )
            if !windowColumnNames.contains("repo_grouping_mode") {
                try database.execute(
                    sql: """
                        ALTER TABLE local_window_state
                        ADD COLUMN repo_grouping_mode TEXT NOT NULL DEFAULT 'repo'
                        """
                )
            }

            let preferenceColumnNames = try Set(
                String.fetchAll(
                    database,
                    sql: "SELECT name FROM pragma_table_info('local_repo_explorer_preferences')"
                )
            )
            if preferenceColumnNames.contains("grouping_mode") {
                // Preserve an existing user's selection: copy the legacy per-workspace value into
                // the new window-scoped column before the old column is dropped. A missing or
                // unrecognized legacy value leaves the new column at its 'repo' default rather than
                // failing the migration.
                //
                // Deterministic mapping (owner ruling, N1): local_repo_explorer_preferences is
                // keyed by workspace_id, so more than one legacy row is possible. The ideal winner
                // is the currently active workspace, but that selection lives in
                // app_workspace_selection in core.sqlite -- a separate database this local
                // migration cannot reach (core and local prepare and migrate independently; see
                // "SQLite ownership" in CLAUDE.md). The deterministic fallback is therefore the
                // most-recently-updated legacy row, ordered by this table's own updated_at; two
                // rows can share an updated_at (e.g. both written in the same batch/import), so
                // break ties with the table's own primary key (workspace_id DESC) to guarantee one
                // deterministic winner rather than falling back to SQLite's unspecified row order
                // (owner ruling, N1 tie-breaker).
                if let existingGroupingMode = try String.fetchOne(
                    database,
                    sql: """
                        SELECT grouping_mode FROM local_repo_explorer_preferences
                        ORDER BY updated_at DESC, workspace_id DESC
                        LIMIT 1
                        """
                ), SQLiteLocalUXStorage.isValidRepoExplorerGrouping(existingGroupingMode) {
                    try database.execute(
                        sql: """
                            UPDATE local_window_state
                            SET repo_grouping_mode = ?
                            WHERE window_role = 'main'
                            """,
                        arguments: [existingGroupingMode]
                    )
                }
                try database.execute(
                    sql: "ALTER TABLE local_repo_explorer_preferences DROP COLUMN grouping_mode"
                )
            }
        }
    }

    private static func registerActivityAndAnnotationMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("006_add_repository_local_activity_facts") { database in
            try database.execute(
                sql: """
                    CREATE TABLE local_repository_activity (
                        repository_stable_key TEXT PRIMARY KEY,
                        last_qualifying_activity_at REAL,
                        continuous_coverage_started_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        owned_promotion_attempt_id TEXT,
                        owned_promotion_started_at REAL,
                        owned_promotion_unsettled INTEGER NOT NULL
                            CHECK (owned_promotion_unsettled IN (0, 1))
                    )
                    """
            )
            try database.execute(
                sql: """
                    CREATE TABLE local_repository_activity_cursor (
                        volume_identifier TEXT PRIMARY KEY,
                        last_event_id INTEGER NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
            )
        }
        migrator.registerMigration("006_create_worktree_annotation_schema") { database in
            guard try !database.tableExists("annotation_session") else { return }
            for statement in createWorktreeAnnotationSchemaStatements {
                try database.execute(sql: statement)
            }
        }
        migrator.registerMigration("007_add_worktree_annotation_message_handled") { database in
            let messageColumnNames = try Set(
                String.fetchAll(
                    database,
                    sql: "SELECT name FROM pragma_table_info('annotation_message')"
                )
            )
            guard !messageColumnNames.contains("handled") else { return }
            try database.execute(
                sql:
                    "ALTER TABLE annotation_message ADD COLUMN handled INTEGER NOT NULL DEFAULT 0 CHECK (handled IN (0, 1))"
            )
        }
        migrator.registerMigration("008_add_worktree_annotation_message_viewed_revision") { database in
            let messageColumnNames = try Set(
                String.fetchAll(
                    database,
                    sql: "SELECT name FROM pragma_table_info('annotation_message')"
                )
            )
            guard !messageColumnNames.contains("viewed_saved_revision") else { return }
            try database.execute(
                sql:
                    "ALTER TABLE annotation_message ADD COLUMN viewed_saved_revision INTEGER CHECK (viewed_saved_revision >= 1)"
            )
        }
    }

    private static func registerReviewedSubjectMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("009_add_worktree_annotation_reviewed_subject_evidence") { database in
            let sessionColumnNames = try Set(
                String.fetchAll(
                    database,
                    sql: "SELECT name FROM pragma_table_info('annotation_session')"
                )
            )
            if !sessionColumnNames.contains("accepted_reviewed_subject_json") {
                try database.execute(
                    sql: "ALTER TABLE annotation_session ADD COLUMN accepted_reviewed_subject_json TEXT"
                )
                try database.execute(
                    sql: """
                        UPDATE annotation_session
                        SET accepted_reviewed_subject_json = json_object(
                            'reviewedHeadOID',
                            json_extract(
                                accepted_source_fingerprint_json,
                                '$.reviewComparisonOrigin.reviewedHeadOID'
                            )
                        )
                        WHERE json_type(
                            accepted_source_fingerprint_json,
                            '$.reviewComparisonOrigin.reviewedHeadOID'
                        ) = 'text'
                          AND length(json_extract(
                            accepted_source_fingerprint_json,
                            '$.reviewComparisonOrigin.reviewedHeadOID'
                          )) IN (40, 64)
                          AND json_extract(
                            accepted_source_fingerprint_json,
                            '$.reviewComparisonOrigin.reviewedHeadOID'
                          ) NOT GLOB '*[^0-9A-Fa-f]*'
                        """
                )
            }
            try database.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_annotation_session_repository_lifecycle_relationship
                    ON annotation_session(repository_id, lifecycle, source_relationship)
                    """
            )
        }
        migrator.registerMigration("010_remove_worktree_annotation_workspace_provenance") { database in
            let sessionColumnNames = try Set(
                String.fetchAll(
                    database,
                    sql: "SELECT name FROM pragma_table_info('annotation_session')"
                )
            )
            guard sessionColumnNames.contains("originating_workspace_id") else { return }
            try database.execute(
                sql: "ALTER TABLE annotation_session DROP COLUMN originating_workspace_id"
            )
        }
    }

    private static func registerPerScreenSidebarOrganizationMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("007_add_per_screen_sidebar_organization") { database in
            try migratePerScreenSidebarState(database)
            try migratePerScreenCollapsedGroups(database)
            try migratePerScreenSortPreferences(database)
        }
    }

    private static func migratePerScreenSidebarState(_ database: Database) throws {
        try database.execute(
            sql: """
                ALTER TABLE local_window_state
                RENAME COLUMN repo_grouping_mode TO legacy_grouping_mode
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_window_state
                ADD COLUMN repos_grouping_mode TEXT NOT NULL DEFAULT 'repo'
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_window_state
                ADD COLUMN panes_grouping_mode TEXT NOT NULL DEFAULT 'repo'
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_window_state
                ADD COLUMN repos_subgroup_mode TEXT NOT NULL DEFAULT 'none'
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_window_state
                ADD COLUMN panes_subgroup_mode TEXT NOT NULL DEFAULT 'activity'
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_window_state
                ADD COLUMN repos_shows_pinned INTEGER NOT NULL DEFAULT 1
                CHECK (repos_shows_pinned IN (0, 1))
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_window_state
                ADD COLUMN panes_shows_pinned INTEGER NOT NULL DEFAULT 1
                CHECK (panes_shows_pinned IN (0, 1))
                """
        )
        try database.execute(
            sql: """
                UPDATE local_window_state
                SET sidebar_surface = CASE legacy_grouping_mode
                        WHEN 'pane' THEN 'panes'
                        WHEN 'tab' THEN 'panes'
                        ELSE 'repos'
                    END,
                    panes_grouping_mode = CASE legacy_grouping_mode
                        WHEN 'tab' THEN 'tab'
                        ELSE 'repo'
                    END
                """
        )
    }

    private static func migratePerScreenCollapsedGroups(_ database: Database) throws {
        for section in ["pinnedRepositories", "openRepositories", "repositories"] {
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO local_window_sidebar_collapsed_group(window_id, group_key)
                    SELECT collapsed.window_id, 'repos:\(section):' || collapsed.group_key
                    FROM local_window_sidebar_collapsed_group AS collapsed
                    JOIN local_window_state AS window ON window.window_id = collapsed.window_id
                    WHERE collapsed.group_key NOT LIKE 'pane-repo:%'
                      AND collapsed.group_key NOT LIKE 'tab:%'
                      AND collapsed.group_key NOT LIKE 'repos:%'
                      AND collapsed.group_key NOT LIKE 'panes:%'
                    """
            )
        }
        for section in ["pinnedPanes", "panes"] {
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO local_window_sidebar_collapsed_group(window_id, group_key)
                    SELECT collapsed.window_id,
                           'panes:\(section):repo:' || substr(collapsed.group_key, 11)
                    FROM local_window_sidebar_collapsed_group AS collapsed
                    JOIN local_window_state AS window ON window.window_id = collapsed.window_id
                    WHERE collapsed.group_key LIKE 'pane-repo:%'
                    """
            )
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO local_window_sidebar_collapsed_group(window_id, group_key)
                    SELECT collapsed.window_id,
                           'panes:\(section):tab:' || substr(collapsed.group_key, 5)
                    FROM local_window_sidebar_collapsed_group AS collapsed
                    JOIN local_window_state AS window ON window.window_id = collapsed.window_id
                    WHERE collapsed.group_key LIKE 'tab:%'
                    """
            )
        }
        try database.execute(
            sql: """
                DELETE FROM local_window_sidebar_collapsed_group
                WHERE group_key NOT LIKE 'repos:%'
                  AND group_key NOT LIKE 'panes:%'
                """
        )
        try database.execute(sql: "ALTER TABLE local_window_state DROP COLUMN legacy_grouping_mode")
    }

    private static func migratePerScreenSortPreferences(_ database: Database) throws {
        try database.execute(
            sql: """
                ALTER TABLE local_repo_explorer_preferences
                ADD COLUMN repos_sort_field TEXT NOT NULL DEFAULT 'name'
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_repo_explorer_preferences
                ADD COLUMN panes_sort_field TEXT NOT NULL DEFAULT 'name'
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_repo_explorer_preferences
                ADD COLUMN repos_sort_direction TEXT NOT NULL DEFAULT 'ascending'
                """
        )
        try database.execute(
            sql: """
                ALTER TABLE local_repo_explorer_preferences
                ADD COLUMN panes_sort_direction TEXT NOT NULL DEFAULT 'ascending'
                """
        )
        try database.execute(
            sql: """
                UPDATE local_repo_explorer_preferences
                SET repos_sort_direction = CASE sort_order
                        WHEN 'descending' THEN 'descending'
                        ELSE 'ascending'
                    END,
                    panes_sort_direction = CASE sort_order
                        WHEN 'descending' THEN 'descending'
                        ELSE 'ascending'
                    END
                """
        )
        try database.execute(sql: "ALTER TABLE local_repo_explorer_preferences DROP COLUMN sort_order")
        try database.execute(sql: "ALTER TABLE local_repo_explorer_preferences DROP COLUMN visibility_mode")
    }

    package static func migrateBootRequired(_ writer: any DatabaseWriter) throws {
        try bootRequiredMigrator.migrate(writer)
    }

    package static func migrate(_ writer: any DatabaseWriter) throws {
        try migrator.migrate(writer)
    }

    package static func migrateOptionalSchema(_ writer: any DatabaseWriter) async throws {
        let migrator = migrator
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            migrator.asyncMigrate(writer) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let createApplicationLocalSchemaStatements = [
        """
        CREATE TABLE local_workspace_cursor (
            workspace_id TEXT PRIMARY KEY,
            active_tab_id TEXT,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE local_tab_cursor (
            workspace_id TEXT NOT NULL,
            tab_id TEXT NOT NULL,
            active_arrangement_id TEXT,
            updated_at REAL NOT NULL,
            PRIMARY KEY (workspace_id, tab_id)
        )
        """,
        "CREATE INDEX idx_local_tab_cursor_workspace ON local_tab_cursor(workspace_id)",
        """
        CREATE TABLE local_arrangement_cursor (
            workspace_id TEXT NOT NULL,
            arrangement_id TEXT NOT NULL,
            active_pane_id TEXT,
            updated_at REAL NOT NULL,
            PRIMARY KEY (workspace_id, arrangement_id)
        )
        """,
        "CREATE INDEX idx_local_arrangement_cursor_workspace ON local_arrangement_cursor(workspace_id)",
        """
        CREATE TABLE local_drawer_cursor (
            workspace_id TEXT NOT NULL,
            drawer_id TEXT NOT NULL,
            is_expanded INTEGER NOT NULL CHECK (is_expanded IN (0, 1)),
            updated_at REAL NOT NULL,
            PRIMARY KEY (workspace_id, drawer_id)
        )
        """,
        "CREATE INDEX idx_local_drawer_cursor_workspace ON local_drawer_cursor(workspace_id)",
        """
        CREATE UNIQUE INDEX idx_local_drawer_one_expanded_per_workspace
        ON local_drawer_cursor(workspace_id)
        WHERE is_expanded = 1
        """,
        """
        CREATE TABLE local_arrangement_drawer_cursor (
            workspace_id TEXT NOT NULL,
            arrangement_id TEXT NOT NULL,
            drawer_id TEXT NOT NULL,
            active_child_id TEXT,
            updated_at REAL NOT NULL,
            PRIMARY KEY (workspace_id, arrangement_id, drawer_id)
        )
        """,
        """
        CREATE INDEX idx_local_arrangement_drawer_cursor_workspace
        ON local_arrangement_drawer_cursor(workspace_id)
        """,
        """
        CREATE TABLE local_window_state (
            window_id TEXT PRIMARY KEY,
            window_role TEXT NOT NULL UNIQUE CHECK (window_role = 'main'),
            sidebar_width REAL NOT NULL,
            window_frame_json TEXT,
            filter_text TEXT NOT NULL,
            is_filter_visible INTEGER NOT NULL CHECK (is_filter_visible IN (0, 1)),
            sidebar_collapsed INTEGER NOT NULL CHECK (sidebar_collapsed IN (0, 1)),
            sidebar_surface TEXT NOT NULL,
            repo_grouping_mode TEXT NOT NULL DEFAULT 'repo',
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE local_window_sidebar_expanded_group (
            window_id TEXT NOT NULL REFERENCES local_window_state(window_id) ON DELETE CASCADE,
            group_key TEXT NOT NULL,
            PRIMARY KEY (window_id, group_key)
        )
        """,
        """
        CREATE TABLE local_recent_workspace_target (
            workspace_id TEXT NOT NULL,
            id TEXT NOT NULL,
            path TEXT NOT NULL,
            display_title TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            repo_id TEXT,
            worktree_id TEXT,
            kind TEXT NOT NULL,
            last_opened_at REAL NOT NULL,
            PRIMARY KEY (workspace_id, id)
        )
        """,
        """
        CREATE INDEX idx_local_recent_target_workspace_time
        ON local_recent_workspace_target(workspace_id, last_opened_at)
        """,
        """
        CREATE TABLE local_notification_inbox_collapsed_group (
            workspace_id TEXT NOT NULL,
            group_key TEXT NOT NULL,
            PRIMARY KEY (workspace_id, group_key)
        )
        """,
        """
        CREATE TABLE local_notification_inbox_item (
            workspace_id TEXT NOT NULL,
            id TEXT NOT NULL,
            timestamp REAL NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT,
            source_kind TEXT NOT NULL,
            pane_id TEXT,
            tab_id TEXT,
            tab_display_label TEXT,
            tab_ordinal INTEGER,
            repo_id TEXT,
            repo_name TEXT,
            worktree_id TEXT,
            worktree_name TEXT,
            branch_name TEXT,
            pane_display_label TEXT,
            pane_ordinal INTEGER,
            pane_role TEXT,
            parent_pane_id TEXT,
            parent_pane_display_label TEXT,
            parent_pane_ordinal INTEGER,
            drawer_ordinal INTEGER,
            runtime_display_label TEXT,
            activity_burst_window_id TEXT,
            activity_session_id TEXT,
            activity_event_count INTEGER,
            activity_rows_added INTEGER,
            activity_threshold_rows INTEGER,
            activity_latest_rows INTEGER,
            claim_pane_id TEXT,
            claim_lane TEXT,
            claim_semantic TEXT,
            claim_session_id TEXT,
            is_read INTEGER NOT NULL CHECK (is_read IN (0, 1)),
            is_dismissed_from_pane_inbox INTEGER NOT NULL CHECK (is_dismissed_from_pane_inbox IN (0, 1)),
            PRIMARY KEY (workspace_id, id)
        )
        """,
        """
        CREATE INDEX idx_notification_workspace_timestamp
        ON local_notification_inbox_item(workspace_id, timestamp)
        """,
        """
        CREATE INDEX idx_notification_workspace_pane
        ON local_notification_inbox_item(workspace_id, pane_id)
        """,
        """
        CREATE INDEX idx_notification_workspace_tab
        ON local_notification_inbox_item(workspace_id, tab_id)
        """,
        """
        CREATE INDEX idx_notification_workspace_repo
        ON local_notification_inbox_item(workspace_id, repo_id)
        """,
        """
        CREATE INDEX idx_notification_workspace_worktree
        ON local_notification_inbox_item(workspace_id, worktree_id)
        """,
        """
        CREATE INDEX idx_notification_claim_exact
        ON local_notification_inbox_item(
            workspace_id, claim_pane_id, claim_lane, claim_semantic, claim_session_id
        )
        WHERE claim_pane_id IS NOT NULL
          AND claim_lane IS NOT NULL
          AND claim_semantic IS NOT NULL
        """,
        """
        CREATE INDEX idx_notification_claim_session
        ON local_notification_inbox_item(workspace_id, claim_pane_id, claim_session_id)
        WHERE claim_pane_id IS NOT NULL
          AND claim_session_id IS NOT NULL
        """,
        """
        CREATE TABLE local_editor_preferences (
            workspace_id TEXT PRIMARY KEY,
            bookmarked_editor_id TEXT,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE local_repo_explorer_preferences (
            workspace_id TEXT PRIMARY KEY,
            sort_order TEXT NOT NULL,
            visibility_mode TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE local_inbox_notification_preferences (
            workspace_id TEXT PRIMARY KEY,
            grouping TEXT NOT NULL,
            sort_order TEXT NOT NULL,
            bell_enabled INTEGER NOT NULL CHECK (bell_enabled IN (0, 1)),
            global_content_mode TEXT NOT NULL,
            global_row_state_filter TEXT NOT NULL,
            pane_content_mode TEXT NOT NULL,
            pane_row_state_filter TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE cache_metadata (
            singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
            source_revision INTEGER NOT NULL DEFAULT 0 CHECK (source_revision >= 0),
            last_rebuilt_at REAL
        )
        """,
        """
        CREATE TABLE cache_repo_enrichment (
            repo_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            origin TEXT,
            upstream TEXT,
            group_key TEXT,
            remote_slug TEXT,
            organization_name TEXT,
            display_name TEXT,
            updated_at REAL NOT NULL,
            payload_json TEXT
        )
        """,
        """
        CREATE TABLE cache_worktree_enrichment (
            worktree_id TEXT PRIMARY KEY,
            repo_id TEXT NOT NULL,
            branch TEXT,
            is_main_worktree INTEGER NOT NULL CHECK (is_main_worktree IN (0, 1)),
            updated_at REAL NOT NULL,
            payload_json TEXT
        )
        """,
        "CREATE INDEX idx_cache_worktree_repo ON cache_worktree_enrichment(repo_id)",
        """
        CREATE TABLE cache_pull_request_count (
            worktree_id TEXT PRIMARY KEY,
            repo_id TEXT,
            count INTEGER NOT NULL CHECK (count >= 0),
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_cache_pull_request_repo ON cache_pull_request_count(repo_id)",
    ]

    private static let createWorktreeAnnotationSchemaStatements = [
        """
        CREATE TABLE annotation_session (
            id TEXT PRIMARY KEY,
            repository_id TEXT NOT NULL,
            worktree_id TEXT NOT NULL,
            originating_workspace_id TEXT,
            lifecycle TEXT NOT NULL,
            source_relationship TEXT NOT NULL,
            accepted_source_fingerprint_json TEXT NOT NULL,
            semantic_revision INTEGER NOT NULL DEFAULT 0 CHECK (semantic_revision >= 0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            completed_at REAL
        )
        """,
        """
        CREATE INDEX idx_annotation_session_worktree
        ON annotation_session(worktree_id, lifecycle, source_relationship)
        """,
        """
        CREATE TABLE annotation_thread (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES annotation_session(id) ON DELETE CASCADE,
            scope TEXT NOT NULL,
            resolution TEXT NOT NULL,
            origin_json TEXT NOT NULL,
            created_ordinal INTEGER NOT NULL CHECK (created_ordinal >= 0),
            semantic_revision INTEGER NOT NULL DEFAULT 0 CHECK (semantic_revision >= 0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            resolved_at REAL,
            UNIQUE (session_id, created_ordinal)
        )
        """,
        "CREATE INDEX idx_annotation_thread_session ON annotation_thread(session_id, created_ordinal)",
        """
        CREATE TABLE annotation_message (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL REFERENCES annotation_thread(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
            author_kind TEXT NOT NULL,
            saved_body TEXT,
            saved_body_utf8_bytes INTEGER CHECK (saved_body_utf8_bytes BETWEEN 1 AND 16384),
            saved_revision INTEGER CHECK (saved_revision >= 1),
            status TEXT NOT NULL,
            semantic_revision INTEGER NOT NULL DEFAULT 0 CHECK (semantic_revision >= 0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE (thread_id, ordinal)
        )
        """,
        "CREATE INDEX idx_annotation_message_thread ON annotation_message(thread_id, ordinal)",
        """
        CREATE TABLE annotation_message_draft (
            message_id TEXT PRIMARY KEY REFERENCES annotation_message(id) ON DELETE CASCADE,
            active_edit_token TEXT,
            body TEXT NOT NULL,
            body_utf8_bytes INTEGER NOT NULL CHECK (body_utf8_bytes BETWEEN 0 AND 16384),
            draft_revision INTEGER NOT NULL CHECK (draft_revision >= 0),
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE annotation_output_attempt (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES annotation_session(id) ON DELETE RESTRICT,
            output_kind TEXT NOT NULL,
            state TEXT NOT NULL,
            format_version INTEGER NOT NULL CHECK (format_version >= 1),
            content_type TEXT NOT NULL,
            snapshot_json TEXT NOT NULL,
            exact_bytes BLOB NOT NULL,
            destination_path TEXT,
            repeated_from_attempt_id TEXT REFERENCES annotation_output_attempt(id) ON DELETE RESTRICT,
            effect_error TEXT,
            cleanup_error TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_annotation_output_attempt_session ON annotation_output_attempt(session_id, created_at)",
        """
        CREATE TABLE annotation_output_attempt_message (
            attempt_id TEXT NOT NULL REFERENCES annotation_output_attempt(id) ON DELETE CASCADE,
            message_id TEXT NOT NULL REFERENCES annotation_message(id) ON DELETE RESTRICT,
            expected_saved_revision INTEGER NOT NULL CHECK (expected_saved_revision >= 1),
            batch_ordinal INTEGER NOT NULL CHECK (batch_ordinal >= 0),
            PRIMARY KEY (attempt_id, message_id),
            UNIQUE (attempt_id, batch_ordinal)
        )
        """,
        """
        CREATE INDEX idx_annotation_output_attempt_message_lock
        ON annotation_output_attempt_message(message_id, attempt_id)
        """,
        """
        CREATE TABLE annotation_output_event (
            id TEXT PRIMARY KEY,
            attempt_id TEXT NOT NULL UNIQUE
                REFERENCES annotation_output_attempt(id) ON DELETE RESTRICT,
            event_kind TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        """
        CREATE INDEX idx_annotation_output_event_created
        ON annotation_output_event(created_at)
        """,
        """
        CREATE TABLE local_recovery_provenance (
            id TEXT PRIMARY KEY,
            recovery_kind TEXT NOT NULL,
            recovered_at REAL NOT NULL,
            quarantined_filenames_json TEXT NOT NULL,
            reason TEXT NOT NULL,
            acknowledged_at REAL
        )
        """,
        """
        CREATE INDEX idx_local_recovery_provenance_unacknowledged
        ON local_recovery_provenance(acknowledged_at, recovered_at)
        """,
    ]
}
