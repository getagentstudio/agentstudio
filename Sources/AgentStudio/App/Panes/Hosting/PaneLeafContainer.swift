import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTerminal
import AppKit
import SwiftUI

enum PaneManagementChromePresentation: Equatable {
    case ordinary
    case zoomChild
}

enum PaneManagementTrailingControl: Equatable {
    case movePaneToTab
    case detachDrawerPane

    static func resolve(isDrawerChild: Bool) -> Self {
        isDrawerChild ? .detachDrawerPane : .movePaneToTab
    }
}

/// Renders a single pane leaf container.
/// Handles terminal views (with surface dimming and drag handles) and
/// non-terminal views (webview, code viewer stubs) uniformly.
struct PaneLeafContainer: View {
    let paneHost: PaneHostView
    let octiconLoader: OcticonLoader
    let tabId: UUID
    let isActive: Bool
    let isSplit: Bool
    let isSplitResizing: Bool
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let editorChooser: EditorChooserState
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let actionDispatcher: PaneActionDispatching
    let commandDispatcher: any AppCommandDispatching
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let onOpenPaneGitHub: (UUID) -> Void
    let dropTargetCoordinateSpace: String?
    let useDrawerFramePreference: Bool
    let paneInboxPresentation: PaneInboxPresentation?
    let paneNotePresentation: PaneNotePresentation?
    let ordinal: Int?
    let workspaceWindowId: UUID?
    let toolbarPresentation: PaneSurfaceToolbarPresentation
    let managementChromePresentation: PaneManagementChromePresentation

    @State private var isHovered: Bool = false
    private var managementLayer: ManagementLayerAtom {
        atom(\.managementLayer)
    }
    @State private var isDragHandleHovered: Bool = false
    @State private var isMinimizeHovered: Bool = false
    @State private var isCloseHovered: Bool = false
    @State private var isShowArrangementsHovered: Bool = false
    @State private var isSplitHovered: Bool = false
    @State private var isBrowserHovered: Bool = false
    @State private var isMovePaneHovered: Bool = false
    @State private var isDetachHovered: Bool = false
    @State private var movePaneMenuAnchorView: NSView?
    @State private var movePaneMenuPresenter = PaneMoveDestinationMenuPresenter()
    @State private var contextMenuPresenter: PaneManagementContextMenuPresenter

    init(
        paneHost: PaneHostView,
        octiconLoader: OcticonLoader,
        tabId: UUID,
        isActive: Bool,
        isSplit: Bool,
        isSplitResizing: Bool,
        store: WorkspaceStore,
        repoCache: RepoCacheAtom,
        editorChooser: EditorChooserState,
        closeTransitionCoordinator: PaneCloseTransitionCoordinator,
        actionDispatcher: PaneActionDispatching,
        commandDispatcher: any AppCommandDispatching,
        onPaneFocusTrigger: @escaping PaneFocusTriggerHandler,
        onOpenPaneGitHub: @escaping (UUID) -> Void,
        dropTargetCoordinateSpace: String? = "tabContainer",
        useDrawerFramePreference: Bool = false,
        paneInboxPresentation: PaneInboxPresentation? = nil,
        paneNotePresentation: PaneNotePresentation? = nil,
        ordinal: Int? = nil,
        workspaceWindowId: UUID? = nil,
        toolbarPresentation: PaneSurfaceToolbarPresentation,
        managementChromePresentation: PaneManagementChromePresentation = .ordinary
    ) {
        self.paneHost = paneHost
        self.octiconLoader = octiconLoader
        self.tabId = tabId
        self.isActive = isActive
        self.isSplit = isSplit
        self.isSplitResizing = isSplitResizing
        self.store = store
        self.repoCache = repoCache
        self.editorChooser = editorChooser
        self.closeTransitionCoordinator = closeTransitionCoordinator
        self.actionDispatcher = actionDispatcher
        self.commandDispatcher = commandDispatcher
        self.onPaneFocusTrigger = onPaneFocusTrigger
        self.onOpenPaneGitHub = onOpenPaneGitHub
        self.dropTargetCoordinateSpace = dropTargetCoordinateSpace
        self.useDrawerFramePreference = useDrawerFramePreference
        self.paneInboxPresentation = paneInboxPresentation
        self.paneNotePresentation = paneNotePresentation
        self.ordinal = ordinal
        self.workspaceWindowId = workspaceWindowId
        self.toolbarPresentation = toolbarPresentation
        self.managementChromePresentation = managementChromePresentation
        _contextMenuPresenter = State(
            initialValue: PaneManagementContextMenuPresenter(octiconLoader: octiconLoader)
        )
    }

