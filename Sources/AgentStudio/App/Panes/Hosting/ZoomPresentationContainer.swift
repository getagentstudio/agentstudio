import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import Foundation
import SwiftUI

typealias ZoomExitAnimationPerformer =
    @MainActor (
        _ updates: () -> Void,
        _ completion: @escaping () -> Void
    ) -> Void

enum ZoomManagementTitle {
    static func text(
        sourceOrdinal: Int?,
        activeArrangementName: String?
    ) -> String? {
        guard let sourceOrdinal else { return nil }
        let arrangementName =
            activeArrangementName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !arrangementName.isEmpty else { return nil }
        return "\(sourceOrdinal) · \(arrangementName) · Zoom"
    }
}

@MainActor
struct ZoomPresentationChild {
    let paneId: UUID
    let paneSlot: ViewRegistry.PaneViewSlot
    let toolbarPresentation: PaneSurfaceToolbarPresentation
}

/// How a Zoom composition's companion (Bridge) region occupies the split:
/// whether the divider space is reserved and whether the region is visible.
/// Shared by the live container and drawer bootstrap geometry.
struct ZoomCompanionRegionLayout: Equatable {
    let reservesCompanionSpace: Bool
    let isCompanionVisible: Bool

    /// Mirrors `ZoomPresentationContainer.resolveRenderState`: a visible
    /// unavailable Viewer still occupies its region; a retained companion
    /// counts only once its host is registered.
    static func resolve(
        viewerPresentation: ZoomViewerPresentation,
        companionHostIsReady: (UUID) -> Bool
    ) -> Self {
        switch viewerPresentation {
        case .unavailable, .retryable:
            return Self(reservesCompanionSpace: false, isCompanionVisible: false)
        case .unavailableVisible:
            return Self(reservesCompanionSpace: true, isCompanionVisible: true)
        case .retainedHidden(let companionPaneId):
            return Self(reservesCompanionSpace: companionHostIsReady(companionPaneId), isCompanionVisible: false)
        case .retainedVisible(let companionPaneId):
            let isReady = companionHostIsReady(companionPaneId)
            return Self(reservesCompanionSpace: isReady, isCompanionVisible: isReady)
        }
    }
}

@MainActor
struct ZoomPresentationRenderState {
    let layout: AgentStudioCore.Layout
    let children: [ZoomPresentationChild]
    let isCompanionVisible: Bool
    let parentToolbar: PaneSurfaceToolbarPresentation
}

@MainActor
struct ZoomPresentationContainer: View {
    let tabId: UUID?
    let sourcePaneId: UUID
    let sourceOrdinal: Int?
    let sourceContent: AnyView
    let companionContent: AnyView?
    let isCompanionVisible: Bool
    let parentToolbarPresentation: PaneSurfaceToolbarPresentation
    let store: WorkspaceStore
    let octiconLoader: OcticonLoader
    let editorChooser: EditorChooserState
    let repoCache: RepoCacheAtom
    let appLifecycleStore: AppLifecycleAtom
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let paneInboxPresentation: PaneInboxPresentation?
    let paneNotePresentation: PaneNotePresentation?
    let workspaceWindowId: UUID?
    let actionDispatcher: PaneActionDispatching
    let commandDispatcher: any AppCommandDispatching
    let arrangementInlineRenameState: ArrangementInlineRenameState
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let onFocusPane: (UUID) -> Void
    let onOpenPaneGitHub: (UUID) -> Void
    let viewRegistry: ViewRegistry
    let surfaceId: String
    let renderedPaneIds: Set<UUID>
    private let performZoomExitAnimation: ZoomExitAnimationPerformer

    @State private var splitRatio: CGFloat
    @State private var showsZoomToolbarLabel = false
    @State private var isZoomExitPending = false
    @State private var zoomHovered = false
    @State private var showArrangementsHovered = false
    @State private var paneFrames: [UUID: CGRect] = [:]
    @State private var iconBarFrame: CGRect = .zero
    @State private var drawerDismissCoordinateView: NSView?
    /// Measured split area in `"tabContainer"` space; excludes the shared toolbar.
    @State private var splitAreaFrame: CGRect = .zero

