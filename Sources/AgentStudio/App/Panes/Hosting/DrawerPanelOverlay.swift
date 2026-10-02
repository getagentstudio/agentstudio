import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI

// MARK: - Dismiss Monitor

/// Monitors mouseDown events and dismisses the drawer when clicking outside
/// the drawer panel, connector, and icon bar regions.
/// Installed when the drawer opens, removed when it closes.
@MainActor
final class DrawerDismissMonitor {
    private var monitor: Any?
    private weak var coordinateView: NSView?
    /// Drawer panel + connector bounding rect in tab-container top-left coordinates.
    var drawerRectInTab: CGRect = .zero
    /// Icon bar bounding rect in tab-container top-left coordinates.
    var iconBarRectInTab: CGRect = .zero

    var onDismiss: () -> Void = {}

    init() {}

    func setCoordinateView(_ view: NSView?) {
        coordinateView = view
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            let shouldConsumeEvent = MainActor.assumeIsolated {
                guard let topLeftTabPoint = self.topLeftTabPoint(for: event) else { return false }

                // Returning nil consumes the event so the same click cannot also
                // make the underlying main pane firstResponder. Returning event
                // would dismiss the drawer AND focus whatever NSView is below —
                // a regression where outside clicks toggle drawer visibility but
                // also activate the main pane content underneath.
                return self.handleMouseDown(topLeftTabPoint: topLeftTabPoint)
            }
            return shouldConsumeEvent ? nil : event
        }
    }

    func topLeftTabPoint(for event: NSEvent) -> CGPoint? {
        guard let eventWindow = event.window else { return nil }
        guard let coordinateView else { return nil }
        guard coordinateView.window === eventWindow else { return nil }

        let localPoint = coordinateView.convert(event.locationInWindow, from: nil)
        return Self.topLeftPoint(
            fromAppKitPoint: localPoint,
            bounds: coordinateView.bounds,
            isFlipped: coordinateView.isFlipped
        )
    }

    static func topLeftPoint(
        fromAppKitPoint point: CGPoint,
        bounds: CGRect,
        isFlipped: Bool
    ) -> CGPoint {
        CGPoint(
            x: point.x - bounds.minX,
            y: isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        )
    }

    /// Outside-click dismissal test.
    ///
    /// Returns true when the click is outside both the drawer panel + connector
    /// region and the icon bar. Empty rects contain no points, so a click
    /// during a transient frame reset is treated as "outside both" and
    /// dismisses — this matches the working debug-branch behavior. The
    /// non-zero-only preference reducers keep the stored drawer and icon bar rects
    /// stable across SwiftUI re-publish cycles.
    func shouldDismiss(topLeftTabPoint: CGPoint) -> Bool {
        !drawerRectInTab.contains(topLeftTabPoint) && !iconBarRectInTab.contains(topLeftTabPoint)
    }

    @discardableResult
    func handleMouseDown(topLeftTabPoint: CGPoint) -> Bool {
        guard shouldDismiss(topLeftTabPoint: topLeftTabPoint) else { return false }
        onDismiss()
        return true
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Preference Key for Drawer Panel Frame in Tab Space

/// Reports the drawer panel frame in the `"tabContainer"` coordinate space.
/// FlatTabStripContainer uses this to mount drawer drag capture at tab level.
///
/// The reducer keeps the last non-zero value: a transient zero update during a
/// transition must not unmount the drawer capture.
struct DrawerPanelFrameInTabKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - DrawerPanelOverlay

/// Which geometry the tab-level drawer overlay presents with.
enum DrawerOverlayPresentation: Equatable {
    /// Anchored to the owning pane's measured frame above its toolbar.
    case normal
    /// Fixed overlay over the Zoom source's selected region. Regions are in
    /// `"tabContainer"` space and already exclude the shared bottom toolbar.
    case zoom(sourcePaneId: UUID, terminalRegion: CGRect, bridgeRegion: CGRect?)

    var isZoom: Bool {
        if case .zoom = self { return true }
        return false
    }
}

/// Tab-level overlay that renders the expanded drawer panel on top of all panes.
/// Positioned at the tab container level so it can extend beyond the originating
/// pane's bounds, with an S-curve connector visually bridging the panel to its anchor.
///
/// Every rectangle comes from `DrawerPresentationGeometryResolver`, the same
/// policy terminal bootstrap uses. Outside-click dismissal is owned by
/// `DrawerDismissMonitor` so dismissing clicks can be consumed before they
/// refocus underlying AppKit content.
struct DrawerPanelOverlay: View {
    static let outlineAccessibilityIdentifier = "drawerPanel.outline"
    static let moveControlAccessibilityIdentifier = "drawerPanel.moveZoomSide"

    struct MoveControlResolutionKey: Equatable {
        let command: AppCommand?
        let ownerPaneId: UUID
        let tabId: UUID
        let workspaceWindowId: UUID?
        let zoomSourcePaneId: UUID?
    }

    private struct ResolvedMoveControlAction {
        let key: MoveControlResolutionKey
        let action: TargetedCommandControlAction
    }

    private struct ExpandedPaneInfo {
        let paneId: UUID
        /// Measured owner frame; absent in Pane Zoom, which anchors to regions.
        let frame: CGRect?
        let drawer: Drawer
        let drawerView: DrawerView
    }

    let store: WorkspaceStore
    let octiconLoader: OcticonLoader
    let repoCache: RepoCacheAtom
    let editorChooser: EditorChooserState
    let viewRegistry: ViewRegistry
    let appLifecycleStore: AppLifecycleAtom
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let tabId: UUID
    let presentation: DrawerOverlayPresentation
    let paneFrames: [UUID: CGRect]
    let tabSize: CGSize
    let iconBarFrame: CGRect
    let actionDispatcher: PaneActionDispatching
    let arrangementInlineRenameState: ArrangementInlineRenameState
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let onFocusPane: (UUID) -> Void
    let paneInboxPresentation: PaneInboxPresentation?
    let onOpenPaneGitHub: (UUID) -> Void
    let drawerDropTarget: DrawerRearrangeTarget?
    let dismissCoordinateView: NSView?
    let workspaceWindowId: UUID?
    /// Active drag's source pane id, threaded through to DrawerPanel
    /// so its visuals dict applies the source-aware filter (R1, R2,
    /// R8/R13a).
    let dragSourcePaneId: UUID?

    @State private var dismissMonitor = DrawerDismissMonitor()
    /// Local normal-mode resize session; per-sample state never leaves the overlay.
    @State private var resizeSession: DrawerNormalResizeSession?
    @State private var isMoveControlHovered = false
    @State private var resolvedMoveControlAction: ResolvedMoveControlAction?

    /// Find the pane whose drawer is currently expanded.
    /// Invariant: only one drawer can be expanded at a time (toggle behavior).
    /// In Pane Zoom only the Zoom source's drawer presents.
    private var expandedPaneInfo: ExpandedPaneInfo? {
        switch presentation {
        case .normal:
            for (paneId, frame) in paneFrames {
                if let info = expandedInfo(paneId: paneId, frame: frame) {
                    return info
                }
            }
            return nil
        case .zoom(let sourcePaneId, _, _):
            return expandedInfo(paneId: sourcePaneId, frame: nil)
        }
    }

    private func expandedInfo(paneId: UUID, frame: CGRect?) -> ExpandedPaneInfo? {
        guard let drawer = store.paneAtom.pane(paneId)?.drawer,
            drawer.isExpanded,
            let drawerView = atom(\.arrangementView).drawerView(forParent: paneId)
        else { return nil }
        return ExpandedPaneInfo(paneId: paneId, frame: frame, drawer: drawer, drawerView: drawerView)
    }

    private func geometryInput(
        ownerPaneId: UUID,
        ownerFrame: CGRect?,
        liveHeight: CGFloat?
    ) -> DrawerPresentationGeometryInput? {
        let preference = store.paneAtom.drawerPresentationPreference(forOwner: ownerPaneId)
        let placement: DrawerPresentationPlacement
        switch presentation {
        case .normal:
            guard let ownerFrame else { return nil }
            placement = .normal(
                ownerFrame: ownerFrame,
                ownerToolbarHeight: iconBarFrame.height,
                liveHeight: liveHeight
            )
        case .zoom(_, let terminalRegion, let bridgeRegion):
            placement = .zoom(terminalRegion: terminalRegion, visibleBridgeRegion: bridgeRegion)
        }
        return DrawerPresentationGeometryInput(
            containerBounds: CGRect(origin: .zero, size: tabSize),
            preference: preference,
            placement: placement
        )
    }

    private func liveResizeHeight(forOwner ownerPaneId: UUID) -> CGFloat? {
        guard !presentation.isZoom,
            let resizeSession,
            !resizeSession.isCancelled,
            resizeSession.applies(toOwner: ownerPaneId, containerHeight: tabSize.height)
        else { return nil }
        return resizeSession.liveHeight
    }

    var body: some View {
        if let info = expandedPaneInfo,
            let input = geometryInput(
                ownerPaneId: info.paneId,
                ownerFrame: info.frame,
                liveHeight: liveResizeHeight(forOwner: info.paneId)
            ),
            let geometry = DrawerPresentationGeometryResolver.resolve(input)
        {
            let outlineFrame = geometry.outlineFrame
            let connectorInsets = geometry.connectorInsets
            let panelHeight = geometry.panelFrame.height

            // Unified outline: panel (rounded rect) + S-curve connector
            let outlineShape = DrawerOutlineShape(
                panelHeight: panelHeight,
                cornerRadius: DrawerLayout.panelCornerRadius,
                junctionLeftInset: connectorInsets.junctionLeft,
                junctionRightInset: connectorInsets.junctionRight,
                bottomLeftInset: connectorInsets.bottomLeft,
                bottomRightInset: connectorInsets.bottomRight,
                bottomCornerRadius: DrawerLayout.connectorBottomCornerRadius
            )
            let panelFraction = outlineFrame.height > 0 ? panelHeight / outlineFrame.height : 1

            let paneId = info.paneId
            let moveControlResolutionKey = Self.makeMoveControlResolutionKey(
                command: Self.moveControlCommand(
                    mode: geometry.mode,
                    isManagementLayerActive: atom(\.managementLayer).isActive
                ),
                ownerPaneId: paneId,
                tabId: tabId,
                workspaceWindowId: workspaceWindowId,
                zoomPresentation: store.panePresentationAtom.zoomPresentation(forTab: tabId)
            )
            VStack(spacing: 0) {
                DrawerPanel(
                    layout: info.drawerView.layout,
                    octiconLoader: octiconLoader,
                    parentPaneId: paneId,
                    tabId: tabId,
                    activeChildId: info.drawerView.activeChildId,
                    minimizedPaneIds: info.drawerView.minimizedPaneIds,
                    closeTransitionCoordinator: closeTransitionCoordinator,
                    height: panelHeight,
                    store: store,
                    repoCache: repoCache,
                    editorChooser: editorChooser,
                    viewRegistry: viewRegistry,
                    action: actionDispatcher.dispatch,
                    arrangementInlineRenameState: arrangementInlineRenameState,
                    resizeInteraction: geometry.resizeHandleFrame == nil
                        ? nil
                        : resizeInteraction(ownerPaneId: paneId, input: input, displayedHeight: panelHeight),
                    onDismiss: {
                        actionDispatcher.dispatch(.toggleDrawer(paneId: paneId))
                        onPaneFocusTrigger(.drawer(.toggle(parentPaneId: paneId)))
                    },
                    onPaneFocusTrigger: onPaneFocusTrigger,
                    onFocusParentPane: { onFocusPane(paneId) },
                    appLifecycleStore: appLifecycleStore,
                    paneInboxPresentation: paneInboxPresentation,
                    onOpenPaneGitHub: onOpenPaneGitHub,
                    dropTarget: drawerDropTarget,
                    dragSourcePaneId: dragSourcePaneId,
                    workspaceWindowId: workspaceWindowId
                )
                .id(paneId)
                .frame(width: outlineFrame.width)
                .overlay(alignment: .bottomTrailing) {
                    moveControl(resolutionKey: moveControlResolutionKey)
                        .padding(.trailing, Self.moveControlTrailingInset)
                        .padding(.bottom, Self.moveControlBottomInset)
                }

                // Connector space (visual bridge from panel to its anchor)
                Color.clear
                    .frame(width: outlineFrame.width, height: geometry.connectorFrame.height)
            }
            .modifier(DrawerMaterialModifier(shape: outlineShape, panelFraction: panelFraction))
            .contentShape(outlineShape)
            .shadow(color: .black.opacity(AppStyles.General.Stroke.muted), radius: 4, y: 2)
            .shadow(color: .black.opacity(AppStyles.General.Stroke.hover), radius: 16, y: 8)
            .background {
                AccessibilityLabelBridge(
                    identifier: Self.outlineAccessibilityIdentifier,
                    label: "Drawer",
                    exposesAccessibility: false
                )
                .allowsHitTesting(false)
            }
            .position(x: outlineFrame.midX, y: outlineFrame.midY)
            .task(id: moveControlResolutionKey) {
                resolveMoveControlAction(for: moveControlResolutionKey)
            }
            .onAppear {
                dismissMonitor.onDismiss = {
                    actionDispatcher.dispatch(.toggleDrawer(paneId: paneId))
                    onPaneFocusTrigger(.drawer(.toggle(parentPaneId: paneId)))
                }
                dismissMonitor.setCoordinateView(dismissCoordinateView)
                dismissMonitor.drawerRectInTab = geometry.dismissalFrame
                dismissMonitor.iconBarRectInTab = iconBarFrame
                dismissMonitor.install()
            }
            .onDisappear {
                dismissMonitor.remove()
                applyResizeEvent(.cancelled)
            }
            .task(id: paneId) {
                dismissMonitor.onDismiss = {
                    actionDispatcher.dispatch(.toggleDrawer(paneId: paneId))
                    onPaneFocusTrigger(.drawer(.toggle(parentPaneId: paneId)))
                }
            }
            .task(id: dismissCoordinateView.map(ObjectIdentifier.init)) {
                dismissMonitor.setCoordinateView(dismissCoordinateView)
            }
            .onChange(of: geometry.dismissalFrame) { _, frame in
                dismissMonitor.drawerRectInTab = frame
            }
            .onChange(of: iconBarFrame) { _, frame in
                dismissMonitor.iconBarRectInTab = frame
            }
            // Resize-session cancellation: owner replaced, mode change,
            // coordinate invalidation, or window deactivation discard the
            // live height so no late sample or end commits elsewhere.
            .onChange(of: paneId) { _, _ in applyResizeEvent(.cancelled) }
            .onChange(of: presentation.isZoom) { _, _ in applyResizeEvent(.cancelled) }
            .onChange(of: tabSize) { _, _ in applyResizeEvent(.cancelled) }
            .onChange(of: appLifecycleStore.isActive) { _, isActive in
                if !isActive { applyResizeEvent(.cancelled) }
            }
            .onChange(of: input.preference.normalHeightRatio) { _, _ in
                applyResizeEvent(.committedPreferenceChanged)
            }
        }
    }

    /// Applies one session event; dispatches the single completed-drag commit.
    private func applyResizeEvent(
        _ event: DrawerResizeSessionEvent,
        context: DrawerResizeSessionContext? = nil
    ) {
        let reduction = DrawerNormalResizeSession.reduce(resizeSession, event, context: context)
        resizeSession = reduction.session
        if let ratio = reduction.commitHeightRatio, let ownerPaneId = context?.ownerPaneId {
            actionDispatcher.dispatch(.setDrawerNormalHeightRatio(parentPaneId: ownerPaneId, ratio: ratio))
        }
    }

    private func resizeInteraction(
        ownerPaneId: UUID,
        input: DrawerPresentationGeometryInput,
        displayedHeight: CGFloat
    ) -> DrawerResizeInteraction {
        let context = DrawerResizeSessionContext(
            ownerPaneId: ownerPaneId,
            containerHeight: tabSize.height,
            displayedHeight: displayedHeight,
            committedHeightRatio: input.preference.normalHeightRatio,
            displayedHeightForRequest: { requestedHeight in
                Self.displayedNormalHeight(for: input, requestedHeight: requestedHeight) ?? displayedHeight
            }
        )
        return DrawerResizeInteraction(
            onChanged: { gestureID, pointerY in
                applyResizeEvent(.changed(gestureID: gestureID, pointerY: pointerY), context: context)
            },
            onEnded: { gestureID in
                applyResizeEvent(.ended(gestureID: gestureID), context: context)
            },
            onTerminated: { gestureID in
                applyResizeEvent(.terminated(gestureID: gestureID))
            }
        )
    }

    /// The on-drawer move control exists only in Pane Zoom while the
    /// management layer is active; it offers the other region's side command,
    /// so its icon points where the drawer will go.
    static func moveControlCommand(
        mode: DrawerPresentationGeometry.Mode,
        isManagementLayerActive: Bool
    ) -> AppCommand? {
        guard isManagementLayerActive, case .zoom(let effectiveSide) = mode else { return nil }
        return AppCommand.moveZoomDrawerCommand(awayFrom: effectiveSide)
    }

    static func makeMoveControlResolutionKey(
        command: AppCommand?,
        ownerPaneId: UUID,
        tabId: UUID,
        workspaceWindowId: UUID?,
        zoomPresentation: ZoomPresentation?
    ) -> MoveControlResolutionKey {
        MoveControlResolutionKey(
            command: command,
            ownerPaneId: ownerPaneId,
            tabId: tabId,
            workspaceWindowId: workspaceWindowId,
            zoomSourcePaneId: zoomPresentation?.sourcePaneId
        )
    }

    /// The move tab stacks directly above the bottom-trailing child's detach
    /// tab, on both sides: the panel's content inset plus the child pane gap
    /// puts it in the detach column, and one tab height plus standard spacing
    /// above the detach tab's own bottom spacing.
    static let moveControlTrailingInset = DrawerLayout.panelContentPadding + AppStyles.General.Layout.paneGap
    static let moveControlBottomInset =
        DrawerLayout.panelContentPadding + AppStyles.General.Layout.paneGap
        + AppStyles.General.Spacing.standard + AppStyles.Shell.PaneChrome.paneEdgeButtonHeight
        + AppStyles.General.Spacing.standard

    /// Same edge tab as the child's detach control. Icon, label, and tooltip
    /// project from the side command's catalog spec.
    @MainActor
    private func resolveMoveControlAction(for key: MoveControlResolutionKey) {
        guard let command = key.command,
            let action = TargetedCommandControlAction.resolve(
                command: command,
                surface: .inlineControl,
                target: key.ownerPaneId,
                targetType: .pane,
                dispatcher: AppCommandDispatcher.shared
            )
        else {
            resolvedMoveControlAction = nil
            return
        }
        resolvedMoveControlAction = ResolvedMoveControlAction(key: key, action: action)
    }

    @ViewBuilder
    private func moveControl(resolutionKey: MoveControlResolutionKey) -> some View {
        if let resolvedMoveControlAction,
            resolvedMoveControlAction.key == resolutionKey,
            case .system(let symbol) = resolvedMoveControlAction.action.commandSpec.icon
        {
            ManagementTrailingEdgeTabButton(
                systemName: symbol.rawValue,
                isHovered: isMoveControlHovered,
                isEnabled: resolvedMoveControlAction.action.isEnabled,
                tooltip: resolvedMoveControlAction.action.commandSpec.controlTooltipRenderValue(),
                accessibilityIdentifier: Self.moveControlAccessibilityIdentifier,
                onAnchorViewChanged: nil,
                action: resolvedMoveControlAction.action.perform
            )
            .onHover { isMoveControlHovered = $0 }
        }
    }

    /// Height the resolver would display for a requested live height.
    static func displayedNormalHeight(
        for input: DrawerPresentationGeometryInput,
        requestedHeight: CGFloat
    ) -> CGFloat? {
        guard case .normal(let ownerFrame, let ownerToolbarHeight, _) = input.placement else { return nil }
        let liveInput = DrawerPresentationGeometryInput(
            containerBounds: input.containerBounds,
            preference: input.preference,
            placement: .normal(
                ownerFrame: ownerFrame,
                ownerToolbarHeight: ownerToolbarHeight,
                liveHeight: requestedHeight
            )
        )
        return DrawerPresentationGeometryResolver.resolve(liveInput)?.panelFrame.height
    }
}

// MARK: - Drawer Dismiss Coordinate Space Bridge

/// Publishes the AppKit view whose local coordinates match the SwiftUI
/// `"tabContainer"` coordinate space used by drawer dismiss hit testing.
struct DrawerDismissCoordinateSpaceBridge: NSViewRepresentable {
    let onViewChanged: (NSView?) -> Void

    func makeNSView(context _: Context) -> DrawerDismissCoordinateSpaceView {
        let view = DrawerDismissCoordinateSpaceView()
        view.onViewChanged = onViewChanged
        return view
    }

    func updateNSView(_ nsView: DrawerDismissCoordinateSpaceView, context _: Context) {
        nsView.onViewChanged = onViewChanged
    }

    static func dismantleNSView(_ nsView: DrawerDismissCoordinateSpaceView, coordinator _: ()) {
        nsView.onViewChanged(nil)
    }
}

final class DrawerDismissCoordinateSpaceView: NSView {
    var onViewChanged: (NSView?) -> Void = { _ in }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onViewChanged(window == nil ? nil : self)
    }
}