    /// Whether this pane is a drawer child (no drag, no drop, no sub-drawer).
    private var isDrawerChild: Bool {
        store.paneAtom.graphAtom.paneStructuralFacts(paneHost.id)?.isDrawerChild ?? false
    }

    /// Drawer state derived from store via @Observable tracking.
    /// Only layout panes have drawers; drawer children return nil.
    private var drawer: Drawer? {
        projectedDrawer(
            from: store.paneAtom.graphAtom.paneStructuralFacts(paneHost.id)
        )
    }

    private func projectedDrawer(from paneStructuralFacts: PaneStructuralFacts?) -> Drawer? {
        guard let paneStructuralFacts,
            let drawerID = paneStructuralFacts.ownedDrawerID
        else { return nil }
        return Drawer(
            drawerId: drawerID,
            parentPaneId: paneStructuralFacts.paneID,
            paneIds: paneStructuralFacts.ownedDrawerPaneIDs,
            isExpanded: store.paneAtom.expandedDrawerID == drawerID
        )
    }

    /// Parent pane ID for drawer children; nil for layout panes.
    private var drawerParentPaneId: UUID? {
        store.paneAtom.graphAtom.paneStructuralFacts(paneHost.id)?.parentPaneID
    }

    private var tabContainsExpandedDrawer: Bool {
        guard let layout = store.tabLayoutAtom.canonicalActiveLayout(forTab: tabId) else { return false }
        return layout.paneIds.contains { paneId in
            store.paneAtom.isDrawerExpanded(for: paneId)
        }
    }

    private var suppressMainPaneManagementInteraction: Bool {
        guard managementChromePresentation == .ordinary else { return true }
        return PaneInteractionOcclusionPolicy.suppressMainPaneManagementInteraction(
            isDrawerChild: isDrawerChild,
            tabContainsExpandedDrawer: tabContainsExpandedDrawer
        )
    }

    private var isClosing: Bool {
        closeTransitionCoordinator.closingPaneIds.contains(paneHost.id)
    }

    private var isPointerInsidePaneView: Bool {
        guard managementLayer.isActive else { return false }
        guard let window = paneHost.window else { return false }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInPane = paneHost.convert(pointInWindow, from: nil)
        return paneHost.bounds.contains(pointInPane)
    }

    /// Downcast to terminal view for terminal-specific features.
    private var terminalView: TerminalPaneMountView? {
        paneHost.mountedContent(as: TerminalPaneMountView.self)
    }

    private struct MovePaneDestination: Identifiable {
        let tabId: UUID
        let title: String

        var id: UUID { tabId }
    }

    private var movePaneDestinations: [MovePaneDestination] {
        store.tabLayoutAtom.tabs.enumerated().compactMap { index, tab in
            guard tab.id != tabId else { return nil }
            guard tab.activePaneId ?? tab.activePaneIds.first != nil else { return nil }
            return MovePaneDestination(
                tabId: tab.id,
                title: PaneMoveDestinationPresentation.title(
                    tabOrdinal: index + 1,
                    tabTitle: tabDisplayTitle(tab: tab)
                )
            )
        }
    }

    private func normalizedMeasuredFrame(from rawFrame: CGRect) -> CGRect {
        let paneGap = AppStyles.General.Layout.paneGap
        return CGRect(
            x: rawFrame.minX + paneGap,
            y: rawFrame.minY + paneGap,
            width: max(rawFrame.width - (paneGap * 2), 1),
            height: max(rawFrame.height - (paneGap * 2), 1)
        )
    }