    init(
        tabId: UUID? = nil,
        sourcePaneId: UUID,
        sourceOrdinal: Int?,
        sourceContent: AnyView,
        companionContent: AnyView?,
        isCompanionVisible: Bool = true,
        parentToolbarPresentation: PaneSurfaceToolbarPresentation,
        splitRatio: Double,
        store: WorkspaceStore,
        octiconLoader: OcticonLoader,
        editorChooser: EditorChooserState,
        repoCache: RepoCacheAtom = RepoCacheAtom(),
        appLifecycleStore: AppLifecycleAtom = AppLifecycleAtom(),
        closeTransitionCoordinator: PaneCloseTransitionCoordinator = PaneCloseTransitionCoordinator(),
        paneInboxPresentation: PaneInboxPresentation? = nil,
        paneNotePresentation: PaneNotePresentation? = nil,
        workspaceWindowId: UUID? = nil,
        actionDispatcher: PaneActionDispatching,
        commandDispatcher: any AppCommandDispatching,
        arrangementInlineRenameState: ArrangementInlineRenameState,
        onPaneFocusTrigger: @escaping PaneFocusTriggerHandler,
        onFocusPane: @escaping (UUID) -> Void = { _ in },
        onOpenPaneGitHub: @escaping (UUID) -> Void = { _ in },
        viewRegistry: ViewRegistry,
        surfaceId: String,
        renderedPaneIds: Set<UUID>,
        performZoomExitAnimation: @escaping ZoomExitAnimationPerformer = Self.performLiveZoomExitAnimation
    ) {
        self.tabId = tabId
        self.sourcePaneId = sourcePaneId
        self.sourceOrdinal = sourceOrdinal
        self.sourceContent = sourceContent
        self.companionContent = companionContent
        self.isCompanionVisible = isCompanionVisible
        self.parentToolbarPresentation = parentToolbarPresentation
        self.store = store
        self.octiconLoader = octiconLoader
        self.editorChooser = editorChooser
        self.repoCache = repoCache
        self.appLifecycleStore = appLifecycleStore
        self.closeTransitionCoordinator = closeTransitionCoordinator
        self.paneInboxPresentation = paneInboxPresentation
        self.paneNotePresentation = paneNotePresentation
        self.workspaceWindowId = workspaceWindowId
        self.actionDispatcher = actionDispatcher
        self.commandDispatcher = commandDispatcher
        self.arrangementInlineRenameState = arrangementInlineRenameState
        self.onPaneFocusTrigger = onPaneFocusTrigger
        self.onFocusPane = onFocusPane
        self.onOpenPaneGitHub = onOpenPaneGitHub
        self.viewRegistry = viewRegistry
        self.surfaceId = surfaceId
        self.renderedPaneIds = renderedPaneIds
        self.performZoomExitAnimation = performZoomExitAnimation
        _splitRatio = State(initialValue: CGFloat(splitRatio))
    }

