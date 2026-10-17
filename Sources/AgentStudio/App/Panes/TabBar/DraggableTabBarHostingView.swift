import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Draggable Tab Bar Container

/// Container view that wraps NSHostingView and handles drag-to-reorder for tabs.
/// Uses NSPanGestureRecognizer for tab drags, AppKit for secondary-click menus and
/// empty-strip window dragging, and SwiftUI for visual and primary-click interactions.
class DraggableTabBarHostingView: NSView, NSDraggingSource {
    private static let paneDragHoverDwellDuration: TimeInterval = 0.1
    private static let doubleClickActionDefaultsKey = "AppleActionOnDoubleClick"

    // MARK: - Properties

    private var hostingView: NSHostingView<AnyView>!
    weak var tabBarAdapter: TabBarAdapter?
    var onReorder: ((_ fromId: UUID, _ insertionIndex: Int, _ correlationId: UUID) -> Void)?
    /// Injection seams for window-drag handling on clicks that land outside any
    /// tab pill. Default to the real AppKit calls; tests substitute closures.
    var performWindowDrag: ((NSEvent) -> Void)?
    var performWindowZoom: (() -> Void)?
    var performWindowMiniaturize: (() -> Void)?
    var currentEventProvider: () -> NSEvent? = { NSApp.currentEvent }
    var contextMenuRequestHandler: ((_ tabId: UUID, _ event: NSEvent) -> Bool)?
    /// Called when a tab is clicked (mouse down + up without drag) during management layer.
    /// The pan gesture recognizer consumes mouse events, preventing SwiftUI's
    /// onTapGesture from firing. This callback forwards the click as a selection.
    var onSelect: ((_ tabId: UUID) -> Void)?
    /// Provides drag payload data (worktreeId, repoId, title) for a tab ID.
    /// Injected by the view controller to decouple from WorkspaceStore.
    var dragPayloadProvider: ((_ tabId: UUID) -> TabDragPayload?)?
    var expandedDrawerParentIdForTab: ((_ tabId: UUID) -> UUID?)?
    var onAutoDismissDrawerForDrag: ((_ tabId: UUID, _ drawerParentPaneId: UUID) -> Void)?

    /// Tab frames reported from SwiftUI, in SwiftUI coordinate space
    private var tabFrames: [UUID: CGRect] = [:]

    /// Currently dragging tab ID (for drag source tracking)
    private var draggingTabId: UUID?

    /// Pan gesture recognizer for drag detection
    private var panGesture: NSPanGestureRecognizer!

    /// Track the tab being dragged and the original event for drag session
    private var panStartTabId: UUID?
    private var panStartEvent: NSEvent?
    private var dwellState = DragDwellState.idle
    private var paneDropTraceIsActive = false

    private var managementLayerObservation: Task<Void, Never>?
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private let commandDispatcher: any AppCommandDispatching
    private var rightMouseDownMonitor: Any?

    isolated deinit {
        managementLayerObservation?.cancel()
        if let rightMouseDownMonitor {
            NSEvent.removeMonitor(rightMouseDownMonitor)
        }
    }

    // MARK: - Initialization

    init(
        rootView: CustomTabBar,
        commandDispatcher: any AppCommandDispatching,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    ) {
        self.commandDispatcher = commandDispatcher
        self.performanceTraceRecorder = performanceTraceRecorder
        super.init(frame: .zero)

        hostingView = NSHostingView(
            rootView: AnyView(rootView.tint(AppStyles.General.Accent.primaryColor)))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Register as drag destination for internal reorder, tab drop, and pane drop
        registerForDraggedTypes([.agentStudioTabInternal, .agentStudioTabDrop, .agentStudioPaneDrop])

        // Set up pan gesture recognizer for drag detection.
        // Disabled by default — only enabled when management layer (Cmd+Opt) is active.
        // This prevents the recognizer from interfering with SwiftUI's onTapGesture
        // on tab pills, which was causing intermittent missed clicks.
        panGesture = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delaysPrimaryMouseButtonEvents = false
        panGesture.isEnabled = atom(\.managementLayer).isActive
        addGestureRecognizer(panGesture)
        observeManagementLayer()
        installRightMouseDownMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeManagementLayer() {
        managementLayerObservation?.cancel()
        managementLayerObservation = Task { @MainActor [weak self] in
            withObservationTracking {
                _ = atom(\.managementLayer).isActive
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.updateManagementLayerState()
                    self?.observeManagementLayer()
                }
            }
        }
        updateManagementLayerState()
    }

