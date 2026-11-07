import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("WorkspaceCoreMigrationTests")
struct WorkspaceCoreMigrationTests {
    @Test("merging independent schema steps preserves either branch's existing database", arguments: [true, false])
    func mergingIndependentSchemaStepsPreservesExistingDatabase(journalAlreadyApplied: Bool) throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrator.migrate(databaseQueue, upTo: "016_add_pane_association_facets")
        let workspaceID = UUIDv7.generate().uuidString
        try databaseQueue.write { database in
            try database.execute(
                sql: "INSERT INTO workspace(id, name, created_at, updated_at) VALUES (?, 'Preserved', 1, 1)",
                arguments: [workspaceID])
        }
        var branchMigrator = DatabaseMigrator()
        if journalAlreadyApplied {
            branchMigrator.registerMigration("017_create_session_ownership_journal") { database in
                for statement in WorkspaceCoreMigrations.createSessionOwnershipJournalStatements {
                    try database.execute(sql: statement)
                }
                try database.execute(
                    sql: "INSERT INTO workspace_terminal_session_ownership(session_id) VALUES ('preserved-session')")
            }
        } else {
            branchMigrator.registerMigration("017_add_independent_sidebar_pins") { database in
                for statement in WorkspaceCoreMigrations.addIndependentSidebarPinsStatements {
                    try database.execute(sql: statement)
                }
            }
        }
        try branchMigrator.migrate(databaseQueue)

        try WorkspaceCoreMigrations.migrate(databaseQueue)
        try WorkspaceCoreMigrations.migrate(databaseQueue)