// MARK: - DrawerOutlineShape

/// Unified outline tracing the panel (rounded rectangle with all 4 corners) and
/// S-curve connector as a single continuous path. The connector narrows from panel
/// width to the bottom bar width via smooth cubic bezier S-curves, then continues
/// with straight vertical sides to a rounded bottom edge.
struct DrawerOutlineShape: Shape {
    let panelHeight: CGFloat
    let cornerRadius: CGFloat
    let junctionLeftInset: CGFloat
    let junctionRightInset: CGFloat
    let bottomLeftInset: CGFloat
    let bottomRightInset: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = min(cornerRadius, panelHeight / 2)
        let br = bottomCornerRadius

        // Junction x-coordinates (where S-curves meet panel bottom edge)
        // Clamped to corner radius so S-curves start after panel corner arcs
        let jLeft = max(r, junctionLeftInset)
        let jRight = w - max(r, junctionRightInset)

        // Bottom bar x-coordinates
        let bLeft = bottomLeftInset
        let bRight = w - bottomRightInset

        // S-curves end just above the bottom corner arcs
        let sCurveBottomY = h - br

        var path = Path()

        // --- Panel: rounded rectangle (all 4 corners identical) ---

        path.move(to: CGPoint(x: 0, y: r))

        // Top-left corner
        path.addArc(
            center: CGPoint(x: r, y: r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: w - r, y: 0))