    var body: some View {
        GeometryReader { tabGeometry in
            ZStack {
                VStack(spacing: 0) {
                    SplitView(
                        .horizontal,
                        viewerPresentationSplit,
                        left: { sourceContent },
                        right: {
                            companionContent
                        },
                        onEqualize: {
                            let defaultRatio = CGFloat(AppPolicies.PaneZoomSplit.defaultTerminalRatio)
                            splitRatio = defaultRatio
                            persistSplitRatio(defaultRatio)
                        },
                        showsDivider: isCompanionVisible,
                        reservesDividerSpace: companionContent != nil,
                        onResizeEnd: {
                            persistSplitRatio(splitRatio)
                        },
                        splitRatioBounds: CGFloat(
                            AppPolicies.PaneZoomSplit.minimumTerminalRatio)...CGFloat(
                                AppPolicies.PaneZoomSplit.maximumTerminalRatio
                            )
                    )
                    .onGeometryChange(for: CGRect.self) { geometry in
                        geometry.frame(in: .named("tabContainer"))
                    } action: { frame in
                        splitAreaFrame = frame
                    }
                    .overlay(alignment: .bottom) {
                        if atom(\.managementLayer).isActive,
                            sourceManagementContext.showsIdentityBlock
                        {
                            ManagementPaneIdentityOverlay(
                                context: sourceManagementContext,
                                octiconLoader: octiconLoader
                            )
                        }
                    }

                    parentToolbar(owningPaneSize: tabGeometry.size)
                }

                drawerPanelOverlay(tabSize: tabGeometry.size)

                if atom(\.managementLayer).isActive {
                    zoomManagementChrome
                }
            }
            .coordinateSpace(name: "tabContainer")
            .background(
                DrawerDismissCoordinateSpaceBridge { view in
                    if drawerDismissCoordinateView !== view {
                        drawerDismissCoordinateView = view
                    }
                }
                .allowsHitTesting(false)
            )
            .onPreferenceChange(PaneFramePreferenceKey.self) { paneFrames = $0 }
            .onPreferenceChange(DrawerIconBarFrameKey.self) { iconBarFrame = $0 }
        }
        .onAppear {
            viewRegistry.surfaceRenderedIds(surfaceId, ids: renderedPaneIds)
        }
        .onChange(of: renderedPaneIds) { _, paneIds in
            viewRegistry.surfaceRenderedIds(surfaceId, ids: paneIds)
        }
        .onDisappear {
            viewRegistry.unregisterSurface(surfaceId)
        }
    }

    /// A finished divider drag commits through the workspace action route,
    /// which writes the ratio and then re-evaluates queued drawer geometry.
    private func persistSplitRatio(_ splitRatio: CGFloat) {
        guard let tabId else { return }
        actionDispatcher.dispatch(.setZoomSplitRatio(tabId: tabId, ratio: Double(splitRatio)))
    }

    private var viewerPresentationSplit: Binding<CGFloat> {
        Binding(
            get: {
                isCompanionVisible ? splitRatio : 1
            },
            set: { newSplitRatio in
                guard isCompanionVisible else { return }
                splitRatio = newSplitRatio
            }
        )
    }

