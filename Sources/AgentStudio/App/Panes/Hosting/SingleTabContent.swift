import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import SwiftUI

struct SingleTabContent: View {
    let tabId: UUID
    let octiconLoader: OcticonLoader
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let editorChooser: EditorChooserState
    let viewRegistry: ViewRegistry
    let heldPanePreviewState: HeldPanePreviewState
    let appLifecycleStore: AppLifecycleAtom
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let actionDispatcher: PaneActionDispatching
    let arrangementInlineRenameState: ArrangementInlineRenameState
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let onFocusPane: (UUID) -> Void
    let paneInboxPresentation: PaneInboxPresentation?
    let paneNotePresentation: PaneNotePresentation?
    let onOpenPaneGitHub: (UUID) -> Void
    let workspaceWindowId: UUID?
    let paneSurfaceToolbarPresentation: (UUID) -> PaneSurfaceToolbarPresentation
    let zoomPaneSurfaceToolbarPresentation: (UUID, ZoomViewerPresentation) -> PaneSurfaceToolbarPresentation
    let interactionProbe: AgentStudioInteractionPerformanceProbe?

    init(
        tabId: UUID,
        octiconLoader: OcticonLoader,
        store: WorkspaceStore,
        repoCache: RepoCacheAtom,
        editorChooser: EditorChooserState,
        viewRegistry: ViewRegistry,
        heldPanePreviewState: HeldPanePreviewState,
        appLifecycleStore: AppLifecycleAtom,
        closeTransitionCoordinator: PaneCloseTransitionCoordinator,
        actionDispatcher: PaneActionDispatching,
        arrangementInlineRenameState: ArrangementInlineRenameState,
        onPaneFocusTrigger: @escaping PaneFocusTriggerHandler,
        onFocusPane: @escaping (UUID) -> Void,
        paneInboxPresentation: PaneInboxPresentation? = nil,
        paneNotePresentation: PaneNotePresentation? = nil,
        onOpenPaneGitHub: @escaping (UUID) -> Void,
        workspaceWindowId: UUID? = nil,
        paneSurfaceToolbarPresentation: @escaping (UUID) -> PaneSurfaceToolbarPresentation,
        zoomPaneSurfaceToolbarPresentation:
            @escaping (UUID, ZoomViewerPresentation) -> PaneSurfaceToolbarPresentation,
        interactionProbe: AgentStudioInteractionPerformanceProbe? = nil
    ) {
        self.tabId = tabId
        self.octiconLoader = octiconLoader
        self.store = store
        self.repoCache = repoCache
        self.editorChooser = editorChooser
        self.viewRegistry = viewRegistry
        self.heldPanePreviewState = heldPanePreviewState
        self.appLifecycleStore = appLifecycleStore
        self.closeTransitionCoordinator = closeTransitionCoordinator
        self.actionDispatcher = actionDispatcher
        self.arrangementInlineRenameState = arrangementInlineRenameState
        self.onPaneFocusTrigger = onPaneFocusTrigger
        self.onFocusPane = onFocusPane
        self.paneInboxPresentation = paneInboxPresentation
        self.paneNotePresentation = paneNotePresentation
        self.onOpenPaneGitHub = onOpenPaneGitHub
        self.workspaceWindowId = workspaceWindowId
        self.paneSurfaceToolbarPresentation = paneSurfaceToolbarPresentation
        self.zoomPaneSurfaceToolbarPresentation = zoomPaneSurfaceToolbarPresentation
        self.interactionProbe = interactionProbe
    }

    private static func traceMissingTab(tabId: UUID) -> Int {
        RestoreTrace.log("SingleTabContent.body missingTab tabId=\(tabId)")
        return 0
    }

    var body: some View {
        Group {
            if let previewHost = readyHeldPreviewHost() {
                HeldPanePreviewContainer(
                    tabId: tabId,
                    paneHost: previewHost,
                    viewRegistry: viewRegistry
                )
                .background(AppStyles.Shell.PaneChrome.background)
                .transition(.identity)
            } else {
                canonicalTabContent()
            }
        }
        .environment(\.agentStudioInteractionPerformanceProbe, interactionProbe)
    }

    @ViewBuilder
    private func canonicalTabContent() -> some View {
        let workspaceTab = WorkspaceTabLayoutDerived(
            shellAtom: store.tabShellAtom,
            arrangementAtom: store.tabArrangementAtom
        )
        let arrangementView = atom(\.arrangementView)
        let tab = workspaceTab.tab(tabId)
        let zoomPresentation = store.panePresentationAtom.zoomPresentation(forTab: tabId)
        // swiftlint:disable:next redundant_discardable_let
        let _ = tab == nil ? Self.traceMissingTab(tabId: tabId) : 0

        if let tab {
            if let zoomPresentation {
                zoomContent(
                    presentation: zoomPresentation,
                    tab: tab
                )
                .background(AppStyles.Shell.PaneChrome.background)
                .transition(.identity)
            } else if let activeLayout = arrangementView.activeLayout(forTab: tab) {
                let activeMinimizedPaneIds = arrangementView.activeMinimizedPaneIds(
                    forTab: tab,
                    activeLayout: activeLayout
                )
                let activeVisiblePaneIds = arrangementView.activeVisiblePaneIds(
                    activeLayout: activeLayout,
                    minimizedPaneIds: activeMinimizedPaneIds
                )
                FlatTabStripContainer(
                    layout: activeLayout,
                    octiconLoader: octiconLoader,
                    tabId: tabId,
                    activePaneId: arrangementView.activePaneId(forTab: tab),
                    minimizedPaneIds: activeMinimizedPaneIds,
                    visiblePaneIds: activeVisiblePaneIds,
                    arrangementInlineRenameState: arrangementInlineRenameState,
                    closeTransitionCoordinator: closeTransitionCoordinator,
                    actionDispatcher: actionDispatcher,
                    onPaneFocusTrigger: onPaneFocusTrigger,
                    onFocusPane: onFocusPane,
                    store: store,
                    repoCache: repoCache,
                    editorChooser: editorChooser,
                    viewRegistry: viewRegistry,
                    appLifecycleStore: appLifecycleStore,
                    paneInboxPresentation: paneInboxPresentation,
                    paneNotePresentation: paneNotePresentation,
                    onOpenPaneGitHub: onOpenPaneGitHub,
                    workspaceWindowId: workspaceWindowId,
                    paneSurfaceToolbarPresentation: paneSurfaceToolbarPresentation
                )
                .background(AppStyles.Shell.PaneChrome.background)
                .transition(.identity)
            } else {
                EmptyArrangementPlaceholderView()
            }
        }
    }