    var body: some View {
        GeometryReader { paneGeometry in
            let paneStructuralFacts =
                managementLayer.isActive || toolbarPresentation.reservesToolbarLayout
                ? store.paneAtom.graphAtom.paneStructuralFacts(paneHost.id) : nil
            let isDrawerChild = paneStructuralFacts?.isDrawerChild ?? false
            let drawer = projectedDrawer(from: paneStructuralFacts)
            let drawerParentPaneId = paneStructuralFacts?.parentPaneID
            let suppressMainPaneManagementInteraction = {
                guard managementChromePresentation == .ordinary else { return true }
                return PaneInteractionOcclusionPolicy.suppressMainPaneManagementInteraction(
                    isDrawerChild: isDrawerChild,
                    tabContainsExpandedDrawer: tabContainsExpandedDrawer
                )
            }
            // Keep the tab-wide drawer scan and direct pointer query lazy. These closures
            // are reached only by management chrome or an actual hover callback.
            let isManagementHovered = {
                guard !suppressMainPaneManagementInteraction() else { return false }
                return isHovered || isPointerInsidePaneView
            }
            let managementContext = PaneManagementContext.project(
                paneId: paneHost.id,
                store: store,
            )
            let minimizePresentation = commandPresentation(
                .minimizePane,
                surface: .inlineControl
            )
            let closePresentation = commandPresentation(
                .closePane,
                surface: .inlineControl
            )
            let splitPresentation = commandPresentation(
                .splitRight,
                surface: .inlineControl
            )
            let detachPresentation = commandPresentation(
                .detachDrawerPane,
                surface: .inlineControl
            )
            let inlineMovePresentation = commandPresentation(
                .movePaneToTab,
                surface: .inlineControl
            )
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    PaneViewRepresentable(paneHost: paneHost)
                        // Force SwiftUI to recreate the representable when the host
                        // instance changes (e.g. after repair or placeholder retry).
                        // Without this, updateNSView is a no-op and the old NSView
                        // stays mounted.
                        .id(paneHost.hostIdentity)
                        // In management layer, route drag targeting through the shared
                        // SwiftUI leaf container so pane type (WKWebView/Ghostty/etc.)
                        // cannot intercept drop updates differently.
                        .allowsHitTesting(!managementLayer.isActive)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            if managementLayer.isActive
                                && managementChromePresentation == .ordinary
                                && !isDrawerChild
                                && managementContext.showsIdentityBlock
                            {
                                ManagementPaneIdentityOverlay(
                                    context: managementContext,
                                    octiconLoader: octiconLoader
                                )
                            }
                        }
                    if toolbarPresentation.reservesToolbarLayout && !isDrawerChild {
                        let locationTargetPaneId = currentLocationTargetPaneId(drawer: drawer)
                        PaneSurfaceToolbarHost(
                            anchorPaneId: paneHost.id,
                            locationTargetPaneId: locationTargetPaneId,
                            toolbarSurface: .pane,
                            drawer: drawer,
                            leadingToolbarActions: toolbarPresentation.leadingActions,
                            contextToolbarActions: toolbarPresentation.contextActions,
                            store: store,
                            repoCache: repoCache,
                            octiconLoader: octiconLoader,
                            editorChooser: editorChooser,
                            paneInboxPresentation: paneInboxPresentation,
                            paneNotePresentation: paneNotePresentation,
                            workspaceWindowId: workspaceWindowId,
                            owningPaneSize: paneGeometry.size,
                            actionDispatcher: actionDispatcher,
                            commandDispatcher: commandDispatcher,
                            onPaneFocusTrigger: onPaneFocusTrigger
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Regular inactive split panes keep a readable center and dim only the edge band.
                if isSplit && !isActive && managementChromePresentation == .ordinary {
                    InactivePaneEdgeDimmingOverlay()
                }

                // Management layer dimming: persistent overlay signaling content is non-interactive
                if managementLayer.isActive && managementChromePresentation == .ordinary {
                    Rectangle()
                        .fill(Color.black)
                        .opacity(AppStyles.Shell.ManagementLayer.modeDimmingOpacity)
                        .allowsHitTesting(false)
                }

                // Hover border: drag affordance in management layer
                if managementLayer.isActive
                    && isManagementHovered()
                    && !isSplitResizing
                    && !suppressMainPaneManagementInteraction()
                {
                    RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.panel)
                        .strokeBorder(Color.white.opacity(AppStyles.General.Stroke.visible), lineWidth: 1)
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: AppStyles.General.Animation.fast), value: isManagementHovered())
                }

