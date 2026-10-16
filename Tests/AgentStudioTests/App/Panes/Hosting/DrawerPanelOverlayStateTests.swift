import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct DrawerPanelOverlayStateTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    // MARK: - Rendered drawer pane projection

    @Test
    func drawerPanelRenderedPaneIds_hidesMinimizedPanesOutsideManagement() {
        let visiblePaneId = UUID()
        let minimizedPaneId = UUID()
        let layout = DrawerGridLayout(
            topRow: Layout(paneId: visiblePaneId)
                .inserting(
                    paneId: minimizedPaneId,
                    at: visiblePaneId,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )!
        )

        let renderedPaneIds = DrawerPanel.renderedPaneIds(
            layout: layout,
            minimizedPaneIds: [minimizedPaneId],
            isManagementLayerActive: false
        )

        #expect(renderedPaneIds == [visiblePaneId])
    }

    @Test
    func drawerPanelRenderedPaneIds_managementLayerRestoresMinimizedPanes() {
        let visiblePaneId = UUID()
        let minimizedPaneId = UUID()
        let layout = DrawerGridLayout(
            topRow: Layout(paneId: visiblePaneId)
                .inserting(
                    paneId: minimizedPaneId,
                    at: visiblePaneId,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )!
        )

        let renderedPaneIds = DrawerPanel.renderedPaneIds(
            layout: layout,
            minimizedPaneIds: [minimizedPaneId],
            isManagementLayerActive: true
        )

        #expect(renderedPaneIds == [visiblePaneId, minimizedPaneId])
    }

    // MARK: - Frame preference reducer stability

    @Test
    func drawerPanelFrameInTabKey_keepsRealFrameWhenZeroIsPublished() {
        var tabFrame = CGRect(x: 30, y: 40, width: 220, height: 120)
        DrawerPanelFrameInTabKey.reduce(value: &tabFrame) { .zero }

        #expect(tabFrame == CGRect(x: 30, y: 40, width: 220, height: 120))
    }

    @Test
    func drawerIconBarFrameKey_keepsRealFrameWhenZeroIsPublished() {
        var iconBarFrame = CGRect(x: 5, y: 6, width: 80, height: 30)
        DrawerIconBarFrameKey.reduce(value: &iconBarFrame) { .zero }

        #expect(iconBarFrame == CGRect(x: 5, y: 6, width: 80, height: 30))
    }

    // MARK: - Resize input presence

    @Test("Normal drawer panel exposes its top resize target; Zoom panel has none", arguments: [true, false])
    func drawerPanelResizeTargetFollowsInteraction(hasResizeInteraction: Bool) throws {
        let store = WorkspaceStore(startsObserving: false)
        let parent = store.createPane()
        let tab = Tab(paneId: parent.id)
        store.appendTab(tab)
        let panel = DrawerPanel(
            layout: DrawerGridLayout(),
            octiconLoader: makeTestOcticonLoader(),
            parentPaneId: parent.id, tabId: tab.id, activeChildId: nil,
            minimizedPaneIds: [], closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
            height: 300, store: store, repoCache: RepoCacheAtom(),
            editorChooser: makeTestAtomRegistry().editorChooser,
            viewRegistry: ViewRegistry(), action: { _ in },
            commandDispatcher: AppTerminalFixtureCommandDispatcher(),
            arrangementInlineRenameState: ArrangementInlineRenameState(),
            resizeInteraction: hasResizeInteraction
                ? DrawerResizeInteraction(onChanged: { _, _ in }, onEnded: { _ in }, onTerminated: { _ in })
                : nil,
            onDismiss: {}, onPaneFocusTrigger: { _ in },
            onFocusParentPane: {}, appLifecycleStore: AppLifecycleAtom(),
            paneInboxPresentation: nil, onOpenPaneGitHub: { _ in },
            dropTarget: nil, dragSourcePaneId: nil)
        let hostingView = NSHostingView(rootView: panel.frame(width: 500, height: 300))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()

        #expect(
            containsView(in: hostingView, identifier: DrawerResizeHandle.accessibilityIdentifier)
                == hasResizeInteraction
        )
    }

    private func containsView(in root: NSView, identifier: String) -> Bool {
        if root.identifier?.rawValue == identifier { return true }
        return root.subviews.contains { containsView(in: $0, identifier: identifier) }
    }

    // MARK: - Dismiss monitor outside-click contract

    @Test
    func drawerDismissMonitor_outsideClickDismisses_evenWhenIconBarFrameIsZero() {
        let monitor = DrawerDismissMonitor()
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = .zero

        #expect(monitor.shouldDismiss(topLeftTabPoint: CGPoint(x: 40, y: 40)))
        #expect(!monitor.shouldDismiss(topLeftTabPoint: CGPoint(x: 200, y: 200)))
    }

    @Test
    func drawerDismissMonitor_excludesDrawerAndIconBarRegions() {
        let monitor = DrawerDismissMonitor()
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = CGRect(x: 240, y: 330, width: 160, height: 28)

        #expect(!monitor.shouldDismiss(topLeftTabPoint: CGPoint(x: 120, y: 120)))
        #expect(!monitor.shouldDismiss(topLeftTabPoint: CGPoint(x: 260, y: 340)))
        #expect(monitor.shouldDismiss(topLeftTabPoint: CGPoint(x: 40, y: 40)))
    }

    @Test
    func drawerDismissMonitor_dismissesOnlyForPointsOutsideDrawerAndIconBar() {
        let monitor = DrawerDismissMonitor()
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = CGRect(x: 240, y: 330, width: 160, height: 28)

        let cases: [(description: String, point: CGPoint, shouldDismiss: Bool)] = [
            ("inside drawer top-left area", CGPoint(x: 120, y: 120), false),
            ("inside drawer bottom-right area", CGPoint(x: 599, y: 319), false),
            ("inside icon bar left side", CGPoint(x: 260, y: 340), false),
            ("inside icon bar right side", CGPoint(x: 399, y: 357), false),
            ("outside left of drawer", CGPoint(x: 99, y: 120), true),
            ("outside right of drawer", CGPoint(x: 601, y: 120), true),
            ("outside above drawer", CGPoint(x: 120, y: 99), true),
            ("outside below drawer and away from icon bar", CGPoint(x: 120, y: 321), true),
            ("outside below icon bar", CGPoint(x: 260, y: 359), true),
        ]

        for dismissCase in cases {
            #expect(
                monitor.shouldDismiss(topLeftTabPoint: dismissCase.point) == dismissCase.shouldDismiss,
                "\(dismissCase.description) shouldDismiss=\(dismissCase.shouldDismiss)"
            )
        }
    }

    @Test
    func drawerDismissMonitor_outsideClickStillDismisses_afterStaleFrameZeroReset() {
        // Models the failure mode the empty-rect early-exit caused: if the
        // dismiss monitor's drawer rect is reset to .zero (which used to
        // happen because the preference reducer accepted zero updates),
        // the monitor must still dismiss on outside clicks. Empty rect
        // contains nothing — so any click is outside.
        let monitor = DrawerDismissMonitor()
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = .zero

        #expect(monitor.shouldDismiss(topLeftTabPoint: CGPoint(x: 40, y: 40)))

        monitor.drawerRectInTab = .zero

        #expect(monitor.shouldDismiss(topLeftTabPoint: CGPoint(x: 40, y: 40)))
        #expect(monitor.shouldDismiss(topLeftTabPoint: CGPoint(x: 200, y: 200)))
    }

    @Test
    func drawerDismissMonitor_invokesDismissOnceForOutsidePoint() {
        let monitor = DrawerDismissMonitor()
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = CGRect(x: 240, y: 330, width: 160, height: 28)
        var dismissCount = 0
        monitor.onDismiss = { dismissCount += 1 }

        #expect(!monitor.handleMouseDown(topLeftTabPoint: CGPoint(x: 120, y: 120)))
        #expect(!monitor.handleMouseDown(topLeftTabPoint: CGPoint(x: 260, y: 340)))
        #expect(monitor.handleMouseDown(topLeftTabPoint: CGPoint(x: 40, y: 40)))
        #expect(dismissCount == 1)
    }

    @Test
    func drawerDismissMonitor_convertsAppKitEventPointToTopLeftTabSpace() {
        let topLeftPoint = DrawerDismissMonitor.topLeftPoint(
            fromAppKitPoint: CGPoint(x: 200, y: 400),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600),
            isFlipped: false
        )

        #expect(topLeftPoint == CGPoint(x: 200, y: 200))
    }

    @Test
    func drawerDismissMonitor_keepsFlippedAppKitPointInTopLeftTabSpace() {
        let topLeftPoint = DrawerDismissMonitor.topLeftPoint(
            fromAppKitPoint: CGPoint(x: 200, y: 200),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600),
            isFlipped: true
        )

        #expect(topLeftPoint == CGPoint(x: 200, y: 200))
    }

    @Test
    func drawerDismissMonitor_insideDrawerClickInTranslatedWindowDoesNotDismiss() {
        let monitor = DrawerDismissMonitor()
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = .zero

        var dismissCount = 0
        monitor.onDismiss = { dismissCount += 1 }

        let insideDrawerPointInSwiftUIGlobal = CGPoint(x: 200, y: 200)
        let oldScreenFlippedPoint = previousScreenFlippedPoint(
            topLeftPointInTab: insideDrawerPointInSwiftUIGlobal,
            tabFrameInScreenCoordinates: CGRect(x: 700, y: 100, width: 900, height: 600),
            screenMaxY: 1200
        )
        let topLeftTabPoint = DrawerDismissMonitor.topLeftPoint(
            fromAppKitPoint: CGPoint(x: 200, y: 400),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600),
            isFlipped: false
        )

        #expect(monitor.shouldDismiss(topLeftTabPoint: oldScreenFlippedPoint))
        #expect(!monitor.handleMouseDown(topLeftTabPoint: topLeftTabPoint))
        #expect(dismissCount == 0)
    }

    @Test
    func drawerDismissMonitor_iconBarClickConvertedFromAppKitDoesNotDismiss() {
        let monitor = DrawerDismissMonitor()
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = CGRect(x: 240, y: 330, width: 160, height: 28)

        let topLeftTabPoint = DrawerDismissMonitor.topLeftPoint(
            fromAppKitPoint: CGPoint(x: 260, y: 260),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600),
            isFlipped: false
        )

        #expect(topLeftTabPoint == CGPoint(x: 260, y: 340))
        #expect(!monitor.handleMouseDown(topLeftTabPoint: topLeftTabPoint))
    }

    @Test
    func drawerDismissMonitor_outsideClickConvertedFromAppKitDismissesOnce() {
        let monitor = DrawerDismissMonitor()
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = CGRect(x: 240, y: 330, width: 160, height: 28)
        var dismissCount = 0
        monitor.onDismiss = { dismissCount += 1 }

        let topLeftTabPoint = DrawerDismissMonitor.topLeftPoint(
            fromAppKitPoint: CGPoint(x: 40, y: 560),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600),
            isFlipped: false
        )

        #expect(topLeftTabPoint == CGPoint(x: 40, y: 40))
        #expect(monitor.handleMouseDown(topLeftTabPoint: topLeftTabPoint))
        #expect(dismissCount == 1)
    }

    @Test
    func drawerDismissMonitor_usesCoordinateBridgeForSameWindowEventsAndIgnoresOtherWindows() throws {
        let tabBounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(
            contentRect: tabBounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let otherWindow = NSWindow(
            contentRect: tabBounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        defer {
            window.close()
            otherWindow.close()
        }

        let coordinateView = DrawerDismissCoordinateSpaceView(frame: tabBounds)
        try #require(window.contentView).addSubview(coordinateView)

        let monitor = DrawerDismissMonitor()
        monitor.setCoordinateView(coordinateView)
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = CGRect(x: 240, y: 330, width: 160, height: 28)
        var dismissCount = 0
        monitor.onDismiss = { dismissCount += 1 }

        let insideEvent = try #require(
            leftMouseDownEvent(
                window: window,
                topLeftTabPoint: CGPoint(x: 200, y: 200),
                tabHeight: tabBounds.height
            )
        )
        let insidePoint = try #require(monitor.topLeftTabPoint(for: insideEvent))

        #expect(insidePoint == CGPoint(x: 200, y: 200))
        #expect(!monitor.handleMouseDown(topLeftTabPoint: insidePoint))
        #expect(dismissCount == 0)

        let outsideEvent = try #require(
            leftMouseDownEvent(
                window: window,
                topLeftTabPoint: CGPoint(x: 40, y: 40),
                tabHeight: tabBounds.height
            )
        )
        let outsidePoint = try #require(monitor.topLeftTabPoint(for: outsideEvent))

        #expect(outsidePoint == CGPoint(x: 40, y: 40))
        #expect(monitor.handleMouseDown(topLeftTabPoint: outsidePoint))
        #expect(dismissCount == 1)

        let otherWindowEvent = try #require(
            leftMouseDownEvent(
                window: otherWindow,
                topLeftTabPoint: CGPoint(x: 40, y: 40),
                tabHeight: tabBounds.height
            )
        )

        #expect(monitor.topLeftTabPoint(for: otherWindowEvent) == nil)
    }

    @Test
    func drawerDismissCoordinateSpaceViewPublishesAndClearsMountedView() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let coordinateView = DrawerDismissCoordinateSpaceView(frame: window.contentView?.bounds ?? .zero)
        var publishedView: NSView?
        coordinateView.onViewChanged = { publishedView = $0 }

        try #require(window.contentView).addSubview(coordinateView)

        #expect(publishedView === coordinateView)

        coordinateView.removeFromSuperview()

        #expect(publishedView == nil)
    }

    @Test
    func drawerDismissCoordinateSpaceBridgeMountedThroughSwiftUIConvertsTranslatedEvents() async throws {
        let tabOrigin = CGPoint(x: 72, y: 48)
        let tabSize = CGSize(width: 900, height: 600)
        let hostSize = CGSize(width: 1040, height: 720)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: hostSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let publishedViewBox = PublishedBridgeViewBox()
        let hostingView = NSHostingView(
            rootView: DrawerDismissBridgeLayoutProbe(
                tabOrigin: tabOrigin,
                tabSize: tabSize,
                onViewChanged: { publishedViewBox.view = $0 }
            )
        )
        hostingView.frame = CGRect(origin: .zero, size: hostSize)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        await assertEventuallyMain("drawer dismiss bridge should publish mounted NSView") {
            publishedViewBox.view != nil
        }

        let bridgeView = try #require(publishedViewBox.view)
        hostingView.layoutSubtreeIfNeeded()

        #expect(bridgeView.window === window)
        #expect(bridgeView.bounds.size == tabSize)
        #expect(bridgeView.convert(bridgeView.bounds, to: nil).origin != .zero)

        let monitor = DrawerDismissMonitor()
        monitor.setCoordinateView(bridgeView)
        monitor.drawerRectInTab = CGRect(x: 100, y: 100, width: 500, height: 220)
        monitor.iconBarRectInTab = CGRect(x: 240, y: 330, width: 160, height: 28)
        var dismissCount = 0
        monitor.onDismiss = { dismissCount += 1 }

        let insideEvent = try #require(
            leftMouseDownEvent(
                window: window,
                locationInWindow: bridgeView.convert(CGPoint(x: 200, y: 200), to: nil)
            )
        )
        let insidePoint = try #require(monitor.topLeftTabPoint(for: insideEvent))

        #expect(insidePoint == CGPoint(x: 200, y: 200))
        #expect(!monitor.handleMouseDown(topLeftTabPoint: insidePoint))
        #expect(dismissCount == 0)

        let outsideEvent = try #require(
            leftMouseDownEvent(
                window: window,
                locationInWindow: bridgeView.convert(CGPoint(x: 40, y: 40), to: nil)
            )
        )
        let outsidePoint = try #require(monitor.topLeftTabPoint(for: outsideEvent))

        #expect(outsidePoint == CGPoint(x: 40, y: 40))
        #expect(monitor.handleMouseDown(topLeftTabPoint: outsidePoint))
        #expect(dismissCount == 1)
    }

    private func leftMouseDownEvent(
        window: NSWindow,
        topLeftTabPoint: CGPoint,
        tabHeight: CGFloat
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: topLeftTabPoint.x, y: tabHeight - topLeftTabPoint.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }

    private func leftMouseDownEvent(
        window: NSWindow,
        locationInWindow: CGPoint
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }

    private func previousScreenFlippedPoint(
        topLeftPointInTab point: CGPoint,
        tabFrameInScreenCoordinates tabFrame: CGRect,
        screenMaxY: CGFloat
    ) -> CGPoint {
        let appKitLocationInWindow = CGPoint(
            x: point.x,
            y: tabFrame.height - point.y
        )
        let screenPoint = CGPoint(
            x: tabFrame.minX + appKitLocationInWindow.x,
            y: tabFrame.minY + appKitLocationInWindow.y
        )
        return CGPoint(
            x: screenPoint.x,
            y: screenMaxY - screenPoint.y
        )
    }
}

private final class PublishedBridgeViewBox {
    var view: NSView?
}

private struct DrawerDismissBridgeLayoutProbe: View {
    let tabOrigin: CGPoint
    let tabSize: CGSize
    let onViewChanged: (NSView?) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: tabSize.width, height: tabSize.height)
                .background(
                    DrawerDismissCoordinateSpaceBridge(onViewChanged: onViewChanged)
                        .allowsHitTesting(false)
                )
                .offset(x: tabOrigin.x, y: tabOrigin.y)
        }
        .frame(
            width: tabOrigin.x + tabSize.width + 68,
            height: tabOrigin.y + tabSize.height + 72,
            alignment: .topLeading
        )
    }
}