        try databaseQueue.read { database throws in
            #expect(
                try String.fetchOne(
                    database, sql: "SELECT name FROM workspace WHERE id = ?",
                    arguments: [workspaceID]) == "Preserved")
            #expect(try database.tableExists("workspace_terminal_session_ownership"))
            #expect(try database.tableExists("workspace_undo_close"))
            #expect(try database.tableExists("workspace_undo_close_member"))
            #expect(try database.columns(in: "pane").contains { $0.name == "is_pinned" })
            #expect(try database.columns(in: "repo").contains { $0.name == "is_pinned" })
            #expect(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
            if journalAlreadyApplied {
                #expect(
                    try String.fetchOne(
                        database,
                        sql:
                            "SELECT cleanup_state FROM workspace_terminal_session_ownership WHERE session_id = 'preserved-session'"
                    )
                        == "owned")
            }
            #expect(try WorkspaceCoreMigrations.migrator.hasCompletedMigrations(database))
        }
    }

    @Test("fresh core database creates workspace graph tables")
    func freshCoreDatabaseCreatesWorkspaceGraphTables() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()

        try WorkspaceCoreMigrations.migrate(databaseQueue)

        let tableNames = try databaseQueue.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table'
                    ORDER BY name
                    """
            )
        }

        #expect(tableNames.contains("workspace"))
        #expect(tableNames.contains("app_workspace_selection"))
        #expect(tableNames.contains("repo"))
        #expect(tableNames.contains("repo_tag"))
        #expect(tableNames.contains("worktree"))
        #expect(!tableNames.contains("worktree_tag"))
        #expect(tableNames.contains("pane"))
        #expect(tableNames.contains("pane_content_terminal"))
        #expect(!tableNames.contains("pane_tag"))
        #expect(tableNames.contains("drawer"))
        #expect(tableNames.contains("drawer_pane"))
        #expect(tableNames.contains("tab_shell"))
        #expect(tableNames.contains("tab_pane"))
        #expect(tableNames.contains("tab_arrangement"))
        #expect(tableNames.contains("arrangement_layout_pane"))
        #expect(tableNames.contains("arrangement_layout_divider"))
        #expect(tableNames.contains("arrangement_minimized_pane"))
        #expect(tableNames.contains("arrangement_drawer_view"))
        #expect(tableNames.contains("drawer_view_layout_pane"))
        #expect(tableNames.contains("drawer_view_layout_divider"))
        #expect(tableNames.contains("drawer_view_minimized_pane"))
        #expect(!tableNames.contains("legacy_workspace_import_status"))
        #expect(!tableNames.contains("workspace_sqlite_snapshot_status"))

        let repoColumns = try databaseQueue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(repo)")
                .map { row in row["name"] as String }
        }
        let worktreeColumns = try databaseQueue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(worktree)")
                .map { row in row["name"] as String }
        }
        let tabShellColumns = try databaseQueue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(tab_shell)")
                .map { row in row["name"] as String }
        }
        #expect(!repoColumns.contains("color_hex"))
        #expect(!repoColumns.contains("workspace_id"))
        #expect(!worktreeColumns.contains("color_hex"))
        #expect(!worktreeColumns.contains("workspace_id"))
        #expect(tabShellColumns.contains("color_hex"))
        let tabArrangementColumns = try databaseQueue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(tab_arrangement)")
                .map { row in row["name"] as String }
        }
        #expect(!tabArrangementColumns.contains("shows_minimized_panes"))
    }

    @Test("migration identifiers are stable and run once")
    func migrationIdentifiersAreStableAndRunOnce() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()

        try WorkspaceCoreMigrations.migrate(databaseQueue)
        try WorkspaceCoreMigrations.migrate(databaseQueue)

        let completedMigrations = try databaseQueue.read { database in
            try WorkspaceCoreMigrations.migrator.completedMigrations(database)
        }

        #expect(
            completedMigrations == [
                "001_create_workspace",
                "002_create_repo_worktree_topology",
                "003_create_panes",
                "004_create_tabs_and_arrangements",
                "005_repair_tab_graph_layout_storage",
                "006_create_workspace_sqlite_snapshot_status",
                "007_stage_workspace_sqlite_snapshot_status",
                "008_add_zmx_session_id",
                "009_drop_pane_source_binding",
                "010_repository_topology_tags_and_tab_color",
                "011_add_repo_sidebar_metadata",
                "012_background_active_unowned_layout_panes",
                "013_globalize_repository_topology",
                "014_drop_shows_minimized_panes",
                "015_drop_pane_topology_facets",
                "016_add_pane_association_facets",
                "017_add_independent_sidebar_pins",
                "017_create_session_ownership_journal",
                "018_repository_location_absence",
                "019_browser_webviews",
            ]
        )
    }

    @Test("migration 012 backgrounds only historical active unowned top-level panes")
    func migration012BackgroundsOnlyHistoricalActiveUnownedTopLevelPanes() throws {
        let fixture = try makeMigration012Fixture()
        try WorkspaceCoreMigrations.migrator.migrate(
            fixture.databaseQueue,
            upTo: "012_background_active_unowned_layout_panes"
        )
        try assertMigration012Result(fixture)
    }

    @Test("migration 009 refits pane source columns as facet columns")
    func migration009RefitsPaneSourceColumnsAsFacetColumns() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        let workspaceId = UUID().uuidString
        let repoId = UUID().uuidString
        let worktreeId = UUID().uuidString
        let paneId = UUID().uuidString

        try WorkspaceCoreMigrations.migrator.migrate(databaseQueue, upTo: "008_add_zmx_session_id")
        try databaseQueue.write { database in
            try insertWorkspace(database, workspaceId: workspaceId)
            try insertRepo(database, workspaceId: workspaceId, repoId: repoId)
            try insertWorktree(database, workspaceId: workspaceId, repoId: repoId, worktreeId: worktreeId)
            try insertPaneBeforeSourceBindingMigration(
                database,
                workspaceId: workspaceId,
                paneId: paneId,
                sourceRepoId: repoId,
                sourceWorktreeId: worktreeId
            )
            try database.execute(
                sql: """
                    INSERT INTO pane_content_terminal(pane_id, provider, lifetime, zmx_session_id)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [paneId, SessionProvider.zmx.rawValue, SessionLifetime.persistent.rawValue, "as-anchor"]
            )
        }

        try WorkspaceCoreMigrations.migrator.migrate(
            databaseQueue,
            upTo: "009_drop_pane_source_binding"
        )

        let columnNames = try databaseQueue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(pane)")
                .map { row in row["name"] as String }
        }
        #expect(columnNames.contains("facet_repo_id"))
        #expect(columnNames.contains("facet_worktree_id"))
        #expect(!columnNames.contains("source_kind"))
        #expect(!columnNames.contains("source_repo_id"))
        #expect(!columnNames.contains("source_worktree_id"))

        let row = try databaseQueue.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT facet_repo_id, facet_worktree_id, launch_directory, cwd
                    FROM pane
                    WHERE id = ?
                    """,
                arguments: [paneId]
            )
        }
        #expect(row?["facet_repo_id"] as String? == repoId)
        #expect(row?["facet_worktree_id"] as String? == worktreeId)
        #expect(row?["launch_directory"] as String? == "/tmp")
        #expect(row?["cwd"] as String? == "/tmp")
    }

    @Test("snapshot staging migration preserves existing completion token")
    func snapshotStagingMigrationPreservesExistingCompletionToken() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        let workspaceId = UUID().uuidString
        let completedAt = 1_700_004_000.0
        try WorkspaceCoreMigrations.migrator.migrate(
            databaseQueue,
            upTo: "006_create_workspace_sqlite_snapshot_status"
        )
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workspace(id, name, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [workspaceId, "Migrated Completion", 1.0, completedAt]
            )
            try database.execute(
                sql: """
                    INSERT INTO workspace_sqlite_snapshot_status(workspace_id, completed_at)
                    VALUES (?, ?)
                    """,
                arguments: [workspaceId, completedAt]
            )
        }

        try WorkspaceCoreMigrations.migrator.migrate(
            databaseQueue,
            upTo: "007_stage_workspace_sqlite_snapshot_status"
        )

        let tokens = try databaseQueue.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT staged_at, completed_at
                    FROM workspace_sqlite_snapshot_status
                    WHERE workspace_id = ?
                    """,
                arguments: [workspaceId]
            )
        }
        #expect((tokens?["staged_at"] as Double?) == completedAt)
        #expect((tokens?["completed_at"] as Double?) == completedAt)
    }

    @Test("workspace selection round trips")
    func workspaceSelectionRoundTrips() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID()

        let restoredActiveWorkspaceId = try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workspace(id, name, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    workspaceId.uuidString,
                    "SQLite Workspace",
                    1.0,
                    1.0,
                ]
            )
            try database.execute(
                sql: "UPDATE app_workspace_selection SET active_workspace_id = ? WHERE singleton_id = 1",
                arguments: [workspaceId.uuidString]
            )
            return try String.fetchOne(
                database,
                sql: "SELECT active_workspace_id FROM app_workspace_selection WHERE singleton_id = 1"
            )
        }

        #expect(restoredActiveWorkspaceId == workspaceId.uuidString)
    }

    @Test("global worktree rejects a dangling repository reference")
    func globalWorktreeRejectsDanglingRepositoryReference() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)

        expectDatabaseError(containing: "FOREIGN KEY constraint failed") {
            try databaseQueue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO worktree(
                            id, repo_id, name, path, stable_key, is_main_worktree
                        )
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        UUID().uuidString,
                        "missing-repository-worktree",
                        "/tmp/missing-repository-worktree",
                        "missing-repository-worktree",
                        0,
                    ]
                )
            }
        }
    }

    @Test("pane content storage uses live pane graph vocabulary")
    func paneContentStorageUsesLivePaneGraphVocabulary() {
        #expect(SQLitePaneContentTypeStorage.storageValue(for: .terminal) == "terminal")
        #expect(SQLitePaneContentTypeStorage.storageValue(for: .browser) == "browser")
        #expect(SQLitePaneContentTypeStorage.storageValue(for: .diff) == "diff")
        #expect(SQLitePaneContentTypeStorage.storageValue(for: .editor) == "editor")
        #expect(SQLitePaneContentTypeStorage.storageValue(for: .review) == "review")
        #expect(SQLitePaneContentTypeStorage.storageValue(for: .agent) == "agent")
        #expect(SQLitePaneContentTypeStorage.storageValue(for: .codeViewer) == "codeViewer")
        #expect(SQLitePaneContentTypeStorage.storageValue(for: .plugin("acme")) == "plugin:acme")
    }

    @Test("pane content rejects mismatched payload table")
    func paneContentRejectsMismatchedPayloadTable() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString

        // The browser tables carry no triggers since 019; the code-viewer table still enforces its content type.
        expectDatabaseError(containing: "pane_content_code_viewer requires codeViewer pane") {
            try databaseQueue.write { database in
                try insertWorkspace(database, workspaceId: workspaceId)
                try insertPane(database, workspaceId: workspaceId, paneId: paneId)
                try database.execute(
                    sql: """
                        INSERT INTO pane_content_terminal(pane_id, provider, lifetime)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [paneId, "zmx", "persistent"]
                )
                try database.execute(
                    sql: """
                        INSERT INTO pane_content_code_viewer(pane_id, file_path, scroll_to_line)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [paneId, "/tmp/mismatched.swift", 1]
                )
            }
        }
    }

    @Test("browser pane content uses the browser and webview tables")
    func browserPaneContentUsesWebviewPayloadTable() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString

        let storedURL = try databaseQueue.write { database in
            try insertWorkspace(database, workspaceId: workspaceId)
            try insertPane(
                database,
                workspaceId: workspaceId,
                paneId: paneId,
                contentType: SQLitePaneContentTypeStorage.storageValue(for: .browser)
            )
            try database.execute(
                sql: """
                    INSERT INTO pane_content_browser(pane_id, active_webview_id, show_navigation)
                    VALUES (?, ?, ?)
                    """,
                arguments: [paneId, paneId, 1]
            )
            try database.execute(
                sql: """
                    INSERT INTO pane_content_webview(id, browser_pane_id, position, url, title)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [paneId, paneId, 0, "https://example.com", "Example"]
            )
            return try String.fetchOne(
                database, sql: "SELECT url FROM pane_content_webview WHERE browser_pane_id = ?",
                arguments: [paneId])
        }

        #expect(storedURL == "https://example.com")
    }

    @Test("pane content type is immutable")
    func paneContentTypeIsImmutable() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString

        expectDatabaseError(containing: "pane content_type is immutable") {
            try databaseQueue.write { database in
                try insertWorkspace(database, workspaceId: workspaceId)
                try insertPane(database, workspaceId: workspaceId, paneId: paneId)
                try database.execute(
                    sql: "UPDATE pane SET content_type = ? WHERE id = ?",
                    arguments: [SQLitePaneContentTypeStorage.storageValue(for: .browser), paneId]
                )
            }
        }
    }

    @Test("pane content type rejects unsupported storage tokens")
    func paneContentTypeRejectsUnsupportedStorageTokens() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString

        expectDatabaseError(containing: "pane content_type is not supported") {
            try databaseQueue.write { database in
                try insertWorkspace(database, workspaceId: workspaceId)
                try insertPane(database, workspaceId: workspaceId, paneId: paneId, contentType: "webview")
            }
        }
    }

    @Test("tab pane membership enforces one owning tab per pane")
    func tabPaneMembershipEnforcesOneOwningTabPerPane() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString
        let firstTabId = UUID().uuidString
        let secondTabId = UUID().uuidString

        expectDatabaseError(containing: "UNIQUE constraint failed: tab_pane.pane_id") {
            try databaseQueue.write { database in
                try insertWorkspace(database, workspaceId: workspaceId)
                try insertPane(database, workspaceId: workspaceId, paneId: paneId)
                try insertTabShell(database, workspaceId: workspaceId, tabId: firstTabId, name: "First", sortIndex: 0)
                try insertTabShell(database, workspaceId: workspaceId, tabId: secondTabId, name: "Second", sortIndex: 1)
                try database.execute(
                    sql: """
                        INSERT INTO tab_pane(tab_id, pane_id, sort_index)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [firstTabId, paneId, 0]
                )
                try database.execute(
                    sql: """
                        INSERT INTO tab_pane(tab_id, pane_id, sort_index)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [secondTabId, paneId, 0]
                )
            }
        }
    }

    @Test("tab arrangement enforces one default per tab")
    func tabArrangementEnforcesOneDefaultPerTab() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString
        let tabId = UUID().uuidString

        expectDatabaseError(containing: "UNIQUE constraint failed: tab_arrangement.tab_id") {
            try databaseQueue.write { database in
                try insertWorkspace(database, workspaceId: workspaceId)
                try insertTabShell(database, workspaceId: workspaceId, tabId: tabId, name: "Workspace", sortIndex: 0)
                try insertTabArrangement(
                    database, tabId: tabId, arrangementId: UUID().uuidString, name: "Default", isDefault: true,
                    sortIndex: 0)
                try insertTabArrangement(
                    database, tabId: tabId, arrangementId: UUID().uuidString, name: "Also Default", isDefault: true,
                    sortIndex: 1)
            }
        }
    }

    @Test("drawer table enforces one drawer per parent pane")
    func drawerTableEnforcesOneDrawerPerParentPane() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString
        let parentPaneId = UUID().uuidString

        expectDatabaseError(containing: "UNIQUE constraint failed: drawer.parent_pane_id") {
            try databaseQueue.write { database in
                try insertWorkspace(database, workspaceId: workspaceId)
                try insertPane(database, workspaceId: workspaceId, paneId: parentPaneId)
                try insertDrawer(
                    database,
                    drawerId: UUID().uuidString,
                    parentPaneId: parentPaneId,
                    title: "First Drawer"
                )
                try insertDrawer(
                    database,
                    drawerId: UUID().uuidString,
                    parentPaneId: parentPaneId,
                    title: "Second Drawer"
                )
            }
        }
    }

    @Test("drawer pane membership enforces one owning drawer per pane")
    func drawerPaneMembershipEnforcesOneOwningDrawerPerPane() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(databaseQueue)
        let workspaceId = UUID().uuidString
        let firstParentPaneId = UUID().uuidString
        let secondParentPaneId = UUID().uuidString
        let childPaneId = UUID().uuidString
        let firstDrawerId = UUID().uuidString
        let secondDrawerId = UUID().uuidString

        expectDatabaseError(containing: "UNIQUE constraint failed: drawer_pane.pane_id") {
            try databaseQueue.write { database in
                try insertWorkspace(database, workspaceId: workspaceId)
                try insertPane(database, workspaceId: workspaceId, paneId: firstParentPaneId)
                try insertPane(database, workspaceId: workspaceId, paneId: secondParentPaneId)
                try insertPane(database, workspaceId: workspaceId, paneId: childPaneId)
                try insertDrawer(
                    database, drawerId: firstDrawerId, parentPaneId: firstParentPaneId, title: "First Drawer")
                try insertDrawer(
                    database,
                    drawerId: secondDrawerId,
                    parentPaneId: secondParentPaneId,
                    title: "Second Drawer"
                )
                try database.execute(
                    sql: """
                        INSERT INTO drawer_pane(drawer_id, pane_id, sort_index)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [firstDrawerId, childPaneId, 0]
                )
                try database.execute(
                    sql: """
                        INSERT INTO drawer_pane(drawer_id, pane_id, sort_index)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [secondDrawerId, childPaneId, 0]
                )
            }
        }
    }

    private func expectDatabaseError(
        containing expectedMessage: String,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected DatabaseError containing '\(expectedMessage)'")
        } catch let error as DatabaseError {
            #expect(error.message?.contains(expectedMessage) == true)
        } catch {
            Issue.record("Expected DatabaseError containing '\(expectedMessage)', got \(error)")
        }
    }

    private func insertWorkspace(_ database: Database, workspaceId: String) throws {
        try database.execute(
            sql: """
                INSERT INTO workspace(id, name, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                workspaceId,
                "SQLite Workspace",
                1.0,
                1.0,
            ]
        )
    }

    private func insertRepo(
        _ database: Database,
        workspaceId: String,
        repoId: String,
        stableKey: String = "repo"
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO repo(id, workspace_id, name, repo_path, stable_key, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                repoId,
                workspaceId,
                stableKey,
                "/tmp/\(stableKey)",
                stableKey,
                1.0,
            ]
        )
    }

    private func insertWorktree(
        _ database: Database,
        workspaceId: String,
        repoId: String,
        worktreeId: String,
        stableKey: String = "worktree"
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO worktree(id, workspace_id, repo_id, name, path, stable_key, is_main_worktree)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                worktreeId,
                workspaceId,
                repoId,
                stableKey,
                "/tmp/\(stableKey)",
                stableKey,
                0,
            ]
        )
    }

    private func insertPane(
        _ database: Database,
        workspaceId: String,
        paneId: String,
        contentType: String = SQLitePaneContentTypeStorage.storageValue(for: .terminal),
        parentPaneId: String? = nil
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO pane(
                    id, workspace_id, content_type, execution_backend,
                    launch_directory, title, cwd,
                    residency_kind, kind, parent_pane_id, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                paneId,
                workspaceId,
                contentType,
                "zmx",
                "/tmp",
                "Terminal",
                "/tmp",
                "active",
                parentPaneId == nil ? "leaf" : "drawerChild",
                parentPaneId,
                1.0,
                1.0,
            ]
        )
    }

    private func insertPaneBeforeTopologyFacetDrop(
        _ database: Database,
        workspaceId: String,
        paneId: String,
        facetRepoId: String? = nil,
        facetWorktreeId: String? = nil,
        parentPaneId: String? = nil
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO pane(
                    id, workspace_id, content_type, execution_backend,
                    facet_repo_id, facet_worktree_id, launch_directory, title, cwd,
                    residency_kind, kind, parent_pane_id, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                paneId,
                workspaceId,
                SQLitePaneContentTypeStorage.storageValue(for: .terminal),
                "zmx",
                facetRepoId,
                facetWorktreeId,
                "/tmp",
                "Terminal",
                "/tmp",
                "active",
                parentPaneId == nil ? "leaf" : "drawerChild",
                parentPaneId,
                1.0,
                1.0,
            ]
        )
    }

    private func insertPaneBeforeSourceBindingMigration(
        _ database: Database,
        workspaceId: String,
        paneId: String,
        contentType: String = SQLitePaneContentTypeStorage.storageValue(for: .terminal),
        sourceRepoId: String? = nil,
        sourceWorktreeId: String? = nil,
        parentPaneId: String? = nil
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO pane(
                    id, workspace_id, content_type, execution_backend, source_kind,
                    source_repo_id, source_worktree_id, launch_directory, title, cwd,
                    residency_kind, kind, parent_pane_id, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                paneId,
                workspaceId,
                contentType,
                "zmx",
                "workspace",
                sourceRepoId,
                sourceWorktreeId,
                "/tmp",
                "Terminal",
                "/tmp",
                "active",
                parentPaneId == nil ? "leaf" : "drawerChild",
                parentPaneId,
                1.0,
                1.0,
            ]
        )
    }

    private func insertTabShell(
        _ database: Database,
        workspaceId: String,
        tabId: String,
        name: String,
        sortIndex: Int
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO tab_shell(id, workspace_id, name, sort_index)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [tabId, workspaceId, name, sortIndex]
        )
    }

    private func insertTabPane(
        _ database: Database,
        tabId: String,
        paneId: String,
        sortIndex: Int = 0
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO tab_pane(tab_id, pane_id, sort_index)
                VALUES (?, ?, ?)
                """,
            arguments: [tabId, paneId, sortIndex]
        )
    }

    private func insertTabArrangement(
        _ database: Database,
        tabId: String,
        arrangementId: String,
        name: String,
        isDefault: Bool,
        sortIndex: Int
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO tab_arrangement(id, tab_id, name, is_default, sort_index)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [arrangementId, tabId, name, isDefault ? 1 : 0, sortIndex]
        )
    }

    private func insertDrawer(
        _ database: Database,
        drawerId: String,
        parentPaneId: String,
        title _: String
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO drawer(id, parent_pane_id)
                VALUES (?, ?)
                """,
            arguments: [drawerId, parentPaneId]
        )
    }

    private func insertDrawerPane(
        _ database: Database,
        drawerId: String,
        paneId: String,
        sortIndex: Int = 0
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO drawer_pane(drawer_id, pane_id, sort_index)
                VALUES (?, ?, ?)
                """,
            arguments: [drawerId, paneId, sortIndex]
        )
    }

    private func tableExists(_ database: Database, tableName: String) throws -> Bool {
        try String.fetchOne(
            database,
            sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                AND name = ?
                """,
            arguments: [tableName]
        ) != nil
    }

}