                // Drag handle: compact centered pill in management layer.
                // The Color.clear fills the ZStack for centering; allowsHitTesting(false)
                // ensures only the capsule itself intercepts mouse events.
                if managementLayer.isActive && !isSplitResizing && !suppressMainPaneManagementInteraction() {
                    ZStack {
                        Color.clear
                            .allowsHitTesting(false)
                        ZStack {
                            RoundedRectangle(cornerRadius: AppStyles.Shell.ManagementLayer.dragHandleCornerRadius)
                                .fill(
                                    Color.black.opacity(
                                        AppStyles.Shell.ManagementLayer.backgroundOpacity(
                                            isHovered: isDragHandleHovered
                                        )
                                    )
                                )
                                .shadow(color: .black.opacity(AppStyles.General.Stroke.visible), radius: 4, y: 2)
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: AppStyles.General.Icon.toolbar, weight: .medium))
                                .foregroundStyle(
                                    .white.opacity(
                                        AppStyles.Shell.ManagementLayer.iconOpacity(isHovered: isDragHandleHovered))
                                )
                        }
                        .frame(
                            width: AppStyles.Shell.ManagementLayer.dragHandleWidth,
                            height: AppStyles.Shell.ManagementLayer.dragHandleHeight
                        )
                        .contentShape(
                            RoundedRectangle(cornerRadius: AppStyles.Shell.ManagementLayer.dragHandleCornerRadius)
                        )
                        .onHover { hovered in
                            isDragHandleHovered = hovered
                            RestoreTrace.log(
                                "PaneLeafContainer.dragHandle.onHover hovered=\(hovered) pane=\(paneHost.id) drawerParent=\(drawerParentPaneId?.uuidString ?? "nil")"
                            )
                        }
                        .draggable(
                            PaneDragPayload(
                                paneId: paneHost.id,
                                tabId: tabId,
                                drawerParentPaneId: drawerParentPaneId
                            )
                        ) {
                            DragHandleDragPreview(
                                paneId: paneHost.id,
                                drawerParentPaneId: drawerParentPaneId,
                                tabId: tabId
                            )
                        }
                        .accessibilityIdentifier("paneManagement.dragHandle")
                    }
                }

                // Shortcut ordinal: top-center, aligned with management controls.
                if managementLayer.isActive && !isSplitResizing && !suppressMainPaneManagementInteraction() {
                    VStack {
                        HStack {
                            Spacer()
                            if let ordinal {
                                ManagementOrdinalShortcutHint(ordinal: ordinal)
                            }
                            Spacer()
                        }
                        .padding(AppStyles.General.Spacing.standard)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Pane controls: minimize + close (top-left, management layer)
                if managementLayer.isActive && !isSplitResizing && !suppressMainPaneManagementInteraction() {
                    VStack {
                        HStack(spacing: AppStyles.General.Spacing.standard) {
                            if let minimizePresentation {
                                managementCommandCircleButton(
                                    presentation: minimizePresentation,
                                    systemName: "minus",
                                    isHovered: isMinimizeHovered,
                                    accessibilityIdentifier: "paneManagement.minimize"
                                ) {
                                    minimizePresentation.perform()
                                }
                                .onHover { isMinimizeHovered = $0 }
                            }

                            if let closePresentation {
                                managementCommandCircleButton(
                                    presentation: closePresentation,
                                    systemName: "xmark",
                                    isHovered: isCloseHovered,
                                    accessibilityIdentifier: "paneManagement.close",
                                    additionalEnabledState: !isClosing
                                ) {
                                    beginCloseTransition()
                                }
                                .onHover { isCloseHovered = $0 }
                            }

                            if let showArrangementsAction = toolbarPresentation.showArrangementsAction {
                                managementCircleButton(
                                    action: showArrangementsAction,
                                    isHovered: isShowArrangementsHovered,
                                    accessibilityIdentifier: "paneManagement.showArrangements"
                                )
                                .onHover { isShowArrangementsHovered = $0 }
                            }

                            Spacer()
                        }
                        .padding(AppStyles.General.Spacing.standard)
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // Quarter-moon split and browser buttons (top-right, management layer)
                if managementLayer.isActive && !isSplitResizing && !suppressMainPaneManagementInteraction() {
                    VStack {
                        HStack {
                            Spacer()
                            VStack(spacing: AppStyles.General.Spacing.standard) {
                                if let splitPresentation {
                                    paneEdgeCommandButton(
                                        presentation: splitPresentation,
                                        systemName: "plus",
                                        isHovered: isSplitHovered,
                                        accessibilityIdentifier: "paneManagement.addPane"
                                    ) {
                                        splitPresentation.perform()
                                    }
                                    .onHover { isSplitHovered = $0 }
                                }

                                paneEdgeButton(
                                    systemName: "globe",
                                    isHovered: isBrowserHovered,
                                    toolTipText: LocalActionSpec.openGitHubInNewTab.actionSpec.helpText
                                ) {
                                    onOpenPaneGitHub(paneHost.id)
                                }
                                .onHover { isBrowserHovered = $0 }
                                .accessibilityIdentifier("paneManagement.openBrowser")
                            }
                        }
                        .padding(.top, AppStyles.General.Spacing.standard)
                        Spacer()

                        HStack {
                            Spacer()
                            switch PaneManagementTrailingControl.resolve(
                                isDrawerChild: isDrawerChild
                            ) {
                            case .detachDrawerPane:
                                if let detachPresentation {
                                    ManagementTrailingEdgeTabButton(
                                        systemName: SystemSymbol.rectanglePortraitAndArrowRight.rawValue,
                                        isHovered: isDetachHovered,
                                        isEnabled: detachPresentation.isEnabled,
                                        tooltip: detachPresentation.spec.controlTooltipRenderValue(),
                                        accessibilityIdentifier: "paneManagement.detachDrawerPane",
                                        onAnchorViewChanged: nil
                                    ) {
                                        detachPresentation.perform()
                                    }
                                    .onHover { isDetachHovered = $0 }
                                }
                            case .movePaneToTab:
                                if !managementContext.showsIdentityBlock,
                                    let inlineMovePresentation
                                {
                                    movePaneTrailingEdgeTabButton(inlineMovePresentation)
                                }
                            }
                        }
                        .padding(.bottom, AppStyles.General.Spacing.standard)
                    }
                    .allowsHitTesting(true)
                    .transition(.opacity)
                }

                PaneManagementContextMenuCaptureBridge(
                    isEnabled: managementLayer.isActive
                        && managementChromePresentation == .ordinary
                        && !isDrawerChild
                        && !isClosing
                        && !suppressMainPaneManagementInteraction()
                ) { event, captureView in
                    presentPaneManagementContextMenu(event: event, in: captureView)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            }
            .overlayPreferenceValue(ManagementPaneIdentityCardBoundsPreferenceKey.self) { identityCardBounds in
                GeometryReader { overlayGeometry in
                    if managementLayer.isActive,
                        managementChromePresentation == .ordinary,
                        !isDrawerChild,
                        !isSplitResizing,
                        !suppressMainPaneManagementInteraction(),
                        managementContext.showsIdentityBlock,
                        let identityCardBounds,
                        let inlineMovePresentation
                    {
                        let cardFrame = overlayGeometry[identityCardBounds]
                        movePaneTrailingEdgeTabButton(inlineMovePresentation)
                            .position(
                                x: overlayGeometry.size.width
                                    - (AppStyles.Shell.PaneChrome.paneSplitButtonSize / 2),
                                y: cardFrame.minY
                                    - AppStyles.General.Spacing.standard
                                    - (AppStyles.Shell.PaneChrome.paneEdgeButtonHeight / 2)
                            )
                    }
                }
            }
            .contentShape(Rectangle())
            .onHover { hovered in
                isHovered =
                    managementLayer.isActive && self.suppressMainPaneManagementInteraction
                    ? false : hovered
            }
            .onTapGesture {
                if let drawerParentPaneId = self.drawerParentPaneId {
                    onPaneFocusTrigger(
                        .drawer(
                            .selectPane(parentPaneId: drawerParentPaneId, drawerPaneId: paneHost.id)
                        )
                    )
                } else {
                    onPaneFocusTrigger(
                        .contentClick(
                            PaneContentClickFocusTrigger(
                                targetPaneId: paneHost.id,
                                location: .content,
                                clickPhase: .completed
                            )
                        )
                    )
                }
            }
            .opacity(isClosing ? 0.58 : 1)
            .scaleEffect(isClosing ? 0.985 : 1)
            .zIndex(isClosing ? 1 : 0)
            .animation(.easeOut(duration: AppStyles.General.Animation.fast), value: isClosing)
            .allowsHitTesting(!isClosing)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.panel))
        .padding(AppStyles.General.Layout.paneGap)
        .background(
            GeometryReader { geo in
                ZStack {
                    if let dropTargetCoordinateSpace {
                        // Report pane frame for overlay positioning in the configured container
                        // coordinate space (tab container or drawer container).
                        let rawFrame = geo.frame(in: .named(dropTargetCoordinateSpace))
                        let measuredFrame = normalizedMeasuredFrame(from: rawFrame)
                        let frameDestinations = PaneFramePublicationPolicy.destinations(
                            useDrawerFramePreference: useDrawerFramePreference
                        )
                        if frameDestinations.contains(.drawerContainer) {
                            Color.clear.preference(
                                key: DrawerPaneFramePreferenceKey.self,
                                value: [paneHost.id: measuredFrame]
                            )
                        } else {
                            Color.clear.preference(
                                key: PaneFramePreferenceKey.self,
                                value: [paneHost.id: measuredFrame]
                            )
                        }
                    } else {
                        Color.clear
                    }
                }
            }
        )
    }
}

