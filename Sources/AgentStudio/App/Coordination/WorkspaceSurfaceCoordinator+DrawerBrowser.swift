import AgentStudioCore
import AgentStudioWebview
import Foundation

/// Which tab a drawer-browser open landed in.
enum DrawerBrowserTabOutcome: Equatable, Sendable {
    /// The drawer had no browser; one was created showing the page.
    case newBrowser
    /// The drawer's browser added a tab for the page.
    case newTab
    /// A tab already showing the page was made active and loaded again.
    case reusedTab
}

/// What every drawer-browser open returns: the browser actually used, new or
/// existing, and where the page landed.
struct DrawerBrowserOpenResult: Equatable, Sendable {
    let childPaneId: UUID
    let tab: DrawerBrowserTabOutcome
}

@MainActor
extension WorkspaceSurfaceCoordinator {
    /// The one way a browser opens. It opens `url` in the drawer of
    /// `parentPaneId`: a tab in the drawer's browser when it has one, otherwise
    /// a new drawer browser. An interactive open expands the drawer and selects
    /// the browser; a background open leaves drawer state and focus as they were.
    /// `newChildPaneId` names the browser only when one is created.
    @discardableResult
    func openBrowserInDrawer(
        parentPaneId: UUID,
        url: URL,
        newChildPaneId: UUID? = nil,
        presentation: DrawerChildPresentation
    ) -> DrawerBrowserOpenResult? {
        if let browserPaneId = drawerBrowserPaneId(parentPaneId: parentPaneId) {
            guard
                let controller = viewRegistry.view(for: browserPaneId)?
                    .mountedContent(as: WebviewPaneMountView.self)?.controller
            else {
                Self.logger.error("openBrowserInDrawer: drawer browser \(browserPaneId) has no mounted view")
                return nil
            }
            let tab: DrawerBrowserTabOutcome =
                switch controller.openPage(url) {
                case .added: .newTab
                case .reused: .reusedTab
                }
            if presentation == .interactive {
                revealDrawerBrowser(browserPaneId, parentPaneId: parentPaneId)
            }
            return DrawerBrowserOpenResult(childPaneId: browserPaneId, tab: tab)
        }
        guard
            let createdPaneId = executeAddWebviewDrawerPane(
                parentPaneId: parentPaneId,
                state: WebviewState(url: url, showNavigation: true),
                childPaneId: newChildPaneId,
                presentation: presentation
            )
        else { return nil }
        return DrawerBrowserOpenResult(childPaneId: createdPaneId, tab: .newBrowser)
    }

    /// Runs a validated drawer-browser open and returns its result, or nil when
    /// the action is not one or the open failed.
    func openBrowserInDrawer(_ validated: ValidatedAction) -> DrawerBrowserOpenResult? {
        switch validated.action {
        case .addWebviewDrawerPane(let parentPaneId, let state):
            return openBrowserInDrawer(parentPaneId: parentPaneId, url: state.url, presentation: .interactive)
        case .addDrawerChildInBackground(let parentPaneId, let childPaneId, .webview(let state)):
            return openBrowserInDrawer(
                parentPaneId: parentPaneId, url: state.url, newChildPaneId: childPaneId, presentation: .background
            )
        default:
            return nil
        }
    }

    /// The drawer's browser: its first browser child in drawer order. Drawers
    /// saved with several browsers keep them; new opens use the first.
    func drawerBrowserPaneId(parentPaneId: UUID) -> UUID? {
        store.paneAtom.pane(parentPaneId)?.drawer?.paneIds.first { childPaneId in
            guard case .webview = store.paneAtom.pane(childPaneId)?.content else { return false }
            return true
        }
    }

    private func revealDrawerBrowser(_ browserPaneId: UUID, parentPaneId: UUID) {
        if !store.paneAtom.isDrawerExpanded(for: parentPaneId) {
            store.paneAtom.toggleDrawer(for: parentPaneId)
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }
        }
        guard let drawerContext = drawerCommandContext(parentPaneId: parentPaneId, command: "openBrowserInDrawer")
        else { return }
        store.tabArrangementAtom.setActiveDrawerPane(
            browserPaneId, drawerId: drawerContext.drawerId, inTab: drawerContext.tabId)
        reattachForViewSwitch(paneId: browserPaneId)
        focusVisiblePaneHost(browserPaneId)
    }
}
