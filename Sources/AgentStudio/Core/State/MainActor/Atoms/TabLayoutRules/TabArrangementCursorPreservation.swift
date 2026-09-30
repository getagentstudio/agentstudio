import Foundation

/// Preserves cursor selections a human makes while a background drawer
/// terminal creation is still in flight, so its stale capture can't clobber
/// them when it finally publishes.
///
/// `WorkspaceSQLiteSaveCoordinator.commitTerminalCreation` captures workspace
/// state up front, then awaits off-main preparation and a SQLite save before
/// `WorkspaceMutationCoordinator.applyCommittedTerminalCreation` replaces the
/// tab's arrangement states from that capture. Graph fields (layout,
/// `allPaneIds`, drawer membership) are serialized behind the same awaited
/// save and can't race it, but cursor writes — for example selecting a
/// different drawer child — go straight to `WorkspaceTabArrangementAtom` and
/// aren't ordered against it. A background creation must not let its stale
/// capture undo a cursor a human set in that window. An interactive creation
/// is different: it's meant to select the child it just inserted, so its
/// captured cursors always win.
enum TabArrangementCursorPreservation {
    /// - Parameters:
    ///   - published: The arrangement state built from the just-committed
    ///     save's capture. Carries the newly inserted drawer child in its
    ///     graph fields (layout, `allPaneIds`, drawer membership).
    ///   - live: The tab's arrangement state as currently observed, or `nil`
    ///     when the tab is no longer present. A `nil` cursor inside it means
    ///     "nothing to preserve," not "clear the cursor."
    ///   - presentation: How the inserted child should present.
    ///     `.interactive` selects the child it just inserted, so
    ///     `published`'s cursors win outright; `.background` preserves any
    ///     live cursor that's still valid against `published`'s graph.
    static func committedDrawerInsertionState(
        published: TabArrangementState,
        live: TabArrangementState?,
        presentation: DrawerChildPresentation
    ) -> TabArrangementState {
        guard presentation == .background, let live else { return published }

        var preserved = published
        if preserved.arrangements.contains(where: { $0.id == live.activeArrangementId }) {
            preserved.activeArrangementId = live.activeArrangementId
        }

        for index in preserved.arrangements.indices {
            let arrangement = preserved.arrangements[index]
            guard let liveArrangement = live.arrangements.first(where: { $0.id == arrangement.id }) else {
                continue
            }
            if let liveActivePaneId = liveArrangement.activePaneId,
                arrangement.layout.contains(liveActivePaneId)
            {
                preserved.arrangements[index].activePaneId = liveActivePaneId
            }
            for (drawerId, drawerView) in arrangement.drawerViews {
                guard let liveActiveChildId = liveArrangement.drawerViews[drawerId]?.activeChildId,
                    drawerView.layout.contains(liveActiveChildId)
                else { continue }
                var preservedDrawerView = drawerView
                preservedDrawerView.activeChildId = liveActiveChildId
                preserved.arrangements[index].drawerViews[drawerId] = preservedDrawerView
            }
        }
        return preserved
    }
}