        // Top-right corner
        path.addArc(
            center: CGPoint(x: w - r, y: r),
            radius: r,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: w, y: panelHeight - r))

        // Bottom-right panel corner
        path.addArc(
            center: CGPoint(x: w - r, y: panelHeight - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // --- Right S-curve: panel bottom → bottom bar ---

        path.addLine(to: CGPoint(x: jRight, y: panelHeight))
        // S-curve spans full connector height: horizontal start, vertical end
        path.addCurve(
            to: CGPoint(x: bRight, y: sCurveBottomY),
            control1: CGPoint(x: (jRight + bRight) / 2, y: panelHeight),
            control2: CGPoint(x: bRight, y: (panelHeight + sCurveBottomY) / 2)
        )

        // --- Bottom bar (rounded corners) ---

        path.addArc(
            center: CGPoint(x: bRight - br, y: h - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bLeft + br, y: h))
        path.addArc(
            center: CGPoint(x: bLeft + br, y: h - br),
            radius: br,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // --- Left S-curve: bottom bar → panel bottom ---

        // S-curve spans full connector height: vertical start, horizontal end
        path.addCurve(
            to: CGPoint(x: jLeft, y: panelHeight),
            control1: CGPoint(x: bLeft, y: (panelHeight + sCurveBottomY) / 2),
            control2: CGPoint(x: (jLeft + bLeft) / 2, y: panelHeight)
        )

        // Panel bottom edge to bottom-left panel corner
        path.addLine(to: CGPoint(x: r, y: panelHeight))

        // Bottom-left panel corner
        path.addArc(
            center: CGPoint(x: r, y: panelHeight - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - DrawerMaterialModifier

/// Applies liquid glass on macOS 26+, falls back to ultraThinMaterial on older versions.
/// Includes a gradient mask that keeps full material on the panel and fades the connector.
struct DrawerMaterialModifier: ViewModifier {
    let shape: DrawerOutlineShape
    let panelFraction: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(connectorFadeOverlay)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
        }
    }

    /// Gradient overlay that transitions the connector from glass toward the toolbar color.
    /// Clear over the panel, gradually fading to the window background tint through the connector
    /// so the bottom visually matches the icon bar toolbar.
    private var connectorFadeOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: panelFraction),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.95), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}