private struct Migration012Fixture {
    let databaseQueue: DatabaseQueue
    let repoId: String
    let worktreeId: String
    let ownedPaneId: String
    let unownedLayoutPaneId: String
    let unownedLegacyLeafPaneId: String
    let malformedDrawerChildPaneId: String
    let malformedLayoutWithParentPaneId: String
}

extension WorkspaceCoreMigrationTests {
    fileprivate func makeMigration012Fixture() throws -> Migration012Fixture {
        let fixture = Migration012Fixture(
            databaseQueue: try SQLiteDatabaseFactory.makeInMemoryQueue(),
            repoId: UUID().uuidString,
            worktreeId: UUID().uuidString,
            ownedPaneId: UUID().uuidString,
            unownedLayoutPaneId: UUID().uuidString,
            unownedLegacyLeafPaneId: UUID().uuidString,
            malformedDrawerChildPaneId: UUID().uuidString,
            malformedLayoutWithParentPaneId: UUID().uuidString
        )
        let workspaceId = UUID().uuidString
        let tabId = UUID().uuidString

        try WorkspaceCoreMigrations.migrator.migrate(
            fixture.databaseQueue,
            upTo: "011_add_repo_sidebar_metadata"
        )
        try fixture.databaseQueue.write { database in
            try insertMigration012Rows(
                database,
                fixture: fixture,
                workspaceId: workspaceId,
                tabId: tabId
            )
        }
        return fixture
    }

