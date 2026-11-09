import Foundation

extension WorkspaceCoreMigrations {
    /// A browser pane contains webviews: one `pane_content_browser` row per
    /// browser pane and one `pane_content_webview` row per tab. Each existing
    /// browser becomes a browser with one webview that reuses the pane id.
    /// No triggers, foreign keys or cascades; deleting panes clears both tables
    /// in Swift, in the same transaction.
    ///
    /// An available undo record whose payload holds a browser in the old shape
    /// can't be decoded any more, and one unreadable record fails the whole
    /// undo load, so each one expires. `snapshot_payload` is a BLOB, so the
    /// match is on bytes, not `LIKE`.
    static let browserWebviewsStatements: [String] = [
        "ALTER TABLE pane_content_webview RENAME TO pane_content_webview_old",
        """
        CREATE TABLE pane_content_browser (
            pane_id           TEXT PRIMARY KEY,
            active_webview_id TEXT NOT NULL,
            show_navigation   INTEGER NOT NULL CHECK (show_navigation IN (0, 1))
        )
        """,
        """
        CREATE TABLE pane_content_webview (
            id              TEXT PRIMARY KEY,
            browser_pane_id TEXT NOT NULL,
            position        INTEGER NOT NULL,
            url             TEXT NOT NULL,
            title           TEXT NOT NULL
        )
        """,
        "CREATE INDEX pane_content_webview_by_browser ON pane_content_webview(browser_pane_id, position)",
        """
        INSERT INTO pane_content_browser (pane_id, active_webview_id, show_navigation)
        SELECT pane_id, pane_id, show_navigation FROM pane_content_webview_old
        """,
        """
        INSERT INTO pane_content_webview (id, browser_pane_id, position, url, title)
        SELECT pane_id, pane_id, 0, url, title FROM pane_content_webview_old
        """,
        // Its two triggers go with it.
        "DROP TABLE pane_content_webview_old",
        """
        UPDATE workspace_undo_close SET state = 'expired', snapshot_payload = NULL
        WHERE state = 'available' AND instr(snapshot_payload, CAST('"type":"webview"' AS BLOB)) > 0
        """,
    ]
}
