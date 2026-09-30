import Foundation

/// Direction for inserting a new pane into a pane strip.
/// Standalone type decoupled from any concrete view implementation.
package enum SplitNewDirection: Equatable, Codable, Hashable {
    case left, right, up, down
}

/// Direction for keyboard-driven pane resize.
package enum SplitResizeDirection: Equatable, Hashable, CustomStringConvertible {
    case up, down, left, right

    /// The Layout.SplitDirection axis this resize acts on.
    var axis: Layout.SplitDirection {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    package var description: String {
        switch self {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        }
    }
}

/// How creating a drawer child presents it. Interactive creation expands the
/// drawer, selects the child and focuses it; background creation leaves the
/// drawer's expansion, selection and keyboard focus exactly as they were.
package enum DrawerChildPresentation: Equatable, Hashable, Sendable {
    case interactive
    case background
}

/// What a drawer child created in the background holds. Drawers never hold
/// Bridge or code-viewer content, so neither is representable here.
package enum BackgroundDrawerChildContent: Equatable, Hashable {
    case terminal
    case webview(WebviewState)
}

/// Identifies where a pane being inserted comes from.
package enum PaneSource: Equatable, Hashable {
    /// Moving an existing pane from its current location
    case existingPane(paneId: UUID, sourceTabId: UUID)
    /// Creating a new terminal
    case newTerminal
    /// Creating a new browser pane with the requested state.
    case newWebview(WebviewState)
    /// Creating a new terminal at an explicit directory
    case newTerminalAtDirectory(URL)
}

package struct PaneInsertRequest: Equatable, Hashable {
    package let source: PaneSource
    package let targetTabId: UUID
    package let targetPaneId: UUID
    package let direction: SplitNewDirection
    package let sizingMode: DropSizingMode
}

package struct CrossTabPaneMoveRequest: Equatable, Hashable {
    package let paneId: UUID
    package let sourceTabId: UUID
    package let destTabId: UUID
    let targetPaneId: UUID
    let direction: Layout.SplitDirection
    let position: Layout.Position

    package init(
        paneId: UUID,
        sourceTabId: UUID,
        destTabId: UUID,
        targetPaneId: UUID,
        direction: Layout.SplitDirection,
        position: Layout.Position
    ) {
        self.paneId = paneId
        self.sourceTabId = sourceTabId
        self.destTabId = destTabId
        self.targetPaneId = targetPaneId
        self.direction = direction
        self.position = position
    }
}

/// Fully resolved action with all target IDs explicit.
/// Every action that modifies tab/pane state flows through this type.
///
/// "Resolved" means no "active tab" or "current pane" references —
/// all targets are concrete UUIDs computed during the resolution step.
package enum WorkspaceActionCommand: Equatable, Hashable {
    // Tab lifecycle
    case selectTab(tabId: UUID)
    case closeTab(tabId: UUID)
    case breakUpTab(tabId: UUID)
    case renameTab(tabId: UUID, name: String)

    // Pane lifecycle
    case closePane(tabId: UUID, paneId: UUID)
    case extractPaneToTab(tabId: UUID, paneId: UUID)

    // Split operations
    case insertPaneRequest(PaneInsertRequest)
    case resizePane(tabId: UUID, splitId: UUID, ratio: Double)
    case resizeVisiblePanePair(tabId: UUID, leftPaneId: UUID, rightPaneId: UUID, ratio: Double)
    case equalizePanes(tabId: UUID)

    /// Move a tab by a relative delta (positive=right, negative=left).
    case moveTab(tabId: UUID, delta: Int)
    /// Move a tab to a pre-removal tab-bar insertion slot.
    case reorderTab(tabId: UUID, insertionIndex: Int)

    /// Resize a pane by keyboard delta (Ghostty's resize_split action).
    case resizePaneByDelta(
        tabId: UUID, paneId: UUID,
        direction: SplitResizeDirection, amount: UInt16)

    /// Move ALL panes from sourceTab into targetTab at targetPaneId position.
    /// Source tab is removed after merge.
    case mergeTab(
        sourceTabId: UUID, targetTabId: UUID,
        targetPaneId: UUID, direction: SplitNewDirection)

    /// Move one main-layout pane from one tab into another tab.
    case movePaneAcrossTabs(CrossTabPaneMoveRequest)

    // Arrangement operations

    /// Create a custom arrangement as a complete view over the tab's panes.
    case createArrangement(tabId: UUID, name: String)
    /// Remove a custom arrangement (cannot remove default).
    case removeArrangement(tabId: UUID, arrangementId: UUID)
    /// Switch to a different arrangement in a tab.
    case switchArrangement(tabId: UUID, arrangementId: UUID)
    /// Rename an arrangement.
    case renameArrangement(tabId: UUID, arrangementId: UUID, name: String)
    // Worktree actions (routed through command pipeline for validation)
    case openWorktree(worktreeId: UUID)
    case openNewTerminalInTab(worktreeId: UUID, launchDirectory: URL?, title: String?)
    case openWorktreeInPane(worktreeId: UUID)
    case openFloatingTerminal(launchDirectory: URL?, title: String?)
    case removeRepo(repoId: UUID)
    case setRepoPinned(repoId: UUID, isPinned: Bool)
    case setPanePinned(paneId: UUID, isPinned: Bool)

    // Minimize / Expand
    case minimizePane(tabId: UUID, paneId: UUID)
    case expandPane(tabId: UUID, paneId: UUID)

    // Orphaned pane pool

    /// Move a pane to the background pool (remove from layout, keep alive).
    case backgroundPane(paneId: UUID)
    /// Reactivate a backgrounded pane into a tab layout.
    case reactivatePane(
        paneId: UUID, targetTabId: UUID,
        targetPaneId: UUID, direction: SplitNewDirection)
    /// Permanently destroy a backgrounded pane.
    case purgeOrphanedPane(paneId: UUID)

    // Drawer operations

    /// Enter a parent pane's drawer scope without creating a pane.
    case enterDrawer(parentPaneId: UUID)
    /// Move focus to the drawer pane above the current selection.
    case focusDrawerPaneUp(parentPaneId: UUID, drawerPaneId: UUID)
    /// Move focus to the drawer pane left of the current selection.
    case focusDrawerPaneLeft(parentPaneId: UUID, drawerPaneId: UUID)
    /// Move focus to the drawer pane below the current selection.
    case focusDrawerPaneDown(parentPaneId: UUID, drawerPaneId: UUID)
    /// Move focus to the drawer pane right of the current selection.
    case focusDrawerPaneRight(parentPaneId: UUID, drawerPaneId: UUID)
    /// Promote a drawer pane into the main layout to the right of its parent.
    case detachDrawerPane(parentPaneId: UUID, drawerPaneId: UUID)

    /// Add a drawer pane to a parent pane.
    case addDrawerPane(parentPaneId: UUID)
    /// Add a browser drawer pane to a parent pane.
    case addWebviewDrawerPane(parentPaneId: UUID, state: WebviewState)
    /// Add a drawer child named up front without expanding the drawer, changing
    /// its selection or moving focus. IPC creates drawer children this way.
    case addDrawerChildInBackground(parentPaneId: UUID, childPaneId: UUID, content: BackgroundDrawerChildContent)
    /// Remove a drawer pane from its parent.
    case removeDrawerPane(parentPaneId: UUID, drawerPaneId: UUID)
    /// Toggle a pane's drawer expanded/collapsed.
    case toggleDrawer(paneId: UUID)
    /// Switch the active drawer pane.
    case setActiveDrawerPane(parentPaneId: UUID, drawerPaneId: UUID)
    /// Resize a split within a drawer's layout.
    case resizeDrawerPane(parentPaneId: UUID, splitId: UUID, ratio: Double)
    /// Resize the visible panes around a minimized drawer-pane run.
    case resizeDrawerVisiblePanePair(parentPaneId: UUID, leftPaneId: UUID, rightPaneId: UUID, ratio: Double)
    /// Equalize all splits within a drawer's layout.
    case equalizeDrawerPanes(parentPaneId: UUID)
    /// Minimize a pane within a drawer.
    case minimizeDrawerPane(parentPaneId: UUID, drawerPaneId: UUID)
    /// Expand a minimized pane within a drawer.
    case expandDrawerPane(parentPaneId: UUID, drawerPaneId: UUID)
    /// Insert a new pane into a drawer's layout next to a target drawer pane.
    case insertDrawerPane(
        parentPaneId: UUID,
        targetDrawerPaneId: UUID,
        direction: SplitNewDirection,
        sizingMode: DropSizingMode
    )
    /// Commit a Pane Zoom terminal/Viewer split ratio after a finished divider drag.
    case setZoomSplitRatio(tabId: UUID, ratio: Double)
    /// Commit the owning pane's normal drawer height after a completed resize.
    case setDrawerNormalHeightRatio(parentPaneId: UUID, ratio: Double)
    /// Choose the Pane Zoom region the owning pane's drawer covers.
    case setDrawerZoomSide(parentPaneId: UUID, side: DrawerZoomSide)
    /// Move an existing drawer pane within the same drawer layout.
    case moveDrawerPane(
        parentPaneId: UUID,
        drawerPaneId: UUID,
        target: DrawerRearrangeTarget,
        sizingMode: DropSizingMode
    )

    // System actions — dispatched by Reconciler and undo timers, not by user input.

    /// Undo TTL expired — remove pane from store, kill zmx, destroy surface.
    case expireUndoEntry(paneId: UUID)

    /// Reconciler-generated repair action.
    case repair(RepairAction)
}

extension WorkspaceActionCommand {
    package static func insertPane(
        source: PaneSource,
        targetTabId: UUID,
        targetPaneId: UUID,
        direction: SplitNewDirection,
        sizingMode: DropSizingMode
    ) -> Self {
        .insertPaneRequest(
            PaneInsertRequest(
                source: source,
                targetTabId: targetTabId,
                targetPaneId: targetPaneId,
                direction: direction,
                sizingMode: sizingMode
            )
        )
    }
}

/// System-generated repair actions from the Reconciler.
/// Flow through WorkspaceSurfaceCoordinator.execute like user actions — one-way data flow never bypassed.
package enum RepairAction: Equatable, Hashable {
    /// zmx died — create new zmx session, send reattach command to existing surface.
    case reattachZmx(paneId: UUID)
    /// Surface died — full view + surface recreation. zmx reattaches.
    case recreateSurface(paneId: UUID)
    /// Pane is in layout but has no view in ViewRegistry.
    case createMissingView(paneId: UUID)
    /// Unrecoverable failure — mark pane as failed.
    case markSessionFailed(paneId: UUID, reason: String)
    /// Pane exists in runtime but not in store (and not pending undo) — clean up.
    case cleanupOrphan(paneId: UUID)
}
