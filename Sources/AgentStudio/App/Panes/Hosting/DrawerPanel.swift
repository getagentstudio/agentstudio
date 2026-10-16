import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI

// MARK: - DrawerResizeHandle

/// Callbacks for the normal-mode top-edge resize gesture.
///
/// Pointer positions are reported in the fixed `"tabContainer"` space, never
/// the handle's own moving bounds. `onTerminated` runs after every gesture,
/// including cancellations that never reach `onEnded`.
struct DrawerResizeInteraction {
    let onChanged: (_ gestureID: DrawerResizeGestureID, _ pointerYInTabContainer: CGFloat) -> Void
    let onEnded: (_ gestureID: DrawerResizeGestureID) -> Void
    let onTerminated: (_ gestureID: DrawerResizeGestureID?) -> Void
}

/// Draggable resize handle at the top of a normal-mode drawer panel.
struct DrawerResizeHandle: View {
    static let accessibilityIdentifier = "drawerPanel.resizeHandle"

    let interaction: DrawerResizeInteraction
    @GestureState private var isGestureActive = false
    /// Identity of the gesture in progress, minted at its first sample.
    @State private var activeGestureID: DrawerResizeGestureID?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: DrawerLayout.resizeHandleHeight)
            .contentShape(Rectangle())
            .background {
                AccessibilityLabelBridge(
                    identifier: Self.accessibilityIdentifier,
                    label: "Resize drawer",
                    exposesAccessibility: false
                )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(isGestureActive ? 0.4 : 0.2))
                    .frame(width: DrawerLayout.resizeHandlePillWidth, height: DrawerLayout.resizeHandlePillHeight)
            )
            .gesture(
                DragGesture(coordinateSpace: .named("tabContainer"))
                    .updating($isGestureActive) { _, isActive, _ in
                        isActive = true
                    }
                    .onChanged { value in
                        let gestureID = activeGestureID ?? .make()
                        activeGestureID = gestureID
                        interaction.onChanged(gestureID, value.location.y)
                    }
                    .onEnded { _ in
                        guard let activeGestureID else { return }
                        interaction.onEnded(activeGestureID)
                    }
            )
            // Gesture state resets on both completion and cancellation; the
            // reset is observed after `onEnded` has already committed.
            .onChange(of: isGestureActive) { _, isActive in
                if !isActive {
                    interaction.onTerminated(activeGestureID)
                    activeGestureID = nil
                }
            }
    }
}

