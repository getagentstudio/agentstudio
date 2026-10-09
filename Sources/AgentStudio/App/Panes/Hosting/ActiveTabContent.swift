import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import SwiftUI

/// Legacy active-tab SwiftUI root preserved for diagnostics and transitional tests.
///
/// The production `PaneTabViewController` no longer hosts this view directly; it now
/// creates one persistent `SingleTabContent` host per tab at the AppKit layer.
/// This type remains as a compatibility shim for tests and debug-only investigation.
@available(*, deprecated, message: "PaneTabViewController now uses per-tab SingleTabContent hosts")
struct ActiveTabContent: View {
    let store: WorkspaceStore
    let octiconLoader: OcticonLoader
    let repoCache: RepoCacheAtom
    let editorChooser: EditorChooserState
    let viewRegistry: ViewRegistry
    let appLifecycleStore: AppLifecycleAtom
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let actionDispatcher: PaneActionDispatching
    let commandDispatcher: any AppCommandDispatching
    let arrangementInlineRenameState: ArrangementInlineRenameState
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let onFocusPane: (UUID) -> Void
    let paneInboxPresentation: PaneInboxPresentation? = nil
    let onOpenPaneGitHub: (UUID) -> Void
    let workspaceWindowId: UUID? = nil

    private static func traceBody(
        activeTabId: UUID?,
        tabPaneCount: Int,
        registeredPaneCount: Int,
        hasTree: Bool
    ) -> Int {
        if let activeTabId {
            RestoreTrace.log(
                "ActiveTabContent.body activeTab=\(activeTabId) tabPaneCount=\(tabPaneCount) registeredPaneCount=\(registeredPaneCount) hasTree=\(hasTree)"
            )
        } else {
            RestoreTrace.log("ActiveTabContent.body empty activeTab=nil")
        }
        return 0
    }

    var body: some View {
        let activeTabId = store.tabLayoutAtom.activeTabId
        let tab = activeTabId.flatMap { store.tabLayoutAtom.tab($0) }
        let registeredPaneCount = tab?.activePaneIds.filter { viewRegistry.view(for: $0) != nil }.count ?? 0
        let tabPaneCount = tab?.activePaneIds.count ?? 0
        // swiftlint:disable:next redundant_discardable_let
        let _ = Self.traceBody(
            activeTabId: activeTabId,
            tabPaneCount: tabPaneCount,
            registeredPaneCount: registeredPaneCount,
            hasTree: tab != nil && registeredPaneCount > 0
        )

        if let activeTabId, tab != nil {
            let arrangementView = atom(\.arrangementView)
            if let activeLayout = arrangementView.activeLayout(forTab: activeTabId) {
                FlatTabStripContainer(
                    layout: activeLayout,
                    octiconLoader: octiconLoader,
                    tabId: activeTabId,
                    activePaneId: arrangementView.activePaneId(forTab: activeTabId),
                    minimizedPaneIds: arrangementView.activeMinimizedPaneIds(forTab: activeTabId),
                    visiblePaneIds: arrangementView.activeVisiblePaneIds(forTab: activeTabId),
                    arrangementInlineRenameState: arrangementInlineRenameState,
                    closeTransitionCoordinator: closeTransitionCoordinator,
                    actionDispatcher: actionDispatcher,
                    commandDispatcher: commandDispatcher,
                    onPaneFocusTrigger: onPaneFocusTrigger,
                    onFocusPane: onFocusPane,
                    store: store,
                    repoCache: repoCache,
                    editorChooser: editorChooser,
                    viewRegistry: viewRegistry,
                    appLifecycleStore: appLifecycleStore,
                    paneInboxPresentation: paneInboxPresentation,
                    onOpenPaneGitHub: onOpenPaneGitHub,
                    workspaceWindowId: workspaceWindowId,
                    paneSurfaceToolbarPresentation: { _ in .hidden }
                )
                .background(AppStyles.Shell.PaneChrome.background)
            }
        }
        // Empty/no-tab state handled by AppKit (PaneTabViewController toggles NSView visibility)
    }
}
