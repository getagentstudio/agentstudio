import Foundation
import GRDB

/// Puts a current core database back in the shape builds before migration
/// 020 wrote, so the next boot runs 020 on real rows the app saved.
enum LegacyBrowserDatabaseFixture {
    /// Puts the browser tables back in the schema builds before 020 wrote,
    /// foreign key and both triggers included, and forgets 020 so the next
    /// boot runs it on the existing rows.
    nonisolated static func rewriteBrowserTablesToLegacySchema(at url: URL) throws {
        try DatabaseQueue(path: url.path).write { database in
            try database.execute(
                sql: """
                    CREATE TABLE legacy_pane_content_webview (
                        pane_id TEXT PRIMARY KEY REFERENCES pane(id) ON DELETE CASCADE,
                        url TEXT NOT NULL,
                        title TEXT NOT NULL,
                        show_navigation INTEGER NOT NULL
                    )
                    """)
            try database.execute(
                sql: """
                    INSERT INTO legacy_pane_content_webview(pane_id, url, title, show_navigation)
                    SELECT browser.pane_id, webview.url, webview.title, browser.show_navigation
                    FROM pane_content_browser AS browser
                    JOIN pane_content_webview AS webview ON webview.id = browser.active_webview_id
                    """)
            try database.execute(sql: "DROP TABLE pane_content_webview")
            try database.execute(sql: "DROP TABLE pane_content_browser")
            try database.execute(sql: "ALTER TABLE legacy_pane_content_webview RENAME TO pane_content_webview")
            for (name, event) in [
                ("pane_content_webview_matches_pane_content_type", "INSERT"),
                ("pane_content_webview_update_matches_pane_content_type", "UPDATE OF pane_id"),
            ] {
                try database.execute(
                    sql: """
                        CREATE TRIGGER \(name)
                        BEFORE \(event) ON pane_content_webview
                        WHEN (SELECT content_type FROM pane WHERE id = NEW.pane_id) != 'browser'
                        BEGIN
                            SELECT RAISE(ABORT, 'pane_content_webview requires browser pane');
                        END
                        """)
            }
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '020_browser_webviews'")
        }
    }

    /// Rewrites every browser pane state in every available undo payload to the
    /// shape builds before 020 wrote, and returns how many browser panes the
    /// payloads hold, counted by their `"type":"webview"` content marker.
    nonisolated static func rewriteUndoBrowserStatesToLegacyShape(at url: URL) throws -> Int {
        try DatabaseQueue(path: url.path).write { database in
            var markers = 0
            let rows = try Row.fetchAll(
                database, sql: "SELECT close_id, snapshot_payload FROM workspace_undo_close WHERE state = 'available'")
            for row in rows {
                let payload: Data = row["snapshot_payload"]
                let rawText = String(bytes: payload, encoding: .utf8) ?? ""
                markers += rawText.components(separatedBy: "\"type\":\"webview\"").count - 1
                let json = try JSONSerialization.jsonObject(with: payload)
                let legacy = legacyBrowserStates(in: json)
                let rewritten = try JSONSerialization.data(withJSONObject: legacy)
                try database.execute(
                    sql: "UPDATE workspace_undo_close SET snapshot_payload = ? WHERE close_id = ?",
                    arguments: [rewritten, row["close_id"] as DatabaseValue])
            }
            return markers
        }
    }

    private nonisolated static func legacyBrowserStates(in value: Any) -> Any {
        if var object = value as? [String: Any] {
            if object["type"] as? String == "webview", let state = object["state"] as? [String: Any],
                let tabs = state["tabs"] as? [[String: Any]], let activeId = state["activeTabId"] as? String,
                let active = tabs.first(where: { $0["id"] as? String == activeId })
            {
                object["state"] = [
                    "url": active["url"] as Any, "title": active["title"] as Any,
                    "showNavigation": state["showNavigation"] as Any,
                ]
                return object
            }
            return object.mapValues(legacyBrowserStates(in:))
        }
        if let array = value as? [Any] { return array.map(legacyBrowserStates(in:)) }
        return value
    }
}
