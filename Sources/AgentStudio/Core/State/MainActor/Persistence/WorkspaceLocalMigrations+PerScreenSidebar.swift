import GRDB

extension WorkspaceLocalMigrations {
    static func registerPerScreenSidebarOrganizationMigration(in migrator: inout DatabaseMigrator) {
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
}