/// Inert top band used where the drawer has no resize input (Pane Zoom).
/// Keeps the border thickness without a gesture or accessibility target.
struct DrawerInertTopBand: View {
    var body: some View {
        Color.clear
            .frame(height: DrawerLayout.resizeHandleHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - DrawerPanel

/// Floating drawer panel that overlays pane content.
/// Renders the drawer's flat pane strip inside a rectangular panel
/// with a resize handle at the top and material background.
///
/// Translates tab-level PaneActions dispatched by pane leaves
/// into drawer-specific actions (resize, minimize, close, focus, equalize).
struct DrawerPanel: View {
    let layout: DrawerGridLayout
    let octiconLoader: OcticonLoader
    let parentPaneId: UUID
    let tabId: UUID
    let activeChildId: UUID?
    let minimizedPaneIds: Set<UUID>
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let height: CGFloat
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let editorChooser: EditorChooserState
    let viewRegistry: ViewRegistry
    let action: (WorkspaceActionCommand) -> Void
    let commandDispatcher: any AppCommandDispatching
    let arrangementInlineRenameState: ArrangementInlineRenameState
    /// Normal-mode resize input. `nil` in Pane Zoom, which has no resize target.
    let resizeInteraction: DrawerResizeInteraction?
    let onDismiss: () -> Void
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let onFocusParentPane: () -> Void
    let appLifecycleStore: AppLifecycleAtom
    let paneInboxPresentation: PaneInboxPresentation?
    let onOpenPaneGitHub: (UUID) -> Void
    let dropTarget: DrawerRearrangeTarget?
    /// Active drag's source pane id, used to omit self/adjacent
    /// targets from the visuals dict the overlay paints (R1, R2, R8).
    let dragSourcePaneId: UUID?
    let workspaceWindowId: UUID?

    @State private var drawerPaneFrames: [UUID: CGRect] = [:]
    @State private var drawerActionDispatcher: PaneTabActionDispatcher
    private var managementLayer: ManagementLayerAtom {
        atom(\.managementLayer)
    }

    private var commandActionResolver: TargetedCommandControlActionResolver {
        let commandDispatcher = self.commandDispatcher
        return { command, surface, target, targetType in
            TargetedCommandControlAction.resolve(
                command: command,
                surface: surface,
                target: target,
                targetType: targetType,
                dispatcher: commandDispatcher
            )
        }
    }

    private var drawerSurfaceId: String {
        "drawerShell:\(parentPaneId)"
    }

    private var renderedDrawerPaneIds: Set<UUID> {
        Self.renderedPaneIds(
            layout: layout,
            minimizedPaneIds: minimizedPaneIds,
            isManagementLayerActive: managementLayer.isActive
        )
    }

    init(
        layout: DrawerGridLayout,
        octiconLoader: OcticonLoader,
        parentPaneId: UUID,
        tabId: UUID,
        activeChildId: UUID?,
        minimizedPaneIds: Set<UUID>,
        closeTransitionCoordinator: PaneCloseTransitionCoordinator,
        height: CGFloat,
        store: WorkspaceStore,
        repoCache: RepoCacheAtom,
        editorChooser: EditorChooserState,
        viewRegistry: ViewRegistry,
        action: @escaping (WorkspaceActionCommand) -> Void,
        commandDispatcher: any AppCommandDispatching,
        arrangementInlineRenameState: ArrangementInlineRenameState,
        resizeInteraction: DrawerResizeInteraction?,
        onDismiss: @escaping () -> Void,
        onPaneFocusTrigger: @escaping PaneFocusTriggerHandler,
        onFocusParentPane: @escaping () -> Void,
        appLifecycleStore: AppLifecycleAtom,
        paneInboxPresentation: PaneInboxPresentation?,
        onOpenPaneGitHub: @escaping (UUID) -> Void,
        dropTarget: DrawerRearrangeTarget?,
        dragSourcePaneId: UUID?,
        workspaceWindowId: UUID? = nil
    ) {
        self.layout = layout
        self.octiconLoader = octiconLoader
        self.parentPaneId = parentPaneId
        self.tabId = tabId
        self.activeChildId = activeChildId
        self.minimizedPaneIds = minimizedPaneIds
        self.closeTransitionCoordinator = closeTransitionCoordinator
        self.height = height
        self.store = store
        self.repoCache = repoCache
        self.editorChooser = editorChooser
        self.viewRegistry = viewRegistry
        self.action = action
        self.commandDispatcher = commandDispatcher
        self.arrangementInlineRenameState = arrangementInlineRenameState
        self.resizeInteraction = resizeInteraction
        self.onDismiss = onDismiss
        self.onPaneFocusTrigger = onPaneFocusTrigger
        self.onFocusParentPane = onFocusParentPane
        self.appLifecycleStore = appLifecycleStore
        self.paneInboxPresentation = paneInboxPresentation
        self.onOpenPaneGitHub = onOpenPaneGitHub
        self.dropTarget = dropTarget
        self.dragSourcePaneId = dragSourcePaneId
        self.workspaceWindowId = workspaceWindowId
        self._drawerActionDispatcher = State(
            initialValue: PaneTabActionDispatcher(
                dispatch: { paneAction in
                    action(Self.drawerCommand(for: paneAction, parentPaneId: parentPaneId))
                },
                shouldHandleSplitDragPayload: { _ in true },
                shouldAcceptDrop: { _, _, _, _ in false },
                handleDrop: { _, _, _, _ in
                    #if DEBUG
                        assertionFailure("DrawerPanel drop handling is routed by the drawer overlay")
                    #endif
                }
            )
        )
    }

    nonisolated static func drawerCommand(
        for paneAction: WorkspaceActionCommand,
        parentPaneId: UUID
    ) -> WorkspaceActionCommand {
        switch paneAction {
        case .resizePane(_, let splitId, let ratio):
            return .resizeDrawerPane(parentPaneId: parentPaneId, splitId: splitId, ratio: ratio)
        case .resizeVisiblePanePair(_, let leftPaneId, let rightPaneId, let ratio):
            return .resizeDrawerVisiblePanePair(
                parentPaneId: parentPaneId,
                leftPaneId: leftPaneId,
                rightPaneId: rightPaneId,
                ratio: ratio
            )
        case .equalizePanes:
            return .equalizeDrawerPanes(parentPaneId: parentPaneId)
        case .minimizePane(_, let paneId):
            return .minimizeDrawerPane(parentPaneId: parentPaneId, drawerPaneId: paneId)
        case .expandPane(_, let paneId):
            return .expandDrawerPane(parentPaneId: parentPaneId, drawerPaneId: paneId)
        case .closePane(let tabId, let paneId):
            return .closePane(tabId: tabId, paneId: paneId)
        case .insertPaneRequest(let request):
            return .insertDrawerPane(
                parentPaneId: parentPaneId,
                targetDrawerPaneId: request.targetPaneId,
                direction: request.direction,
                sizingMode: request.sizingMode
            )
        default:
            return paneAction
        }
    }

    /// Translates tab-level actions into drawer-specific actions.
    /// Pane leaf interactions dispatch actions using tabId, but in the drawer
    /// context these need to be routed to drawer operations.
    @ViewBuilder
    private func rowContent(_ rowLayout: AgentStudioCore.Layout) -> some View {
        FlatPaneStripContent(
            layout: rowLayout,
            octiconLoader: octiconLoader,
            tabId: tabId,
            activePaneId: activeChildId,
            minimizedPaneIds: minimizedPaneIds,
            adjacentResizeTargeting: .canonicalDivider,
            ordinalMap: PaneOrdinalMap(orderedPaneIds: layout.paneIds),
            collapsedPaneWidth: managementLayer.isActive ? CollapsedPaneBar.barWidth : 0,
            arrangementInlineRenameState: arrangementInlineRenameState,
            commandActionResolver: commandActionResolver,
            commandDispatcher: commandDispatcher,
            closeTransitionCoordinator: closeTransitionCoordinator,
            actionDispatcher: drawerActionDispatcher,
            onPaneFocusTrigger: onPaneFocusTrigger,
            onFocusPane: { _ in onFocusParentPane() },
            store: store,
            repoCache: repoCache,
            editorChooser: editorChooser,
            viewRegistry: viewRegistry,
            coordinateSpaceName: Self.drawerDropCoordinateSpace,
            useDrawerFramePreference: true,
            isInactivePersistentTab: false,
            paneInboxPresentation: paneInboxPresentation,
            paneNotePresentation: nil,
            onOpenPaneGitHub: onOpenPaneGitHub,
            workspaceWindowId: workspaceWindowId,
            paneSurfaceToolbarPresentation: { paneId in
                guard let pane = store.paneAtom.pane(paneId) else {
                    return .hidden
                }
                return PaneSurfaceToolbarResolver.resolve(
                    content: pane.content,
                    placement: .drawerChild
                )
            }
        )
    }

    /// Empty-drawer keystroke hint. Both halves come from the existing
    /// command-spec system so the on-screen text stays in lockstep with
    /// the keystroke gate and the command's action label.
    ///   key   ──► AppShortcut.addDrawerPane displayed in `.emptyDrawer`
    ///             context (returns the raw-character alternate "P").
    ///   text  ──► LocalActionSpec.addDrawerPane.actionSpec.helpText
    @ViewBuilder
    private var emptyDrawerHint: some View {
        let keyDisplay = AppShortcut.addDrawerPane.displayKeyBinding(in: .emptyDrawer)?.displayString ?? ""
        let actionText = LocalActionSpec.addDrawerPane.actionSpec.helpText.lowercased()
        Text("Press \(keyDisplay) to \(actionText)")
            .font(.system(size: AppStyles.General.Typography.textXs))
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var addDrawerButton: some View {
        let addDrawerPaneAction = commandActionResolver(
            .addDrawerPane,
            .inlineControl,
            parentPaneId,
            .pane
        )

        if let addDrawerPaneAction {
            Button(action: addDrawerPaneAction.perform) {
                Image(systemName: "plus")
                    .font(.system(size: AppStyles.General.Typography.text2xl, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(AppStyles.General.Fill.hover))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!addDrawerPaneAction.isEnabled)
            .controlHelp(addDrawerPaneAction.commandSpec.controlTooltipRenderValue())
            .accessibilityLabel(addDrawerPaneAction.commandSpec.label)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let containerBounds = CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if let resizeInteraction {
                        DrawerResizeHandle(interaction: resizeInteraction)
                    } else {
                        DrawerInertTopBand()
                    }

                    if !layout.isEmpty {
                        // Row-to-row spacing matches horizontal pane gap so the
                        // grid reads as a uniform 2x2 arrangement instead of
                        // two visually separate strips.
                        VStack(spacing: AppStyles.General.Layout.paneGap) {
                            rowContent(layout.topRow)
                            if let bottomRow = layout.bottomRow {
                                rowContent(bottomRow)
                            }
                        }
                        .padding(.horizontal, DrawerLayout.panelContentPadding)
                        .padding(.bottom, DrawerLayout.panelContentPadding)
                    } else {
                        VStack(spacing: 12) {
                            Spacer()
                            addDrawerButton
                            emptyDrawerHint
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if managementLayer.isActive {
                    DrawerDropTargetOverlay(
                        target: dropTarget,
                        targetVisuals: DrawerPaneDragCoordinator.targetVisuals(
                            geometry: DrawerPaneDragGeometry(
                                paneFrames: drawerPaneFrames,
                                layout: layout,
                                containerBounds: containerBounds,
                                minimizedPaneIds: minimizedPaneIds,
                                excludedPaneIds: dragSourcePaneId.map { [$0] } ?? []
                            )
                        )
                    )
                    .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(DrawerPaneFramePreferenceKey.self) { drawerPaneFrames = $0 }
        }
        .frame(height: height)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: DrawerPanelFrameInTabKey.self,
                    value: geometry.frame(in: .named("tabContainer"))
                )
            }
        )
        .coordinateSpace(name: Self.drawerDropCoordinateSpace)
        .contentShape(RoundedRectangle(cornerRadius: DrawerLayout.panelCornerRadius, style: .continuous))
        .modifier(
            DrawerSurfaceRegistrationModifier(
                viewRegistry: viewRegistry,
                surfaceId: drawerSurfaceId,
                renderedPaneIds: renderedDrawerPaneIds
            )
        )
    }

    private static let drawerDropCoordinateSpace = "drawerContainer"

    static func renderedPaneIds(
        layout: DrawerGridLayout,
        minimizedPaneIds: Set<UUID>,
        isManagementLayerActive: Bool
    ) -> Set<UUID> {
        guard !isManagementLayerActive else {
            return Set(layout.paneIds)
        }
        return Set(layout.paneIds.filter { !minimizedPaneIds.contains($0) })
    }
}

private struct DrawerSurfaceRegistrationModifier: ViewModifier {
    let viewRegistry: ViewRegistry
    let surfaceId: String
    let renderedPaneIds: Set<UUID>

    func body(content: Content) -> some View {
        content
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
}

// Panel material is now applied at the DrawerPanelOverlay level
// using the unified DrawerOutlineShape (panel + S-curve connector as one surface).

// MARK: - Preview

#if DEBUG
    /// Fail-closed command route used only by SwiftUI previews.
    @MainActor
    final class PreviewAppCommandDispatcher: AppCommandDispatching {
        func dispatch(_ command: AppCommand) -> Bool { false }

        func dispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) {}

        func dispatchKeyboardShortcut(_ shortcut: AppShortcut) {}

        func dispatchExtractPaneToTab(
            tabId: UUID,
            paneId: UUID,
            targetTabInsertionIndex: Int?
        ) {}

        func canDispatch(_ command: AppCommand) -> Bool { false }

        func canDispatch(
            _ command: AppCommand,
            target: UUID,
            targetType: SearchItemType
        ) -> Bool { false }

        func bridgePaneCommandTarget(worktreeId: UUID) -> BridgePaneCommandTarget? { nil }

        func dispatchMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID) {}
    }

    @MainActor
    struct DrawerPanel_Previews: PreviewProvider {
        static var previews: some View {
            let atomRegistry = AtomRegistry()
            let commandDispatcher = PreviewAppCommandDispatcher()
            let store = WorkspaceStore(
                identityAtom: atomRegistry.core.workspaceIdentity,
                windowMemoryAtom: atomRegistry.core.workspaceWindowMemory,
                repositoryTopologyAtom: atomRegistry.core.workspaceRepositoryTopology,
                paneAtom: atomRegistry.core.workspacePane,
                tabLayoutAtom: atomRegistry.core.workspaceTabLayout,
                mutationCoordinator: atomRegistry.core.workspaceMutationCoordinator
            )
            VStack {
                Spacer()
                DrawerPanel(
                    layout: DrawerGridLayout(),
                    octiconLoader: OcticonLoader(resourceBundle: Bundle.appResources),
                    parentPaneId: UUID(),
                    tabId: UUID(),
                    activeChildId: nil,
                    minimizedPaneIds: [],
                    closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                    height: 200,
                    store: store,
                    repoCache: RepoCacheAtom(),
                    editorChooser: atomRegistry.editorChooser,
                    viewRegistry: ViewRegistry(),
                    action: { _ in },
                    commandDispatcher: commandDispatcher,
                    arrangementInlineRenameState: ArrangementInlineRenameState(),
                    resizeInteraction: nil,
                    onDismiss: {},
                    onPaneFocusTrigger: { _ in },
                    onFocusParentPane: {},
                    appLifecycleStore: AppLifecycleAtom(),
                    paneInboxPresentation: nil,
                    onOpenPaneGitHub: { _ in },
                    dropTarget: nil,
                    dragSourcePaneId: nil
                )
                Spacer()
            }
            .frame(width: 500, height: 400)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
#endif