    @MainActor
    private func readyHeldPreviewHost() -> PaneHostView? {
        guard heldPanePreviewState.isHeld,
            let presentedTarget = heldPanePreviewState.presentedTarget,
            presentedTarget.owningTabID == tabId,
            store.tabLayoutAtom.containsTab(tabId),
            let pane = store.paneAtom.pane(presentedTarget.paneID),
            store.tabLayoutAtom.tabID(containingPane: pane.parentPaneId ?? pane.id)
                == presentedTarget.owningTabID,
            pane.provider == presentedTarget.provider,
            pane.terminalState?.zmxSessionID == presentedTarget.sessionID
        else {
            return nil
        }
        return viewRegistry.slot(for: presentedTarget.paneID).host
    }

    @ViewBuilder
    private func zoomContent(
        presentation: ZoomPresentation,
        tab: AgentStudioCore.Tab
    ) -> some View {
        let parentToolbar = zoomPaneSurfaceToolbarPresentation(
            presentation.sourcePaneId,
            presentation.viewerPresentation
        )
        if let renderState = ZoomPresentationContainer.resolveRenderState(
            presentation: presentation,
            viewRegistry: viewRegistry,
            parentToolbar: parentToolbar
        ) {
            let ordinalMap = PaneOrdinalMap(orderedPaneIds: tab.layout.paneIds)
            let isSplit = renderState.isCompanionVisible
            let sourceContent = zoomChildContent(
                renderState.children[0],
                sourcePaneId: presentation.sourcePaneId,
                isSplit: isSplit,
                ordinalMap: ordinalMap
            )
            let companionContent: AnyView? =
                if presentation.viewerPresentation == .unavailableVisible {
                    AnyView(ZoomViewerUnavailableView())
                } else {
                    renderState.children.dropFirst().first.map {
                        zoomChildContent(
                            $0,
                            sourcePaneId: presentation.sourcePaneId,
                            isSplit: isSplit,
                            ordinalMap: ordinalMap
                        )
                    }
                }

            ZoomPresentationContainer(
                tabId: tabId,
                sourcePaneId: presentation.sourcePaneId,
                sourceOrdinal: ordinalMap.ordinal(forPaneId: presentation.sourcePaneId),
                sourceContent: sourceContent,
                companionContent: companionContent,
                isCompanionVisible: renderState.isCompanionVisible,
                parentToolbarPresentation: renderState.parentToolbar,
                splitRatio: presentation.transientSplitRatio ?? AppPolicies.PaneZoomSplit.defaultTerminalRatio,
                store: store,
                octiconLoader: octiconLoader,
                editorChooser: editorChooser,
                repoCache: repoCache,
                appLifecycleStore: appLifecycleStore,
                closeTransitionCoordinator: closeTransitionCoordinator,
                paneInboxPresentation: paneInboxPresentation,
                paneNotePresentation: paneNotePresentation,
                workspaceWindowId: workspaceWindowId,
                actionDispatcher: actionDispatcher,
                arrangementInlineRenameState: arrangementInlineRenameState,
                onPaneFocusTrigger: onPaneFocusTrigger,
                onFocusPane: onFocusPane,
                onOpenPaneGitHub: onOpenPaneGitHub,
                viewRegistry: viewRegistry,
                surfaceId: "zoom:\(tabId)",
                renderedPaneIds: Set(renderState.children.map(\.paneId))
            )
            .id(presentation.sourcePaneId)
        } else {
            Color.clear
        }
    }

    private func zoomChildContent(
        _ child: ZoomPresentationChild,
        sourcePaneId: UUID,
        isSplit: Bool,
        ordinalMap: PaneOrdinalMap
    ) -> AnyView {
        guard let paneHost = child.paneSlot.host else {
            return AnyView(Color.clear)
        }

        return AnyView(
            PaneLeafContainer(
                paneHost: paneHost,
                octiconLoader: octiconLoader,
                tabId: tabId,
                isActive: child.paneId == sourcePaneId,
                isSplit: isSplit,
                isSplitResizing: false,
                store: store,
                repoCache: repoCache,
                editorChooser: editorChooser,
                closeTransitionCoordinator: closeTransitionCoordinator,
                actionDispatcher: actionDispatcher,
                onPaneFocusTrigger: onPaneFocusTrigger,
                onOpenPaneGitHub: onOpenPaneGitHub,
                dropTargetCoordinateSpace: "tabContainer",
                paneInboxPresentation: child.paneId == sourcePaneId ? paneInboxPresentation : nil,
                paneNotePresentation: child.paneId == sourcePaneId ? paneNotePresentation : nil,
                ordinal: ordinalMap.ordinal(forPaneId: child.paneId),
                workspaceWindowId: workspaceWindowId,
                toolbarPresentation: child.toolbarPresentation,
                managementChromePresentation: .zoomChild
            )
        )
    }
}
