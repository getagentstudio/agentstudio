import Foundation
import os

/// Browsers live only in drawers. A workspace saved before that rule can hold
/// browsers in the main layout; this pure step removes them from the loaded
/// snapshot before composition prepares it. A browser in a tab goes exactly as
/// closing that pane does: what it owns goes with it, and a tab it leaves empty
/// closes. A backgrounded or orphaned browser that no tab holds goes with its
/// drawer's panes; other recoverable panes stay. The next ordinary save
/// persists the result, so the step needs no one-time flag.
enum WorkspaceMainLayoutBrowserRemoval {
    private static let logger = Logger(subsystem: "com.agentstudio", category: "WorkspaceMainLayoutBrowserRemoval")

    static func removingMainLayoutBrowsers(from snapshot: WorkspaceSQLiteSnapshot) -> WorkspaceSQLiteSnapshot {
        var workspace = snapshot
        var attemptedPaneIDs = Set<UUID>()
        while let target = nextMainLayoutBrowser(in: workspace, skipping: attemptedPaneIDs) {
            attemptedPaneIDs.insert(target.paneID)
            do {
                workspace = try WorkspaceUndoComposition.applyingClose(
                    in: workspace, tabID: target.tabID, paneID: target.paneID
                ).workspace
            } catch {
                logger.error(
                    "Could not remove main-layout browser \(target.paneID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return removingUnownedMainLayoutBrowsers(from: workspace)
    }

    /// No tab holds these browsers, so there is no close to replay: each goes
    /// with the panes its drawer owns.
    private static func removingUnownedMainLayoutBrowsers(
        from workspace: WorkspaceSQLiteSnapshot
    ) -> WorkspaceSQLiteSnapshot {
        let tabPaneIDs = Set(workspace.tabs.flatMap(\.allPaneIds))
        let unownedBrowserIDs = Set(
            workspace.panes.compactMap { pane -> UUID? in
                guard !pane.isDrawerChild, case .webview = pane.content, !tabPaneIDs.contains(pane.id) else {
                    return nil
                }
                return pane.id
            }
        )
        guard !unownedBrowserIDs.isEmpty else { return workspace }
        var updated = workspace
        updated.panes.removeAll { pane in
            if unownedBrowserIDs.contains(pane.id) { return true }
            guard case .drawerChild(let parentPaneID) = pane.kind else { return false }
            return unownedBrowserIDs.contains(parentPaneID)
        }
        return updated
    }

    private static func nextMainLayoutBrowser(
        in workspace: WorkspaceSQLiteSnapshot,
        skipping attemptedPaneIDs: Set<UUID>
    ) -> (tabID: UUID, paneID: UUID)? {
        let mainLayoutBrowserIDs = Set(
            workspace.panes.compactMap { pane -> UUID? in
                guard !pane.isDrawerChild, case .webview = pane.content else { return nil }
                return pane.id
            }
        ).subtracting(attemptedPaneIDs)
        guard !mainLayoutBrowserIDs.isEmpty else { return nil }
        for tab in workspace.tabs {
            if let paneID = tab.allPaneIds.first(where: mainLayoutBrowserIDs.contains) {
                return (tab.id, paneID)
            }
        }
        return nil
    }
}