    @ViewBuilder
    private func parentToolbar(owningPaneSize: CGSize) -> some View {
        if case .zoom(let toolbarModel) = parentToolbarPresentation {
            let zoomAction = toolbarModel.zoomAction.map { zoomAction in
                sequencedZoomExitAction(
                    zoomAction.projectingVisibleLabel(
                        showsZoomToolbarLabel ? zoomAction.state.visibleLabel : nil
                    )
                )
            }
            PaneSurfaceToolbarHost(
                anchorPaneId: sourcePaneId,
                locationTargetPaneId: sourcePaneId,
                toolbarSurface: .terminalZoom,
                drawer: store.paneAtom.pane(sourcePaneId)?.drawer,
                leadingToolbarActions: [],
                contextToolbarActions: [zoomAction, toolbarModel.viewerAction].compactMap(\.self),
                store: store,
                repoCache: repoCache,
                octiconLoader: octiconLoader,
                editorChooser: editorChooser,
                paneInboxPresentation: paneInboxPresentation,
                paneNotePresentation: paneNotePresentation,
                workspaceWindowId: workspaceWindowId,
                owningPaneSize: owningPaneSize,
                actionDispatcher: actionDispatcher,
                commandDispatcher: commandDispatcher,
                onPaneFocusTrigger: onPaneFocusTrigger
            )
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                withAnimation(.easeInOut(duration: AppStyles.General.Animation.standard)) {
                    showsZoomToolbarLabel = true
                }
            }
        }
    }

    private func sequencedZoomExitAction(
        _ zoomAction: PaneSurfaceToolbarAction
    ) -> PaneSurfaceToolbarAction {
        PaneSurfaceToolbarAction(
            state: zoomAction.state,
            perform: {
                beginZoomToolbarExit(performCancel: zoomAction.perform)
            }
        )
    }

    private func beginZoomToolbarExit(
        performCancel: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !isZoomExitPending else { return }
        isZoomExitPending = true

        performZoomExitAnimation(
            {
                showsZoomToolbarLabel = false
            },
            {
                performCancel()
                isZoomExitPending = false
            })
    }

    private static func performLiveZoomExitAnimation(
        updates: () -> Void,
        completion: @escaping () -> Void
    ) {
        withAnimation(
            .easeOut(duration: AppStyles.General.Animation.fast),
            completionCriteria: .logicallyComplete,
            updates,
            completion: completion
        )
    }

    @ViewBuilder
    private var zoomManagementChrome: some View {
        if case .zoom(let toolbarModel) = parentToolbarPresentation {
            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .opacity(AppStyles.Shell.ManagementLayer.modeDimmingOpacity)
                    .allowsHitTesting(false)

                VStack {
                    HStack {
                        Spacer()
                        if let zoomManagementTitle {
                            zoomManagementTitleView(zoomManagementTitle)
                        }
                        Spacer()
                    }
                    .padding(AppStyles.General.Spacing.standard)
                    Spacer()
                }
                .allowsHitTesting(false)

                VStack {
                    HStack(spacing: AppStyles.General.Spacing.standard) {
                        if let zoomAction = toolbarModel.zoomAction {
                            managementCircleButton(
                                action: sequencedZoomExitAction(zoomAction),
                                isHovered: zoomHovered,
                                accessibilityIdentifier: "paneManagement.zoom"
                            )
                            .onHover { zoomHovered = $0 }
                        }

                        if let showArrangementsAction = toolbarModel.showArrangementsAction {
                            managementCircleButton(
                                action: showArrangementsAction,
                                isHovered: showArrangementsHovered,
                                accessibilityIdentifier: "paneManagement.showArrangements"
                            )
                            .onHover { showArrangementsHovered = $0 }
                        }

                        Spacer()
                    }
                    .padding(AppStyles.General.Spacing.standard)
                    Spacer()
                }
            }
        }
    }

    private var zoomManagementTitle: String? {
        let activeArrangementName =
            tabId
            .flatMap { store.tabLayoutAtom.tab($0) }?
            .activeArrangement
            .name
        return ZoomManagementTitle.text(
            sourceOrdinal: sourceOrdinal,
            activeArrangementName: activeArrangementName
        )
    }

    private var sourceManagementContext: PaneManagementContext {
        PaneManagementContext.project(
            paneId: sourcePaneId,
            store: store,
        )
    }

    private func zoomManagementTitleView(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppStyles.Shell.ManagementLayer.actionIconSize, weight: .bold))
            .foregroundStyle(
                .white.opacity(AppStyles.Shell.ManagementLayer.iconOpacity(isHovered: false))
            )
            .padding(.horizontal, AppStyles.General.Spacing.standard)
            .frame(height: AppStyles.Shell.ManagementLayer.actionSize)
            .background(
                Capsule()
                    .fill(
                        Color.black.opacity(
                            AppStyles.Shell.ManagementLayer.backgroundOpacity(isHovered: false)
                        )
                    )
                    .shadow(color: .black.opacity(AppStyles.General.Stroke.visible), radius: 4, y: 2)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .background {
                AccessibilityLabelBridge(
                    identifier: "paneManagement.zoomTitle",
                    label: title
                )
            }
    }

    @ViewBuilder
    private func drawerPanelOverlay(tabSize: CGSize) -> some View {
        if let tabId {
            DrawerPanelOverlay(
                store: store,
                octiconLoader: octiconLoader,
                repoCache: repoCache,
                editorChooser: editorChooser,
                viewRegistry: viewRegistry,
                appLifecycleStore: appLifecycleStore,
                closeTransitionCoordinator: closeTransitionCoordinator,
                tabId: tabId,
                presentation: drawerOverlayPresentation,
                paneFrames: paneFrames,
                tabSize: tabSize,
                iconBarFrame: iconBarFrame,
                actionDispatcher: actionDispatcher,
                commandDispatcher: commandDispatcher,
                arrangementInlineRenameState: arrangementInlineRenameState,
                onPaneFocusTrigger: onPaneFocusTrigger,
                onFocusPane: onFocusPane,
                paneInboxPresentation: paneInboxPresentation,
                onOpenPaneGitHub: onOpenPaneGitHub,
                drawerDropTarget: nil,
                dismissCoordinateView: drawerDismissCoordinateView,
                workspaceWindowId: workspaceWindowId,
                dragSourcePaneId: nil
            )
        }
    }

    /// Terminal and Bridge regions from the measured split area and the live
    /// split ratio, so an unfinished divider drag moves the drawer with it.
    private var drawerOverlayPresentation: DrawerOverlayPresentation {
        let regions = DrawerPresentationGeometryResolver.zoomRegions(
            splitArea: splitAreaFrame,
            sourceSplitRatio: splitRatio,
            reservesCompanionSpace: companionContent != nil,
            isCompanionVisible: isCompanionVisible
        )
        return .zoom(
            sourcePaneId: sourcePaneId,
            terminalRegion: regions.terminal,
            bridgeRegion: regions.bridge
        )
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

    static func resolveRenderState(
        presentation: ZoomPresentation,
        viewRegistry: ViewRegistry,
        parentToolbar: PaneSurfaceToolbarPresentation
    ) -> ZoomPresentationRenderState? {
        guard case .zoom = parentToolbar else {
            return nil
        }
        let sourcePaneSlot = viewRegistry.slot(for: presentation.sourcePaneId)
        guard sourcePaneSlot.host != nil else {
            return nil
        }

        var children = [
            ZoomPresentationChild(
                paneId: presentation.sourcePaneId,
                paneSlot: sourcePaneSlot,
                toolbarPresentation: .hidden
            )
        ]

        let layout: AgentStudioCore.Layout
        let isCompanionVisible: Bool
        switch presentation.viewerPresentation {
        case .unavailable, .retryable:
            layout = Layout(paneId: presentation.sourcePaneId)
            isCompanionVisible = false
        case .unavailableVisible:
            layout = Layout(paneId: presentation.sourcePaneId)
            isCompanionVisible = true

        case .retainedHidden(let companionPaneId), .retainedVisible(let companionPaneId):
            let companionPaneSlot = viewRegistry.slot(for: companionPaneId)
            if companionPaneSlot.host != nil {
                children.append(
                    ZoomPresentationChild(
                        paneId: companionPaneId,
                        paneSlot: companionPaneSlot,
                        toolbarPresentation: .hidden
                    )
                )
                let sourceRatio =
                    presentation.transientSplitRatio ?? AppPolicies.PaneZoomSplit.defaultTerminalRatio
                layout = AgentStudioCore.Layout(
                    panes: [
                        AgentStudioCore.Layout.PaneEntry(
                            paneId: presentation.sourcePaneId,
                            ratio: sourceRatio
                        ),
                        AgentStudioCore.Layout.PaneEntry(
                            paneId: companionPaneId,
                            ratio: 1 - sourceRatio
                        ),
                    ],
                    dividerIds: [UUIDv7.generate()]
                )
                if case .retainedVisible = presentation.viewerPresentation {
                    isCompanionVisible = true
                } else {
                    isCompanionVisible = false
                }
            } else {
                layout = Layout(paneId: presentation.sourcePaneId)
                isCompanionVisible = false
            }
        }

        return ZoomPresentationRenderState(
            layout: layout,
            children: children,
            isCompanionVisible: isCompanionVisible,
            parentToolbar: parentToolbar
        )
    }
}