    fileprivate func insertMigration012Rows(
        _ database: Database,
        fixture: Migration012Fixture,
        workspaceId: String,
        tabId: String
    ) throws {
        try insertWorkspace(database, workspaceId: workspaceId)
        try insertRepo(database, workspaceId: workspaceId, repoId: fixture.repoId)
        try insertWorktree(
            database,
            workspaceId: workspaceId,
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId
        )
        try insertMigration012Panes(database, fixture: fixture, workspaceId: workspaceId)
        try insertTabShell(database, workspaceId: workspaceId, tabId: tabId, name: "Owned", sortIndex: 0)
        try insertTabPane(database, tabId: tabId, paneId: fixture.ownedPaneId)
    }

    fileprivate func insertMigration012Panes(
        _ database: Database,
        fixture: Migration012Fixture,
        workspaceId: String
    ) throws {
        let topLevelPaneIds = [
            fixture.ownedPaneId,
            fixture.unownedLayoutPaneId,
            fixture.unownedLegacyLeafPaneId,
        ]
        for paneId in topLevelPaneIds {
            try insertPaneBeforeTopologyFacetDrop(
                database,
                workspaceId: workspaceId,
                paneId: paneId,
                facetRepoId: paneId == fixture.unownedLegacyLeafPaneId ? nil : fixture.repoId,
                facetWorktreeId: paneId == fixture.unownedLegacyLeafPaneId ? nil : fixture.worktreeId
            )
        }
        for paneId in [fixture.malformedDrawerChildPaneId, fixture.malformedLayoutWithParentPaneId] {
            try insertPaneBeforeTopologyFacetDrop(
                database,
                workspaceId: workspaceId,
                paneId: paneId,
                parentPaneId: fixture.ownedPaneId
            )
        }
        try database.execute(
            sql: "UPDATE pane SET kind = 'layout', title = ?, note = ?, cwd = ? WHERE id = ?",
            arguments: ["Preserved title", "Preserved note", "/tmp/preserved-cwd", fixture.unownedLayoutPaneId]
        )
        try database.execute(
            sql: "UPDATE pane SET kind = 'layout' WHERE id = ?",
            arguments: [fixture.malformedLayoutWithParentPaneId]
        )
        for paneId in topLevelPaneIds
            + [fixture.malformedDrawerChildPaneId, fixture.malformedLayoutWithParentPaneId]
        {
            try database.execute(
                sql: """
                    INSERT INTO pane_content_terminal(pane_id, provider, lifetime, zmx_session_id)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [paneId, "zmx", "persistent", "session-\(paneId)"]
            )
        }
    }

    fileprivate func assertMigration012Result(_ fixture: Migration012Fixture) throws {
        let paneRows = try fixture.databaseQueue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT pane.*, pane_content_terminal.provider,
                           pane_content_terminal.lifetime, pane_content_terminal.zmx_session_id
                    FROM pane
                    JOIN pane_content_terminal ON pane_content_terminal.pane_id = pane.id
                    ORDER BY pane.id
                    """
            )
        }
        let paneRowsById = Dictionary(uniqueKeysWithValues: paneRows.map { ($0["id"] as String, $0) })

        #expect(paneRowsById[fixture.unownedLayoutPaneId]?["residency_kind"] as String? == "backgrounded")
        #expect(paneRowsById[fixture.unownedLegacyLeafPaneId]?["residency_kind"] as String? == "backgrounded")
        #expect(paneRowsById[fixture.ownedPaneId]?["residency_kind"] as String? == "active")
        #expect(paneRowsById[fixture.malformedDrawerChildPaneId]?["residency_kind"] as String? == "active")
        #expect(paneRowsById[fixture.malformedLayoutWithParentPaneId]?["residency_kind"] as String? == "active")

        let migratedLayoutPane = try #require(paneRowsById[fixture.unownedLayoutPaneId])
        #expect(migratedLayoutPane["kind"] as String? == "layout")
        #expect(migratedLayoutPane["facet_repo_id"] as String? == fixture.repoId)
        #expect(migratedLayoutPane["facet_worktree_id"] as String? == fixture.worktreeId)
        #expect(migratedLayoutPane["title"] as String? == "Preserved title")
        #expect(migratedLayoutPane["note"] as String? == "Preserved note")
        #expect(migratedLayoutPane["cwd"] as String? == "/tmp/preserved-cwd")
        #expect(migratedLayoutPane["provider"] as String? == "zmx")
        #expect(migratedLayoutPane["lifetime"] as String? == "persistent")
        #expect(migratedLayoutPane["zmx_session_id"] as String? == "session-\(fixture.unownedLayoutPaneId)")
    }
}
