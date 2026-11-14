import Foundation

enum PaneDrawerFocusDecider {
    static func decide(
        trigger: PaneDrawerFocusTrigger,
        context: PaneFocusContext
    ) -> PaneDrawerFocusDecision {
        switch trigger {
        case .selectPane(let parentPaneId, let drawerPaneId), .contentClick(let parentPaneId, let drawerPaneId):
            let drawerChildAlreadyActive =
                context.activeDrawer?.parentPaneId == parentPaneId
                && context.activeDrawer?.paneId == drawerPaneId
            let focusAlreadyInDrawerPane = context.activePaneId == drawerPaneId
            let alreadyActiveDrawerPane = drawerChildAlreadyActive && focusAlreadyInDrawerPane
            let responder: PaneDrawerResponderAction
            if case .contentClick = trigger, context.targetPaneKind != .terminal {
                // The native content click already chose its browser/editor descendant.
                responder = .preserveCurrentResponder
            } else {
                responder = .focusPaneHost(paneId: drawerPaneId)
            }
            return PaneDrawerFocusDecision(
                selection: alreadyActiveDrawerPane
                    ? .keep
                    : .selectDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId),
                responder: responder,
                runtime: .preserveRuntimeFocus,
                reason: .drawerSelectionChanged
            )

        case .toggle(let parentPaneId):
            let responder: PaneDrawerResponderAction
            if context.activeDrawer?.parentPaneId == parentPaneId {
                if let drawerPaneId = context.activeDrawer?.paneId {
                    responder = .focusPaneHost(paneId: drawerPaneId)
                } else if context.activeDrawer?.isEmpty == true {
                    responder = .preserveCurrentResponder
                } else {
                    responder = .focusPaneHost(paneId: parentPaneId)
                }
            } else {
                responder = .focusPaneHost(paneId: parentPaneId)
            }
            return PaneDrawerFocusDecision(
                selection: .keep,
                responder: responder,
                runtime: .preserveRuntimeFocus,
                reason: .drawerSelectionChanged
            )
        }
    }
}
