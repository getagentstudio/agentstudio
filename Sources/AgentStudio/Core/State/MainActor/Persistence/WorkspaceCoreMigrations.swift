import GRDB

enum WorkspaceCoreMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for migration in migrations {
            migrator.registerMigration(migration.identifier) { database in
                try execute(migration.statements, on: database)
            }
        }
        return migrator
    }

    static func migrate(_ writer: any DatabaseWriter) throws {
        try migrator.migrate(writer)
    }

    private static let migrations: [(identifier: String, statements: [String])] = [
        ("001_create_workspace", createWorkspaceStatements),
        ("002_create_repo_worktree_topology", createRepoWorktreeTopologyStatements),
        ("003_create_panes", createPaneStatements),
        ("004_create_tabs_and_arrangements", createTabArrangementStatements),
        ("005_repair_tab_graph_layout_storage", repairTabGraphLayoutStorageStatements),
        ("006_create_workspace_sqlite_snapshot_status", createWorkspaceSQLiteSnapshotStatusStatements),
        ("007_stage_workspace_sqlite_snapshot_status", stageWorkspaceSQLiteSnapshotStatusStatements),
        ("008_add_zmx_session_id", addZmxSessionIdStatements),
        ("009_drop_pane_source_binding", dropPaneSourceBindingStatements),
        ("010_repository_topology_tags_and_tab_color", repositoryTopologyTagsAndTabColorStatements),
        ("011_add_repo_sidebar_metadata", addRepoSidebarMetadataStatements),
        ("012_background_active_unowned_layout_panes", backgroundActiveUnownedLayoutPanesStatements),
        ("013_globalize_repository_topology", globalizeRepositoryTopologyStatements),
        ("014_drop_shows_minimized_panes", dropShowsMinimizedPanesStatements),
        ("015_drop_pane_topology_facets", dropPaneTopologyFacetsStatements),
        ("016_add_pane_association_facets", addPaneAssociationFacetsStatements),
        // Both identifiers have already been applied by separate branches. Keep their full names stable.
        ("017_add_independent_sidebar_pins", addIndependentSidebarPinsStatements),
        ("017_create_session_ownership_journal", createSessionOwnershipJournalStatements),
        ("018_repository_location_absence", repositoryLocationAbsenceStatements),
        ("019_browser_webviews", browserWebviewsStatements),
    ]

    private static func execute(_ statements: [String], on database: Database) throws {
        for statement in statements {
            try database.execute(sql: statement)
        }
    }

    /// Adds opaque durable terminal identity storage.
    ///
    /// Current writers always persist an identity before pane insertion and
    /// current readers reject NULL or blank values. Existing nonblank text is
    /// preserved verbatim; startup never backfills or rewrites this column.
    /// The column remains nullable only because this historical migration
    /// cannot change already-deployed table constraints in place.
    private static let addZmxSessionIdStatements = [
        """
        ALTER TABLE pane_content_terminal ADD COLUMN zmx_session_id TEXT
        """
    ]

    private static let dropShowsMinimizedPanesStatements = [
        """
        ALTER TABLE tab_arrangement DROP COLUMN shows_minimized_panes
        """
    ]

    private static let dropPaneSourceBindingStatements = [
        """
        DROP TRIGGER IF EXISTS pane_source_repo_matches_workspace
        """,
        """
        DROP TRIGGER IF EXISTS pane_source_repo_update_matches_workspace
        """,
        """
        DROP TRIGGER IF EXISTS pane_source_worktree_matches_workspace
        """,
        """
        DROP TRIGGER IF EXISTS pane_source_worktree_update_matches_workspace
        """,
        """
        ALTER TABLE pane RENAME COLUMN source_repo_id TO facet_repo_id
        """,
        """
        ALTER TABLE pane RENAME COLUMN source_worktree_id TO facet_worktree_id
        """,
        """
        ALTER TABLE pane DROP COLUMN source_kind
        """,
        """
        CREATE TRIGGER pane_facet_repo_matches_workspace
        BEFORE INSERT ON pane
        WHEN NEW.facet_repo_id IS NOT NULL
        AND (SELECT workspace_id FROM repo WHERE id = NEW.facet_repo_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane facet_repo_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_facet_repo_update_matches_workspace
        BEFORE UPDATE OF facet_repo_id, workspace_id ON pane
        WHEN NEW.facet_repo_id IS NOT NULL
        AND (SELECT workspace_id FROM repo WHERE id = NEW.facet_repo_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane facet_repo_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_facet_worktree_matches_workspace
        BEFORE INSERT ON pane
        WHEN NEW.facet_worktree_id IS NOT NULL
        AND (SELECT workspace_id FROM worktree WHERE id = NEW.facet_worktree_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane facet_worktree_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_facet_worktree_update_matches_workspace
        BEFORE UPDATE OF facet_worktree_id, workspace_id ON pane
        WHEN NEW.facet_worktree_id IS NOT NULL
        AND (SELECT workspace_id FROM worktree WHERE id = NEW.facet_worktree_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane facet_worktree_id must belong to pane workspace');
        END
        """,
    ]

    private static let createWorkspaceStatements = [
        """
        CREATE TABLE workspace (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE app_workspace_selection (
            singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
            active_workspace_id TEXT REFERENCES workspace(id) ON DELETE SET NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        INSERT INTO app_workspace_selection(singleton_id, active_workspace_id, updated_at)
        VALUES (1, NULL, 0)
        """,
        """
        CREATE TABLE legacy_workspace_import_status (
            workspace_id TEXT PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
            source_state_path TEXT NOT NULL,
            core_imported_at REAL,
            settings_imported_at REAL,
            local_imported_at REAL,
            cache_imported_at REAL,
            archived_at REAL,
            last_error TEXT
        )
        """,
        """
        CREATE INDEX idx_workspace_updated_at ON workspace(updated_at)
        """,
    ]

    private static let createRepoWorktreeTopologyStatements = [
        """
        CREATE TABLE watched_path (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            stable_key TEXT NOT NULL,
            added_at REAL NOT NULL,
            UNIQUE(workspace_id, stable_key)
        )
        """,
        """
        CREATE TABLE repo (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            repo_path TEXT NOT NULL,
            stable_key TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(workspace_id, stable_key),
            UNIQUE(id, workspace_id)
        )
        """,
        """
        CREATE TABLE worktree (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
            repo_id TEXT NOT NULL,
            name TEXT NOT NULL,
            path TEXT NOT NULL,
            stable_key TEXT NOT NULL,
            is_main_worktree INTEGER NOT NULL,
            UNIQUE(workspace_id, stable_key),
            UNIQUE(repo_id, stable_key),
            FOREIGN KEY(repo_id, workspace_id)
                REFERENCES repo(id, workspace_id)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE unavailable_repo (
            workspace_id TEXT NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
            repo_id TEXT NOT NULL,
            PRIMARY KEY(workspace_id, repo_id),
            FOREIGN KEY(repo_id, workspace_id)
                REFERENCES repo(id, workspace_id)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE INDEX idx_repo_workspace_id ON repo(workspace_id)
        """,
        """
        CREATE INDEX idx_worktree_workspace_id ON worktree(workspace_id)
        """,
        """
        CREATE INDEX idx_worktree_repo_id ON worktree(repo_id)
        """,
    ]

    private static let createWorkspaceSQLiteSnapshotStatusStatements = [
        """
        CREATE TABLE workspace_sqlite_snapshot_status (
            workspace_id TEXT PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
            completed_at REAL NOT NULL
        )
        """
    ]

    private static let stageWorkspaceSQLiteSnapshotStatusStatements = [
        """
        ALTER TABLE workspace_sqlite_snapshot_status
        RENAME TO workspace_sqlite_snapshot_status_old
        """,
        """
        CREATE TABLE workspace_sqlite_snapshot_status (
            workspace_id TEXT PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
            staged_at REAL,
            completed_at REAL
        )
        """,
        """
        INSERT INTO workspace_sqlite_snapshot_status(workspace_id, staged_at, completed_at)
        SELECT workspace_id, completed_at, completed_at
        FROM workspace_sqlite_snapshot_status_old
        """,
        """
        DROP TABLE workspace_sqlite_snapshot_status_old
        """,
    ]

    private static let createPaneStatements = [
        """
        CREATE TABLE pane (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
            content_type TEXT NOT NULL CHECK (
                content_type IN (
                    '\(SQLitePaneContentTypeStorage.terminal)',
                    '\(SQLitePaneContentTypeStorage.browser)',
                    '\(SQLitePaneContentTypeStorage.diff)',
                    '\(SQLitePaneContentTypeStorage.editor)',
                    '\(SQLitePaneContentTypeStorage.review)',
                    '\(SQLitePaneContentTypeStorage.agent)',
                    '\(SQLitePaneContentTypeStorage.codeViewer)'
                )
                OR content_type GLOB '\(SQLitePaneContentTypeStorage.pluginPrefix)?*'
            ),
            execution_backend TEXT NOT NULL,
            source_kind TEXT NOT NULL,
            source_repo_id TEXT REFERENCES repo(id) ON DELETE SET NULL,
            source_worktree_id TEXT REFERENCES worktree(id) ON DELETE SET NULL,
            launch_directory TEXT,
            title TEXT NOT NULL,
            note TEXT,
            cwd TEXT,
            checkout_ref TEXT,
            residency_kind TEXT NOT NULL,
            pending_undo_expires_at REAL,
            orphan_reason_kind TEXT,
            orphan_worktree_path TEXT,
            kind TEXT NOT NULL,
            parent_pane_id TEXT REFERENCES pane(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TRIGGER pane_source_repo_matches_workspace
        BEFORE INSERT ON pane
        WHEN NEW.source_repo_id IS NOT NULL
        AND (SELECT workspace_id FROM repo WHERE id = NEW.source_repo_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane source_repo_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_source_repo_update_matches_workspace
        BEFORE UPDATE OF source_repo_id, workspace_id ON pane
        WHEN NEW.source_repo_id IS NOT NULL
        AND (SELECT workspace_id FROM repo WHERE id = NEW.source_repo_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane source_repo_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_source_worktree_matches_workspace
        BEFORE INSERT ON pane
        WHEN NEW.source_worktree_id IS NOT NULL
        AND (SELECT workspace_id FROM worktree WHERE id = NEW.source_worktree_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane source_worktree_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_source_worktree_update_matches_workspace
        BEFORE UPDATE OF source_worktree_id, workspace_id ON pane
        WHEN NEW.source_worktree_id IS NOT NULL
        AND (SELECT workspace_id FROM worktree WHERE id = NEW.source_worktree_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane source_worktree_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_parent_matches_workspace
        BEFORE INSERT ON pane
        WHEN NEW.parent_pane_id IS NOT NULL
        AND (SELECT workspace_id FROM pane WHERE id = NEW.parent_pane_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane parent_pane_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_parent_update_matches_workspace
        BEFORE UPDATE OF parent_pane_id, workspace_id ON pane
        WHEN NEW.parent_pane_id IS NOT NULL
        AND (SELECT workspace_id FROM pane WHERE id = NEW.parent_pane_id) != NEW.workspace_id
        BEGIN
            SELECT RAISE(ABORT, 'pane parent_pane_id must belong to pane workspace');
        END
        """,
        """
        CREATE TRIGGER pane_content_type_is_supported
        BEFORE INSERT ON pane
        WHEN NEW.content_type NOT IN (
            '\(SQLitePaneContentTypeStorage.terminal)',
            '\(SQLitePaneContentTypeStorage.browser)',
            '\(SQLitePaneContentTypeStorage.diff)',
            '\(SQLitePaneContentTypeStorage.editor)',
            '\(SQLitePaneContentTypeStorage.review)',
            '\(SQLitePaneContentTypeStorage.agent)',
            '\(SQLitePaneContentTypeStorage.codeViewer)'
        )
        AND NEW.content_type NOT GLOB '\(SQLitePaneContentTypeStorage.pluginPrefix)?*'
        BEGIN
            SELECT RAISE(ABORT, 'pane content_type is not supported');
        END
        """,
        """
        CREATE TRIGGER pane_content_type_is_immutable
        BEFORE UPDATE OF content_type ON pane
        WHEN OLD.content_type != NEW.content_type
        BEGIN
            SELECT RAISE(ABORT, 'pane content_type is immutable');
        END
        """,
        """
        CREATE TABLE pane_content_terminal (
            pane_id TEXT PRIMARY KEY REFERENCES pane(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            lifetime TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE pane_content_webview (
            pane_id TEXT PRIMARY KEY REFERENCES pane(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            show_navigation INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE pane_content_code_viewer (
            pane_id TEXT PRIMARY KEY REFERENCES pane(id) ON DELETE CASCADE,
            file_path TEXT NOT NULL,
            scroll_to_line INTEGER
        )
        """,
        """
        CREATE TABLE pane_content_payload (
            pane_id TEXT PRIMARY KEY REFERENCES pane(id) ON DELETE CASCADE,
            payload_kind TEXT NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE drawer (
            id TEXT PRIMARY KEY,
            parent_pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
            UNIQUE(parent_pane_id)
        )
        """,
        """
        CREATE TABLE drawer_pane (
            drawer_id TEXT NOT NULL REFERENCES drawer(id) ON DELETE CASCADE,
            pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
            sort_index INTEGER NOT NULL,
            PRIMARY KEY(drawer_id, pane_id),
            UNIQUE(pane_id),
            UNIQUE(drawer_id, sort_index)
        )
        """,
        """
        CREATE TRIGGER drawer_pane_matches_drawer_workspace
        BEFORE INSERT ON drawer_pane
        WHEN (
            SELECT parent_pane.workspace_id
            FROM drawer
            JOIN pane AS parent_pane ON parent_pane.id = drawer.parent_pane_id
            WHERE drawer.id = NEW.drawer_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'drawer_pane pane must belong to drawer workspace');
        END
        """,
        """
        CREATE TRIGGER drawer_pane_update_matches_drawer_workspace
        BEFORE UPDATE OF drawer_id, pane_id ON drawer_pane
        WHEN (
            SELECT parent_pane.workspace_id
            FROM drawer
            JOIN pane AS parent_pane ON parent_pane.id = drawer.parent_pane_id
            WHERE drawer.id = NEW.drawer_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'drawer_pane pane must belong to drawer workspace');
        END
        """,
        """
        CREATE INDEX idx_pane_workspace_id ON pane(workspace_id)
        """,
        """
        CREATE TRIGGER pane_content_terminal_matches_pane_content_type
        BEFORE INSERT ON pane_content_terminal
        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) != '\(SQLitePaneContentTypeStorage.terminal)'
        BEGIN
            SELECT RAISE(ABORT, 'pane_content_terminal requires terminal pane');
        END
        """,
        """
        CREATE TRIGGER pane_content_terminal_update_matches_pane_content_type
        BEFORE UPDATE OF pane_id ON pane_content_terminal
        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) != '\(SQLitePaneContentTypeStorage.terminal)'
        BEGIN
            SELECT RAISE(ABORT, 'pane_content_terminal requires terminal pane');
        END
        """,
        """
        CREATE TRIGGER pane_content_webview_matches_pane_content_type
        BEFORE INSERT ON pane_content_webview
        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) != '\(SQLitePaneContentTypeStorage.browser)'
        BEGIN
            SELECT RAISE(ABORT, 'pane_content_webview requires browser pane');
        END
        """,
        """
        CREATE TRIGGER pane_content_webview_update_matches_pane_content_type
        BEFORE UPDATE OF pane_id ON pane_content_webview
        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) != '\(SQLitePaneContentTypeStorage.browser)'
        BEGIN
            SELECT RAISE(ABORT, 'pane_content_webview requires browser pane');
        END
        """,
        """
        CREATE TRIGGER pane_content_code_viewer_matches_pane_content_type
        BEFORE INSERT ON pane_content_code_viewer
        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) != '\(SQLitePaneContentTypeStorage.codeViewer)'
        BEGIN
            SELECT RAISE(ABORT, 'pane_content_code_viewer requires codeViewer pane');
        END
        """,
        """
        CREATE TRIGGER pane_content_code_viewer_update_matches_pane_content_type
        BEFORE UPDATE OF pane_id ON pane_content_code_viewer
        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) != '\(SQLitePaneContentTypeStorage.codeViewer)'
        BEGIN
            SELECT RAISE(ABORT, 'pane_content_code_viewer requires codeViewer pane');
        END
        """,
        """
        CREATE TRIGGER pane_content_payload_matches_pane_content_type
        BEFORE INSERT ON pane_content_payload
        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) IN (
            '\(SQLitePaneContentTypeStorage.terminal)',
            '\(SQLitePaneContentTypeStorage.browser)',
            '\(SQLitePaneContentTypeStorage.codeViewer)'
        )
        BEGIN
            SELECT RAISE(ABORT, 'pane_content_payload requires payload pane');
        END
        """,
        """
        CREATE TRIGGER pane_content_payload_update_matches_pane_content_type
        BEFORE UPDATE OF pane_id ON pane_content_payload
        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) IN (
            '\(SQLitePaneContentTypeStorage.terminal)',
            '\(SQLitePaneContentTypeStorage.browser)',
            '\(SQLitePaneContentTypeStorage.codeViewer)'
        )
        BEGIN
            SELECT RAISE(ABORT, 'pane_content_payload requires payload pane');
        END
        """,
    ]

    private static let createTabArrangementStatements = [
        """
        CREATE TABLE tab_shell (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            sort_index INTEGER NOT NULL,
            UNIQUE(workspace_id, sort_index)
        )
        """,
        """
        CREATE TABLE tab_pane (
            tab_id TEXT NOT NULL REFERENCES tab_shell(id) ON DELETE CASCADE,
            pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
            sort_index INTEGER NOT NULL,
            PRIMARY KEY(tab_id, pane_id),
            UNIQUE(pane_id),
            UNIQUE(tab_id, sort_index)
        )
        """,
        """
        CREATE TRIGGER tab_pane_matches_tab_workspace
        BEFORE INSERT ON tab_pane
        WHEN (SELECT workspace_id FROM tab_shell WHERE id = NEW.tab_id)
            != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'tab_pane pane must belong to tab workspace');
        END
        """,
        """
        CREATE TRIGGER tab_pane_update_matches_tab_workspace
        BEFORE UPDATE OF tab_id, pane_id ON tab_pane
        WHEN (SELECT workspace_id FROM tab_shell WHERE id = NEW.tab_id)
            != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'tab_pane pane must belong to tab workspace');
        END
        """,
        """
        CREATE TABLE tab_arrangement (
            id TEXT PRIMARY KEY,
            tab_id TEXT NOT NULL REFERENCES tab_shell(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            is_default INTEGER NOT NULL CHECK (is_default IN (0, 1)),
            shows_minimized_panes INTEGER NOT NULL CHECK (shows_minimized_panes IN (0, 1)),
            sort_index INTEGER NOT NULL,
            UNIQUE(tab_id, sort_index)
        )
        """,
        """
        CREATE UNIQUE INDEX idx_tab_arrangement_one_default
        ON tab_arrangement(tab_id)
        WHERE is_default = 1
        """,
        """
        CREATE TABLE arrangement_layout_pane (
            arrangement_id TEXT NOT NULL REFERENCES tab_arrangement(id) ON DELETE CASCADE,
            pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
            sort_index INTEGER NOT NULL,
            ratio REAL NOT NULL,
            PRIMARY KEY(arrangement_id, pane_id),
            UNIQUE(arrangement_id, sort_index)
        )
        """,
        """
        CREATE TRIGGER arrangement_layout_pane_matches_arrangement_workspace
        BEFORE INSERT ON arrangement_layout_pane
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'arrangement_layout_pane pane must belong to arrangement workspace');
        END
        """,
        """
        CREATE TRIGGER arrangement_layout_pane_update_matches_arrangement_workspace
        BEFORE UPDATE OF arrangement_id, pane_id ON arrangement_layout_pane
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'arrangement_layout_pane pane must belong to arrangement workspace');
        END
        """,
        """
        CREATE TABLE arrangement_layout_divider (
            arrangement_id TEXT NOT NULL REFERENCES tab_arrangement(id) ON DELETE CASCADE,
            divider_id TEXT NOT NULL,
            sort_index INTEGER NOT NULL,
            PRIMARY KEY(arrangement_id, divider_id),
            UNIQUE(arrangement_id, sort_index)
        )
        """,
        """
        CREATE TRIGGER arrangement_layout_pane_prunes_adjacent_divider_after_delete
        AFTER DELETE ON arrangement_layout_pane
        BEGIN
            DELETE FROM arrangement_layout_divider
            WHERE arrangement_id = OLD.arrangement_id
            AND sort_index = (
                SELECT MAX(sort_index)
                FROM arrangement_layout_divider
                WHERE arrangement_id = OLD.arrangement_id
                AND sort_index <= OLD.sort_index
            );
        END
        """,
        """
        CREATE TABLE arrangement_minimized_pane (
            arrangement_id TEXT NOT NULL REFERENCES tab_arrangement(id) ON DELETE CASCADE,
            pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
            PRIMARY KEY(arrangement_id, pane_id)
        )
        """,
        """
        CREATE TRIGGER arrangement_minimized_pane_matches_arrangement_workspace
        BEFORE INSERT ON arrangement_minimized_pane
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'arrangement_minimized_pane pane must belong to arrangement workspace');
        END
        """,
        """
        CREATE TRIGGER arrangement_minimized_pane_update_matches_arrangement_workspace
        BEFORE UPDATE OF arrangement_id, pane_id ON arrangement_minimized_pane
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'arrangement_minimized_pane pane must belong to arrangement workspace');
        END
        """,
        """
        CREATE TABLE arrangement_drawer_view (
            arrangement_id TEXT NOT NULL REFERENCES tab_arrangement(id) ON DELETE CASCADE,
            drawer_id TEXT NOT NULL REFERENCES drawer(id) ON DELETE CASCADE,
            row_split_ratio REAL NOT NULL,
            PRIMARY KEY(arrangement_id, drawer_id)
        )
        """,
        """
        CREATE TRIGGER arrangement_drawer_view_matches_arrangement_workspace
        BEFORE INSERT ON arrangement_drawer_view
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (
            SELECT parent_pane.workspace_id
            FROM drawer
            JOIN pane AS parent_pane ON parent_pane.id = drawer.parent_pane_id
            WHERE drawer.id = NEW.drawer_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'arrangement_drawer_view drawer must belong to arrangement workspace');
        END
        """,
        """
        CREATE TRIGGER arrangement_drawer_view_update_matches_arrangement_workspace
        BEFORE UPDATE OF arrangement_id, drawer_id ON arrangement_drawer_view
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (
            SELECT parent_pane.workspace_id
            FROM drawer
            JOIN pane AS parent_pane ON parent_pane.id = drawer.parent_pane_id
            WHERE drawer.id = NEW.drawer_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'arrangement_drawer_view drawer must belong to arrangement workspace');
        END
        """,
        """
        CREATE TABLE drawer_view_layout_pane (
            arrangement_id TEXT NOT NULL,
            drawer_id TEXT NOT NULL,
            row_kind TEXT NOT NULL,
            pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
            sort_index INTEGER NOT NULL,
            ratio REAL NOT NULL,
            PRIMARY KEY(arrangement_id, drawer_id, pane_id),
            UNIQUE(arrangement_id, drawer_id, row_kind, sort_index),
            FOREIGN KEY(arrangement_id, drawer_id)
                REFERENCES arrangement_drawer_view(arrangement_id, drawer_id)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE TRIGGER drawer_view_layout_pane_matches_arrangement_workspace
        BEFORE INSERT ON drawer_view_layout_pane
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'drawer_view_layout_pane pane must belong to arrangement workspace');
        END
        """,
        """
        CREATE TRIGGER drawer_view_layout_pane_update_matches_arrangement_workspace
        BEFORE UPDATE OF arrangement_id, pane_id ON drawer_view_layout_pane
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'drawer_view_layout_pane pane must belong to arrangement workspace');
        END
        """,
        """
        CREATE TABLE drawer_view_layout_divider (
            arrangement_id TEXT NOT NULL,
            drawer_id TEXT NOT NULL,
            row_kind TEXT NOT NULL,
            divider_id TEXT NOT NULL,
            sort_index INTEGER NOT NULL,
            PRIMARY KEY(arrangement_id, drawer_id, row_kind, divider_id),
            UNIQUE(arrangement_id, drawer_id, row_kind, sort_index),
            FOREIGN KEY(arrangement_id, drawer_id)
                REFERENCES arrangement_drawer_view(arrangement_id, drawer_id)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE TRIGGER drawer_view_layout_pane_prunes_adjacent_divider_after_delete
        AFTER DELETE ON drawer_view_layout_pane
        BEGIN
            DELETE FROM drawer_view_layout_divider
            WHERE arrangement_id = OLD.arrangement_id
            AND drawer_id = OLD.drawer_id
            AND row_kind = OLD.row_kind
            AND sort_index = (
                SELECT MAX(sort_index)
                FROM drawer_view_layout_divider
                WHERE arrangement_id = OLD.arrangement_id
                AND drawer_id = OLD.drawer_id
                AND row_kind = OLD.row_kind
                AND sort_index <= OLD.sort_index
            );
        END
        """,
        """
        CREATE TABLE drawer_view_minimized_pane (
            arrangement_id TEXT NOT NULL,
            drawer_id TEXT NOT NULL,
            pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
            PRIMARY KEY(arrangement_id, drawer_id, pane_id),
            FOREIGN KEY(arrangement_id, drawer_id)
                REFERENCES arrangement_drawer_view(arrangement_id, drawer_id)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE TRIGGER drawer_view_minimized_pane_matches_arrangement_workspace
        BEFORE INSERT ON drawer_view_minimized_pane
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'drawer_view_minimized_pane pane must belong to arrangement workspace');
        END
        """,
        """
        CREATE TRIGGER drawer_view_minimized_pane_update_matches_arrangement_workspace
        BEFORE UPDATE OF arrangement_id, pane_id ON drawer_view_minimized_pane
        WHEN (
            SELECT tab_shell.workspace_id
            FROM tab_arrangement
            JOIN tab_shell ON tab_shell.id = tab_arrangement.tab_id
            WHERE tab_arrangement.id = NEW.arrangement_id
        ) != (SELECT workspace_id FROM pane WHERE id = NEW.pane_id)
        BEGIN
            SELECT RAISE(ABORT, 'drawer_view_minimized_pane pane must belong to arrangement workspace');
        END
        """,
        """
        CREATE INDEX idx_tab_shell_workspace_id ON tab_shell(workspace_id)
        """,
    ]

}
