import Foundation
import os

/// Browsers live only in drawers. A workspace saved before that rule can hold
/// browsers in the main layout; this pure step removes them from the loaded
/// snapshot before composition prepares it, each exactly as closing that pane
/// does: what it owns goes with it, and a tab it leaves empty closes. The next
/// ordinary save persists the result, so the step needs no one-time flag.
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
        return workspace
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