extension PaneLeafContainer {
    func beginCloseTransition() {
        guard
            let closePresentation = commandPresentation(
                .closePane,
                surface: .inlineControl
            ),
            closePresentation.isEnabled
        else {
            return
        }
        RestoreTrace.log(
            "PaneLeafContainer.beginCloseTransition pane=\(paneHost.id) drawerChild=\(drawerParentPaneId != nil) tab=\(tabId) closing=\(isClosing)"
        )
        closeTransitionCoordinator.beginClosingPane(paneHost.id) {
            RestoreTrace.log(
                "PaneLeafContainer.performClose pane=\(self.paneHost.id) drawerChild=\(self.drawerParentPaneId != nil) tab=\(self.tabId)"
            )
            closePresentation.perform()
        }
    }

    private func commandPresentation(
        _ command: AppCommand,
        surface: AppCommandSurface
    ) -> PaneLeafCommandPresentation? {
        PaneLeafCommandPresentation.resolve(
            command: command,
            surface: surface,
            targetPaneId: paneHost.id,
            dispatcher: commandDispatcher
        )
    }

    private func tabDisplayTitle(tab: AgentStudioCore.Tab) -> String {
        atom(\.paneDisplay).tabDisplayLabel(for: tab)
    }

    private func paneDisplayTitle(_ paneId: UUID) -> String {
        atom(\.paneDisplay).displayLabel(for: paneId)
    }