    private func updateManagementLayerState() {
        panGesture.isEnabled = atom(\.managementLayer).isActive
        if !atom(\.managementLayer).isActive {
            // Clean up any in-flight drag state when leaving management layer
            panStartTabId = nil
            panStartEvent = nil
            if draggingTabId != nil {
                draggingTabId = nil
                tabBarAdapter?.draggingTabId = nil
                tabBarAdapter?.dropTargetIndex = nil
            }
            resetPaneDragDwell()
        }
    }

    private func installRightMouseDownMonitor() {
        rightMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            self?.processRightMouseDown(event) ?? event
        }
    }

    func processRightMouseDown(_ event: NSEvent) -> NSEvent? {
        recordRightMouseDownAdmission(event)
        guard let window, event.windowNumber == window.windowNumber else { return event }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location), let tabId = tabAtPoint(location) else { return event }
        guard contextMenuRequestHandler?(tabId, event) == true else { return event }
        return nil
    }

    private func recordRightMouseDownAdmission(_ event: NSEvent) {
        guard let window, event.windowNumber == window.windowNumber else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }

        performanceTraceRecorder?.record(
            .tabBarContextMenu,
            attributes: [
                "agentstudio.performance.tabbar.context_menu.phase": .string("input"),
                "agentstudio.performance.tabbar.context_menu.tab_hit": .bool(
                    tabAtPoint(location) != nil
                ),
            ]
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        guard currentEventProvider()?.type == .rightMouseDown else { return hitView }
        performanceTraceRecorder?.record(
            .tabBarContextMenu,
            attributes: [
                "agentstudio.performance.tabbar.context_menu.phase": .string("host_hit_test"),
                "agentstudio.performance.tabbar.context_menu.host_hit": .bool(hitView != nil),
                "agentstudio.performance.tabbar.context_menu.hit_view_class": .string(
                    contextMenuHitViewLabel(hitView)
                ),
                "agentstudio.performance.tabbar.context_menu.static_menu_available": .bool(
                    hitView?.menu != nil
                ),
            ]
        )
        return hitView
    }

    private func contextMenuHitViewLabel(_ hitView: NSView?) -> String {
        guard let hitView else { return "none" }
        return hitView === hostingView || hitView.isDescendant(of: hostingView) ? "swiftui" : "appkit"
    }

    // MARK: - Setup

    func configure(adapter: TabBarAdapter, onReorder: @escaping (UUID, Int, UUID) -> Void) {
        self.tabBarAdapter = adapter
        self.onReorder = onReorder
    }

    func updateTabFrames(_ frames: [UUID: CGRect]) {
        tabFrames.merge(frames) { _, new in new }
        guard let currentTabIds = tabBarAdapter?.tabs.map(\.id), !currentTabIds.isEmpty else { return }
        let currentTabIdSet = Set(currentTabIds)
        tabFrames = tabFrames.filter { currentTabIdSet.contains($0.key) }
    }

    func tabFrameInView(for tabId: UUID) -> NSRect? {
        DraggableTabBarGeometry.nsViewRect(
            for: tabId,
            boundsHeight: bounds.height,
            tabFrames: currentTabFrames
        )
    }

    /// Get current tab frames, preferring local cache but falling back to TabBarAdapter
    private var currentTabFrames: [UUID: CGRect] {
        let availableFrames = tabFrames.isEmpty ? tabBarAdapter?.tabFrames ?? [:] : tabFrames
        guard let currentTabIds = tabBarAdapter?.tabs.map(\.id), !currentTabIds.isEmpty else {
            return availableFrames
        }
        let currentTabIdSet = Set(currentTabIds)
        return availableFrames.filter { currentTabIdSet.contains($0.key) }
    }

    // MARK: - Hit Testing

    /// Find which tab is at the given point (in NSView coordinates)
    private func tabAtPoint(_ point: NSPoint) -> UUID? {
        // Convert to SwiftUI coordinate space (flipped Y)
        let swiftUIPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        return DraggableTabBarGeometry.tabId(at: swiftUIPoint, tabFrames: currentTabFrames)
    }

    /// Find the insertion index for a drop at the given point
    private func dropIndexAtPoint(_ point: NSPoint) -> Int? {
        guard let adapter = tabBarAdapter, !adapter.tabs.isEmpty else { return nil }
        let orderedTabIds = adapter.tabs.map(\.id)
        return Self.paneDropInsertionIndex(
            dropPoint: point,
            boundsHeight: bounds.height,
            tabFrames: currentTabFrames,
            orderedTabIds: orderedTabIds
        )
    }

    /// Shared insertion-index resolver used by tab-bar drag preview and drop commit.
    /// Returning nil means the pointer is outside the tab row and no insertion marker
    /// should be shown.
    nonisolated static func paneDropInsertionIndex(
        dropPoint: NSPoint,
        boundsHeight: CGFloat,
        tabFrames: [UUID: CGRect],
        orderedTabIds: [UUID]
    ) -> Int? {
        guard !orderedTabIds.isEmpty else { return nil }
        guard orderedTabIds.allSatisfy({ tabFrames[$0] != nil }) else { return nil }

        let swiftUIPoint = CGPoint(x: dropPoint.x, y: boundsHeight - dropPoint.y)
        let sortedTabs = orderedTabIds.enumerated().compactMap { index, tabId -> (index: Int, frame: CGRect)? in
            guard let frame = tabFrames[tabId] else { return nil }
            return (index: index, frame: frame)
        }.sorted { $0.frame.minX < $1.frame.minX }
        guard !sortedTabs.isEmpty else { return nil }

        // The AppKit destination owns the full tab-row bounds. SwiftUI pill
        // frames choose the horizontal insertion slot, but their visual
        // padding must not create dead drop bands above or below the pills.
        guard swiftUIPoint.y >= 0, swiftUIPoint.y <= boundsHeight else {
            return nil
        }

        // Find insertion point based on midpoint
        for item in sortedTabs {
            let midX = item.frame.midX
            if swiftUIPoint.x < midX {
                return item.index
            }
        }

        // Past the last tab
        return orderedTabIds.count
    }

    // MARK: - Window Drag

    /// A click that lands on a tab pill keeps existing tab selection / drag-reorder
    /// behavior — the pill's own hit testing wins. Anything else in the strip is
    /// empty chrome: a single click starts a native window drag, a double click
    /// performs the user's configured system titlebar double-click action.
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard tabAtPoint(location) == nil else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            performSystemDoubleClickAction()
            return
        }

        if let performWindowDrag {
            performWindowDrag(event)
        } else {
            window?.performDrag(with: event)
        }
    }

    private func performSystemDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: Self.doubleClickActionDefaultsKey) {
        case "Maximize":
            if let performWindowZoom {
                performWindowZoom()
            } else {
                window?.performZoom(nil)
            }
        case "Minimize":
            if let performWindowMiniaturize {
                performWindowMiniaturize()
            } else {
                window?.performMiniaturize(nil)
            }
        default:
            break
        }
    }

    private func clearDropTargetIndicator() {
        tabBarAdapter?.dropTargetIndex = nil
        resetPaneDragDwell()
    }

    private func resetPaneDragDwell() {
        dwellState = .idle
        tabBarAdapter?.dwellTabId = nil
        tabBarAdapter?.dwellProgress = 0
    }

    // MARK: - Pan Gesture Handler

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        // No runtime guard needed — pan gesture is controlled via isEnabled toggle.
        // This avoids consuming mouse events and interfering with SwiftUI's onTapGesture.
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            // Check if pan started on a tab
            if let tabId = tabAtPoint(location) {
                panStartTabId = tabId
                panStartEvent = NSApp.currentEvent
            }

        case .changed:
            // Start drag session once we have enough movement
            if let tabId = panStartTabId, draggingTabId == nil {
                guard let event = panStartEvent ?? NSApp.currentEvent else {
                    panStartTabId = nil
                    panStartEvent = nil
                    return
                }
                startDrag(tabId: tabId, at: location, event: event)
                panStartTabId = nil
                panStartEvent = nil
            }

        case .ended, .cancelled:
            // If pan ended with no drag started, this was a click — forward as tab selection.
            // The pan gesture consumes the mouse-down, preventing SwiftUI's onTapGesture.
            if let tabId = panStartTabId, draggingTabId == nil {
                onSelect?(tabId)
            }
            panStartTabId = nil
            panStartEvent = nil

        default:
            break
        }
    }

    // MARK: - Drag Initiation

    private func startDrag(tabId: UUID, at point: NSPoint, event: NSEvent) {
        draggingTabId = tabId

        // Update adapter to show drag visual immediately
        tabBarAdapter?.draggingTabId = tabId

        // Create pasteboard item with both formats
        let pasteboardItem = NSPasteboardItem()

        // Internal format for tab bar reordering
        pasteboardItem.setString(tabId.uuidString, forType: .agentStudioTabInternal)

        // SwiftUI-compatible format for terminal split drops
        if let payload = dragPayloadProvider?(tabId) {
            do {
                let payloadData = try JSONEncoder().encode(payload)
                pasteboardItem.setData(payloadData, forType: .agentStudioTabDrop)
            } catch {
                RestoreTrace.log(
                    "DraggableTabBarHostingView failed to encode tab drag payload tabId=\(tabId) error=\(error)"
                )
            }
        }

        // Create dragging item
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Set drag image
        if let frame = currentTabFrames[tabId] {
            let nsFrame = NSRect(
                x: frame.minX,
                y: bounds.height - frame.maxY,  // Flip Y back to NSView
                width: frame.width,
                height: frame.height
            )
            let image = createDragImage(for: tabId, frame: nsFrame)
            draggingItem.setDraggingFrame(nsFrame, contents: image)
        }

        // Start drag session
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func createDragImage(for tabId: UUID, frame: NSRect) -> NSImage {
        let image = NSImage(size: frame.size)
        image.lockFocus()

        // Draw pill background
        let pillRect = NSRect(origin: .zero, size: frame.size)
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.15).setFill()
        path.fill()

        // Draw border
        AppStyles.General.Accent.primaryNSColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        // Draw tab title
        if let tab = tabBarAdapter?.tabs.first(where: { $0.id == tabId }) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white,
            ]
            let title = tab.title as NSString
            let titleSize = title.size(withAttributes: attrs)
            let titlePoint = NSPoint(
                x: (frame.width - titleSize.width) / 2,
                y: (frame.height - titleSize.height) / 2
            )
            title.draw(at: titlePoint, withAttributes: attrs)
        }

        image.unlockFocus()
        return image
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // State already set in startDrag
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Cleanup
        Task { @MainActor [weak self] in
            self?.tabBarAdapter?.draggingTabId = nil
            self?.tabBarAdapter?.dropTargetIndex = nil
            self?.draggingTabId = nil
            self?.resetPaneDragDwell()
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        guard types.contains(.agentStudioTabInternal) || types.contains(.agentStudioPaneDrop) else {
            return []
        }

        if types.contains(.agentStudioPaneDrop) {
            paneDropTraceIsActive = true
            guard let paneData = sender.draggingPasteboard.data(forType: .agentStudioPaneDrop) else {
                recordPaneDropTrace(phase: "entered", outcome: "rejected", reason: "payload_missing")
                clearDropTargetIndicator()
                return []
            }
            guard let payload = decodePaneDragPayload(from: paneData, context: "draggingEntered") else {
                recordPaneDropTrace(
                    phase: "entered", outcome: "rejected", reason: "payload_decode_failed")
                clearDropTargetIndicator()
                return []
            }
            guard Self.allowsTabBarInsertion(for: payload) else {
                recordPaneDropTrace(phase: "entered", outcome: "rejected", reason: "drawer_child")
                clearDropTargetIndicator()
                return []
            }
        }

        // Reject drags when management layer exited mid-drag.
        // Pane drags start only from management layer affordances.
        if (types.contains(.agentStudioTabInternal) || types.contains(.agentStudioPaneDrop))
            && !atom(\.managementLayer).isActive
        {
            if types.contains(.agentStudioPaneDrop) {
                recordPaneDropTrace(
                    phase: "entered", outcome: "rejected", reason: "management_inactive")
            }
            return []
        }

        updateDropTarget(for: sender)
        if types.contains(.agentStudioPaneDrop) {
            let point = convert(sender.draggingLocation, from: nil)
            recordPaneDropTrace(
                phase: "entered",
                outcome: "accepted",
                reason: "none",
                targetResolved: dropIndexAtPoint(point) != nil
            )
        }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []

        if types.contains(.agentStudioPaneDrop),
            !paneDropIsAllowedInTabBar(sender.draggingPasteboard)
        {
            clearDropTargetIndicator()
            return []
        }

        // Reject drags when management layer exited mid-drag
        if (types.contains(.agentStudioTabInternal) || types.contains(.agentStudioPaneDrop))
            && !atom(\.managementLayer).isActive
        {
            Task { @MainActor [weak self] in
                self?.tabBarAdapter?.dropTargetIndex = nil
                self?.resetPaneDragDwell()
            }
            return []
        }

        updatePaneDragDwellIfNeeded(for: sender)

        updateDropTarget(for: sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropTargetIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if paneDropTraceIsActive {
            recordPaneDropTrace(phase: "terminal", outcome: "ended", reason: "none")
            paneDropTraceIsActive = false
        }
        clearDropTargetIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropTargetIndicator() }
        let pasteboard = sender.draggingPasteboard

        // Handle internal tab reorder (only when management layer is still active)
        if let idString = pasteboard.string(forType: .agentStudioTabInternal),
            let tabId = UUID(uuidString: idString),
            let insertionIndex = tabBarAdapter?.dropTargetIndex,
            atom(\.managementLayer).isActive
        {
            onReorder?(tabId, insertionIndex, UUIDv7.generate())
            return true
        }

        // Handle pane drop:
        // - Always use insertion index semantics on the tab row
        // - Create/move to a new tab at the insertion target
        guard (pasteboard.types ?? []).contains(.agentStudioPaneDrop) else { return false }
        guard let paneData = pasteboard.data(forType: .agentStudioPaneDrop) else {
            recordPaneDropTrace(phase: "commit", outcome: "rejected", reason: "payload_missing")
            return false
        }
        guard let payload = decodePaneDragPayload(from: paneData, context: "performDragOperation") else {
            recordPaneDropTrace(
                phase: "commit", outcome: "rejected", reason: "payload_decode_failed")
            return false
        }
        guard Self.allowsTabBarInsertion(for: payload) else {
            recordPaneDropTrace(phase: "commit", outcome: "rejected", reason: "drawer_child")
            return false
        }

        let dropPoint = convert(sender.draggingLocation, from: nil)
        guard let targetTabInsertionIndex = dropIndexAtPoint(dropPoint) else {
            recordPaneDropTrace(
                phase: "commit", outcome: "rejected", reason: "target_unresolved")
            return false
        }

        commandDispatcher.dispatchExtractPaneToTab(
            tabId: payload.tabId,
            paneId: payload.paneId,
            targetTabInsertionIndex: targetTabInsertionIndex
        )
        recordPaneDropTrace(
            phase: "commit", outcome: "requested", reason: "none", targetResolved: true)
        return true
    }

    private func paneDropIsAllowedInTabBar(_ pasteboard: NSPasteboard) -> Bool {
        guard let paneData = pasteboard.data(forType: .agentStudioPaneDrop),
            let payload = decodePaneDragPayload(
                from: paneData,
                context: "paneDropIsAllowedInTabBar"
            )
        else {
            return false
        }
        return Self.allowsTabBarInsertion(for: payload)
    }

    nonisolated static func allowsTabBarInsertion(for payload: PaneDragPayload) -> Bool {
        // Drawer child panes are constrained to their parent drawer and cannot
        // be moved into top-level tabs.
        payload.drawerParentPaneId == nil
    }

    private func updatePaneDragDwellIfNeeded(for sender: NSDraggingInfo) {
        guard
            let paneData = sender.draggingPasteboard.data(forType: .agentStudioPaneDrop),
            let payload = decodePaneDragPayload(
                from: paneData,
                context: "updatePaneDragDwellIfNeeded"
            )
        else {
            resetPaneDragDwell()
            return
        }

        let point = convert(sender.draggingLocation, from: nil)
        let hoveredTabId = tabAtPoint(point)
        if let hoveredTabId, hoveredTabId != tabBarAdapter?.activeTabId {
            onSelect?(hoveredTabId)

            if let drawerParentId = DragAutoDismissDecision.shouldAutoDismiss(
                payload: payload,
                destinationTabId: hoveredTabId,
                destinationExpandedDrawerParentPaneId: expandedDrawerParentIdForTab?(hoveredTabId)
            ) {
                onAutoDismissDrawerForDrag?(hoveredTabId, drawerParentId)
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        let (next, _) = DragDwellState.step(
            current: dwellState,
            hoveredTabId: hoveredTabId,
            now: now,
            dwellDuration: Self.paneDragHoverDwellDuration
        )

        dwellState = next
        tabBarAdapter?.dwellTabId = next.hoveredTabId
        tabBarAdapter?.dwellProgress = DragDwellProgress.progress(
            state: next,
            now: now,
            dwellDuration: Self.paneDragHoverDwellDuration
        )
    }

    private func decodePaneDragPayload(
        from data: Data,
        context: StaticString
    ) -> PaneDragPayload? {
        do {
            return try JSONDecoder().decode(PaneDragPayload.self, from: data)
        } catch {
            RestoreTrace.log(
                "DraggableTabBarHostingView.\(context) pane payload decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func recordPaneDropTrace(
        phase: String,
        outcome: String,
        reason: String,
        targetResolved: Bool = false
    ) {
        performanceTraceRecorder?.record(
            .tabBarPaneDrop,
            attributes: [
                "agentstudio.performance.tabbar.pane_drop.phase": .string(phase),
                "agentstudio.performance.tabbar.pane_drop.outcome": .string(outcome),
                "agentstudio.performance.tabbar.pane_drop.reason": .string(reason),
                "agentstudio.performance.management_layer.is_active": .bool(
                    atom(\.managementLayer).isActive
                ),
                "agentstudio.performance.tabbar.pane_drop.target_resolved": .bool(targetResolved),
                "agentstudio.performance.tabbar.pane_drop.frame.count": .int(currentTabFrames.count),
                "agentstudio.performance.tabbar.tab.count": .int(tabBarAdapter?.tabs.count ?? 0),
            ]
        )
    }

    private func updateDropTarget(for sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        if let index = dropIndexAtPoint(point) {
            // Don't highlight if dropping in same position.
            if let draggingId = draggingTabId,
                let currentIndex = tabBarAdapter?.tabs.firstIndex(where: { $0.id == draggingId }),
                index == currentIndex || index == currentIndex + 1
            {
                tabBarAdapter?.dropTargetIndex = nil
            } else {
                tabBarAdapter?.dropTargetIndex = index
            }
        } else {
            tabBarAdapter?.dropTargetIndex = nil
        }
    }
}
