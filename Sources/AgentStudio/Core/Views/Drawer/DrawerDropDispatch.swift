import AgentStudioInfrastructure
import Foundation

/// Validation + dispatch for drawer-child rearrange drops.
///
/// Extracted from `DrawerPanel` so the drop-capture NSView can be mounted at
/// `FlatTabStripContainer` level (above the drawer subtree) while the dispatch
/// logic stays independent of view placement. AppKit's drag destination
/// traversal does not reach the original nested capture; the destination must
/// sit at tab depth.
@MainActor
package enum DrawerDropDispatch {
    package struct Context {
        let parentPaneId: UUID
        let state: ActionStateSnapshot
    }

    package static func context(parentPaneId: UUID, store: WorkspaceStore) -> Context {
        let arrangementView = WorkspaceArrangementViewDerived(
            tabLayoutAtom: store.tabLayoutAtom,
            paneAtom: store.paneAtom,
            managementLayerAtom: atom(\.managementLayer)
        )
        return Context(
            parentPaneId: parentPaneId,
            state: WorkspaceCommandResolver.snapshot(
                from: store.tabLayoutAtom.tabs,
                activeTabId: store.tabLayoutAtom.activeTabId,
                isManagementLayerActive: atom(\.managementLayer).isActive,
                knownWorktreeIds: store.repositoryTopologyAtom.availableWorktreeIDs,
                drawerParentByPaneId: drawerParentByPaneId(store: store),
                drawerLayoutByParentPaneId: drawerLayoutByParentPaneId(store: store),
                drawerBrowserPaneIds: WorkspaceCommandResolver.drawerBrowserPaneIds(
                    in: store.paneAtom.paneSnapshot().values),
                visiblePaneIds: { tab in
                    arrangementView.activeVisiblePaneIds(forTab: tab.id)
                }
            )
        )
    }

    static func shouldAcceptDrop(
        payload: SplitDropPayload,
        target: DrawerRearrangeTarget,
        sizingMode: DropSizingMode,
        parentPaneId: UUID,
        store: WorkspaceStore
    ) -> Bool {
        shouldAcceptDrop(
            payload: payload,
            target: target,
            sizingMode: sizingMode,
            context: context(parentPaneId: parentPaneId, store: store)
        )
    }

    package static func shouldAcceptDrop(
        payload: SplitDropPayload,
        target: DrawerRearrangeTarget,
        sizingMode: DropSizingMode,
        context: Context
    ) -> Bool {
        guard case .existingPane(let sourcePaneId, _) = payload.kind else {
            assertionFailure("Drawer drop dispatch received non-pane payload")
            RestoreTrace.log(
                "DrawerDropDispatch.shouldAcceptDrop rejected nonPanePayload=\(String(describing: payload))")
            return false
        }
        guard context.state.drawerParentPaneId(of: sourcePaneId) == context.parentPaneId else {
            RestoreTrace.log(
                "DrawerDropDispatch.shouldAcceptDrop rejected parentMismatch source=\(sourcePaneId) sourceParent=\(String(describing: context.state.drawerParentPaneId(of: sourcePaneId))) destinationParent=\(context.parentPaneId)"
            )
            return false
        }

        let moveAction = WorkspaceActionCommand.moveDrawerPane(
            parentPaneId: context.parentPaneId,
            drawerPaneId: sourcePaneId,
            target: target,
            sizingMode: sizingMode
        )
        let validation = WorkspaceCommandValidator.validate(moveAction, state: context.state)
        RestoreTrace.log(
            "DrawerDropDispatch.shouldAcceptDrop parent=\(context.parentPaneId) source=\(sourcePaneId) target=\(String(describing: target)) validation=\(String(describing: validation))"
        )
        if case .success = validation {
            return true
        }
        return false
    }

    static func handleDrop(
        payload: SplitDropPayload,
        target: DrawerRearrangeTarget,
        sizingMode: DropSizingMode,
        parentPaneId: UUID,
        actionDispatcher: PaneActionDispatching,
        store: WorkspaceStore
    ) {
        handleDrop(
            payload: payload,
            target: target,
            sizingMode: sizingMode,
            context: context(parentPaneId: parentPaneId, store: store),
            actionDispatcher: actionDispatcher
        )
    }

    package static func handleDrop(
        payload: SplitDropPayload,
        target: DrawerRearrangeTarget,
        sizingMode: DropSizingMode,
        context: Context,
        actionDispatcher: PaneActionDispatching
    ) {
        guard
            shouldAcceptDrop(
                payload: payload,
                target: target,
                sizingMode: sizingMode,
                context: context
            )
        else {
            RestoreTrace.log(
                "DrawerDropDispatch.handleDrop rejectedDuringRevalidation parent=\(context.parentPaneId) payload=\(String(describing: payload)) target=\(String(describing: target))"
            )
            return
        }
        guard case .existingPane(let sourcePaneId, _) = payload.kind else { return }

        actionDispatcher.dispatch(
            .moveDrawerPane(
                parentPaneId: context.parentPaneId,
                drawerPaneId: sourcePaneId,
                target: target,
                sizingMode: sizingMode
            )
        )
    }

    private static func drawerParentByPaneId(store: WorkspaceStore) -> [UUID: UUID] {
        Dictionary(
            uniqueKeysWithValues: store.paneAtom.paneSnapshot().values.compactMap { pane in
                guard let drawerParentPaneId = pane.parentPaneId else { return nil }
                return (pane.id, drawerParentPaneId)
            }
        )
    }

    private static func drawerLayoutByParentPaneId(store: WorkspaceStore) -> [UUID: DrawerGridLayout] {
        Dictionary(
            uniqueKeysWithValues: store.paneAtom.paneSnapshot().values.compactMap { pane in
                guard
                    let drawer = pane.drawer,
                    let tab = store.tabLayoutAtom.tabContaining(paneId: pane.id),
                    let drawerView = tab.activeArrangement.drawerViews[drawer.drawerId]
                else {
                    return nil
                }
                return (pane.id, drawerView.layout)
            }
        )
    }
}