    private func managementCircleButton(
        action: PaneSurfaceToolbarAction,
        isHovered: Bool,
        accessibilityIdentifier: String
    ) -> some View {
        Button(action: action.perform) {
            Group {
                switch action.state.icon {
                case .system(let symbol):
                    Image(systemName: symbol.rawValue)
                        .font(.system(size: AppStyles.Shell.ManagementLayer.actionIconSize, weight: .bold))
                case .octicon(let symbol):
                    OcticonImage(
                        name: symbol.rawValue,
                        size: AppStyles.Shell.ManagementLayer.actionIconSize,
                        loader: octiconLoader
                    )
                }
            }
            .foregroundStyle(
                .white.opacity(
                    AppStyles.Shell.ManagementLayer.iconOpacity(isHovered: isHovered)
                )
            )
            .frame(
                width: AppStyles.Shell.ManagementLayer.actionSize,
                height: AppStyles.Shell.ManagementLayer.actionSize
            )
            .background(
                Circle()
                    .fill(
                        Color.black.opacity(
                            AppStyles.Shell.ManagementLayer.backgroundOpacity(isHovered: isHovered)
                        )
                    )
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!action.state.isEnabled)
        .controlHelp(action.state.tooltip)
        .accessibilityHidden(true)
        .background {
            AccessibilityPressBridge(
                identifier: accessibilityIdentifier,
                label: action.state.label,
                isEnabled: action.state.isEnabled,
                action: action.perform
            )
        }
    }

    private func managementCommandCircleButton(
        presentation: PaneLeafCommandPresentation,
        systemName: String,
        isHovered: Bool,
        accessibilityIdentifier: String,
        additionalEnabledState: Bool = true,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        let isEnabled = presentation.isEnabled && additionalEnabledState
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppStyles.Shell.ManagementLayer.actionIconSize, weight: .bold))
                .foregroundStyle(
                    .white.opacity(
                        AppStyles.Shell.ManagementLayer.iconOpacity(isHovered: isHovered)
                    )
                )
                .frame(
                    width: AppStyles.Shell.ManagementLayer.actionSize,
                    height: AppStyles.Shell.ManagementLayer.actionSize
                )
                .background(
                    Circle()
                        .fill(
                            Color.black.opacity(
                                AppStyles.Shell.ManagementLayer.backgroundOpacity(isHovered: isHovered)
                            )
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .controlHelp(presentation.spec.controlTooltipRenderValue())
        .accessibilityHidden(true)
        .background {
            AccessibilityPressBridge(
                identifier: accessibilityIdentifier,
                label: presentation.spec.label,
                isEnabled: isEnabled,
                action: action
            )
        }
    }

    private func paneEdgeButton(
        systemName: String,
        isHovered: Bool,
        toolTipText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            paneEdgeButtonLabel(systemName: systemName, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .help(toolTipText)
    }

    private func paneEdgeCommandButton(
        presentation: PaneLeafCommandPresentation,
        systemName: String,
        isHovered: Bool,
        accessibilityIdentifier: String,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        Button(action: action) {
            paneEdgeCommandButtonLabel(
                systemName: systemName,
                isHovered: isHovered
            )
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .controlHelp(presentation.spec.controlTooltipRenderValue())
        .accessibilityHidden(true)
        .background {
            AccessibilityPressBridge(
                identifier: accessibilityIdentifier,
                label: presentation.spec.label,
                isEnabled: presentation.isEnabled,
                action: action
            )
        }
    }

    private func presentMovePaneDestinationMenu(
        _ presentation: PaneLeafCommandPresentation
    ) {
        guard
            presentation.isEnabled,
            let movePaneMenuAnchorView
        else {
            return
        }
        movePaneMenuPresenter.present(
            destinations: movePaneDestinations.map { destination in
                PaneMoveDestinationMenuPresenter.Destination(
                    title: destination.title,
                    perform: {
                        movePane(to: destination, presentation: presentation)
                    }
                )
            },
            from: movePaneMenuAnchorView
        )
    }

    private func presentPaneManagementContextMenu(
        event: NSEvent,
        in captureView: NSView
    ) -> Bool {
        guard
            managementLayer.isActive,
            managementChromePresentation == .ordinary,
            !isDrawerChild,
            !isClosing,
            !suppressMainPaneManagementInteraction
        else {
            return false
        }

        let extractPresentation = commandPresentation(
            .extractPaneToTab,
            surface: .contextMenu
        )
        let movePresentation = commandPresentation(
            .movePaneToTab,
            surface: .contextMenu
        )
        return contextMenuPresenter.present(
            extractPresentation: extractPresentation,
            movePresentation: movePresentation,
            destinationProvider: {
                movePaneDestinations.map { destination in
                    PaneMoveDestinationMenuPresenter.Destination(
                        title: destination.title,
                        perform: {
                            guard let movePresentation else { return }
                            movePane(to: destination, presentation: movePresentation)
                        }
                    )
                }
            },
            event: event,
            in: captureView
        )
    }

    private func movePaneTrailingEdgeTabButton(
        _ presentation: PaneLeafCommandPresentation
    ) -> some View {
        ManagementTrailingEdgeTabButton(
            systemName: SystemSymbol.arrowLeftArrowRight.rawValue,
            isHovered: isMovePaneHovered,
            isEnabled: presentation.isEnabled,
            tooltip: presentation.spec.controlTooltipRenderValue(),
            accessibilityIdentifier: "paneManagement.movePaneToTab",
            onAnchorViewChanged: { view in
                if movePaneMenuAnchorView !== view {
                    movePaneMenuAnchorView = view
                }
            },
            action: {
                presentMovePaneDestinationMenu(presentation)
            }
        )
        .onHover { isMovePaneHovered = $0 }
    }

    private func movePane(
        to destination: MovePaneDestination,
        presentation: PaneLeafCommandPresentation
    ) {
        guard store.tabLayoutAtom.tab(destination.tabId) != nil else { return }

        presentation.movePane(
            sourceTabId: tabId,
            targetTabId: destination.tabId
        )
    }

    private func paneEdgeCommandButtonLabel(
        systemName: String,
        isHovered: Bool
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: AppStyles.Shell.PaneChrome.paneSplitIconSize, weight: .bold))
            .foregroundStyle(
                .white.opacity(AppStyles.Shell.ManagementLayer.iconOpacity(isHovered: isHovered))
            )
            .frame(
                width: AppStyles.Shell.PaneChrome.paneSplitButtonSize,
                height: AppStyles.Shell.PaneChrome.paneEdgeButtonHeight
            )
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: AppStyles.General.CornerRadius.panel + 4,
                    bottomLeadingRadius: AppStyles.General.CornerRadius.panel + 4,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
                .fill(
                    Color.black.opacity(
                        AppStyles.Shell.ManagementLayer.backgroundOpacity(isHovered: isHovered)
                    )
                )
            )
            .contentShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: AppStyles.General.CornerRadius.panel + 4,
                    bottomLeadingRadius: AppStyles.General.CornerRadius.panel + 4,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
            )
    }

    private func paneEdgeButtonLabel(
        systemName: String,
        isHovered: Bool
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: AppStyles.Shell.PaneChrome.paneSplitIconSize, weight: .bold))
            .foregroundStyle(
                .white.opacity(AppStyles.Shell.ManagementLayer.iconOpacity(isHovered: isHovered))
            )
            .frame(
                width: AppStyles.Shell.PaneChrome.paneSplitButtonSize,
                height: AppStyles.Shell.PaneChrome.paneEdgeButtonHeight
            )
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: AppStyles.General.CornerRadius.panel + 4,
                    bottomLeadingRadius: AppStyles.General.CornerRadius.panel + 4,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
                .fill(
                    Color.black.opacity(
                        AppStyles.Shell.ManagementLayer.backgroundOpacity(isHovered: isHovered)
                    )
                )
            )
            .contentShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: AppStyles.General.CornerRadius.panel + 4,
                    bottomLeadingRadius: AppStyles.General.CornerRadius.panel + 4,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
            )
    }

    private var currentLocationTargetPaneId: UUID {
        currentLocationTargetPaneId(drawer: drawer)
    }

    private func currentLocationTargetPaneId(drawer: Drawer?) -> UUID {
        guard let drawer,
            drawer.isExpanded,
            let drawerView = atom(\.arrangementView).drawerView(forParent: paneHost.id),
            let drawerPaneId = drawerView.activeChildId,
            !drawerView.minimizedPaneIds.contains(drawerPaneId)
        else {
            return paneHost.id
        }

        return drawerPaneId
    }
}
