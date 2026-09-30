import Foundation

/// A pane agent's authorization carried to the owner that applies its effect.
///
/// IPC authorization admits a request while the target is inside the agent's
/// own pane, but the effect runs later: behind queued gestures for layout, or
/// in the main-actor step that hands a command to a pane runtime. The owner
/// re-checks this assertion at that point, so a target that left the own pane
/// in between (detached, moved, parent changed) is refused rather than
/// applied.
package struct WorkspaceOwnPaneAssertion: Equatable, Hashable, Sendable {
    package let boundPaneId: UUID

    package init(boundPaneId: UUID) {
        self.boundPaneId = boundPaneId
    }

    /// The own pane is the bound pane and, when the bound pane is in the main
    /// layout, its drawer children. A drawer terminal owns only itself.
    package func admits(
        _ paneId: UUID,
        paneExists: (UUID) -> Bool,
        drawerParentOf: (UUID) -> UUID?
    ) -> Bool {
        guard paneExists(boundPaneId), paneExists(paneId) else { return false }
        if paneId == boundPaneId { return true }
        return drawerParentOf(boundPaneId) == nil && drawerParentOf(paneId) == boundPaneId
    }

    package func admits(_ paneId: UUID, state: ActionStateSnapshot) -> Bool {
        admits(
            paneId,
            paneExists: { state.knownPaneIds.contains($0) },
            drawerParentOf: { state.drawerParentPaneId(of: $0) }
        )
    }
}
