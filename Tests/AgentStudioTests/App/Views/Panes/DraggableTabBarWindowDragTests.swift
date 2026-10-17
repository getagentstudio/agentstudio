import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct DraggableTabBarWindowDragTests {
    private static let doubleClickActionDefaultsKey = "AppleActionOnDoubleClick"

    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("tab host does not rely on AppKit mouseDown window-drag inference")
    func tabHostDoesNotRelyOnMouseDownWindowDragInference() throws {
        let source = try sourceContents("Sources/AgentStudio/App/Panes/TabBar/DraggableTabBarHostingView.swift")

        #expect(
            !source.contains("mouseDownCanMoveWindow"),
            "Tab host must not patch child hit views with mouseDownCanMoveWindow. Disable native window movement at the NSWindow boundary instead."
        )
    }

    @Test("main window allows native movement so performDrag can move it")
    func mainWindowAllowsNativeMovementButNotBackgroundDrag() throws {
        let source = try sourceContents("Sources/AgentStudio/App/Windows/MainWindowController.swift")

        #expect(source.contains("window.isMovable = true"))
        #expect(source.contains("window.isMovableByWindowBackground = false"))
    }

    @Test("toolbar chrome no longer hosts a separate drag region overlay")
    func toolbarChromeNoLongerHostsSeparateDragRegionOverlay() throws {
        let source = try sourceContents("Sources/AgentStudio/App/Windows/MainToolbarChromeView.swift")

        #expect(!source.contains("ShellChromeDragRegionView"))
        #expect(!source.contains("windowDragRegionHeight"))
    }

    @Test("tab host owns mouse down window-drag handling directly")
    func tabHostOwnsMouseDownWindowDragHandlingDirectly() throws {
        let source = try sourceContents("Sources/AgentStudio/App/Panes/TabBar/DraggableTabBarHostingView.swift")

        #expect(source.contains("override func mouseDown(with event: NSEvent)"))
        #expect(source.contains("tabAtPoint(location)"))
        #expect(source.contains("AppleActionOnDoubleClick"))
    }

    @Test("a click inside a tab pill frame does not start a window drag")
    func clickInsidePillFrameDoesNotStartWindowDrag() throws {
        let fixture = makeHostingViewFixture()
        var didDrag = false
        fixture.hostingView.performWindowDrag = { _ in didDrag = true }

        let event = try makeMouseDownEvent(
            atNSViewPoint: fixture.pointInsidePill, clickCount: 1, windowNumber: fixture.window.windowNumber
        )
        fixture.hostingView.mouseDown(with: event)

        #expect(!didDrag)
    }

    @Test("a secondary click entering the tab host emits an input trace")
    func secondaryClickEnteringTabHostEmitsInputTrace() async throws {
        let traceDirectory = FileManager.default.temporaryDirectory.appending(
            path: "tab-context-menu-input-\(UUIDv7.generate().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: traceDirectory) }
        let traceRuntime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "tab-context-menu-input",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 941,
            timeUnixNano: { 941 }
        )
        let traceRecorder = AgentStudioPerformanceTraceRecorder(traceRuntime: traceRuntime)
        let fixture = makeHostingViewFixture(performanceTraceRecorder: traceRecorder)
        let event = try makeMouseDownEvent(
            type: .rightMouseDown,
            atNSViewPoint: fixture.pointInsidePill,
            clickCount: 1,
            windowNumber: fixture.window.windowNumber
        )

        NSApp.sendEvent(event)
        fixture.hostingView.currentEventProvider = { event }
        _ = fixture.hostingView.hitTest(fixture.pointInsidePill)
        try await traceRecorder.drain()

        let outputFileURL = try #require(traceRuntime.outputFileURL)
        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(contents.contains("\"body\":\"performance.tabbar.context_menu\""))
        #expect(contents.contains("\"agentstudio.performance.tabbar.context_menu.phase\":\"input\""))
        #expect(contents.contains("\"agentstudio.performance.tabbar.context_menu.tab_hit\":true"))
        #expect(contents.contains("\"agentstudio.performance.tabbar.context_menu.phase\":\"host_hit_test\""))
        #expect(contents.contains("\"agentstudio.performance.tabbar.context_menu.host_hit\":true"))
        #expect(
            contents.contains(
                "\"agentstudio.performance.tabbar.context_menu.hit_view_class\":\"swiftui\""
            )
        )
    }

    @Test("pane drag entry emits bounded target telemetry")
    func paneDragEntryEmitsBoundedTargetTelemetry() async throws {
        let traceDirectory = FileManager.default.temporaryDirectory.appending(
            path: "tab-pane-drop-input-\(UUIDv7.generate().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: traceDirectory) }
        let traceRuntime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "tab-pane-drop-input",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 942,
            timeUnixNano: { 942 }
        )
        let traceRecorder = AgentStudioPerformanceTraceRecorder(traceRuntime: traceRuntime)
        let fixture = makeHostingViewFixture(performanceTraceRecorder: traceRecorder)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test.pane-drop-\(UUIDv7.generate())"))
        pasteboard.clearContents()
        let payload = PaneDragPayload(paneId: UUIDv7.generate(), tabId: fixture.tabId)
        pasteboard.setData(try JSONEncoder().encode(payload), forType: .agentStudioPaneDrop)
        let dragInfo = TabReorderDraggingInfo(
            pasteboard: pasteboard,
            location: fixture.hostingView.convert(fixture.pointInsidePill, to: nil)
        )
        atom(\.managementLayer).activate()
        defer { atom(\.managementLayer).deactivate() }

        let operation = fixture.hostingView.draggingEntered(dragInfo)
        _ = fixture.hostingView.draggingUpdated(dragInfo)
        _ = fixture.hostingView.draggingUpdated(dragInfo)
        fixture.hostingView.draggingEnded(dragInfo)
        try await traceRecorder.drain()

        #expect(operation == .move)
        let outputFileURL = try #require(traceRuntime.outputFileURL)
        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(contents.contains("\"body\":\"performance.tabbar.pane_drop\""))
        #expect(contents.contains("\"agentstudio.performance.tabbar.pane_drop.phase\":\"entered\""))
        #expect(contents.contains("\"agentstudio.performance.tabbar.pane_drop.outcome\":\"accepted\""))
        #expect(contents.contains("\"agentstudio.performance.management_layer.is_active\":true"))
        #expect(contents.contains("\"agentstudio.performance.tabbar.pane_drop.frame.count\":1"))
        #expect(
            contents.split(separator: "\n").filter { line in
                line.contains("\"body\":\"performance.tabbar.pane_drop\"")
            }.count == 2
        )
        #expect(contents.contains("\"agentstudio.performance.tabbar.pane_drop.phase\":\"terminal\""))
        #expect(contents.contains("\"agentstudio.performance.tabbar.pane_drop.outcome\":\"ended\""))
        #expect(!contents.contains(payload.paneId.uuidString))
    }

    @Test("a secondary click on a tab requests its native context menu and consumes the event")
    func secondaryClickOnTabRequestsContextMenuAndConsumesEvent() throws {
        let fixture = makeHostingViewFixture()
        var requestedTabId: UUID?
        fixture.hostingView.contextMenuRequestHandler = { tabId, _ in
            requestedTabId = tabId
            return true
        }
        let event = try makeMouseDownEvent(
            type: .rightMouseDown,
            atNSViewPoint: fixture.pointInsidePill,
            clickCount: 1,
            windowNumber: fixture.window.windowNumber
        )

        let forwardedEvent = fixture.hostingView.processRightMouseDown(event)

        #expect(requestedTabId == fixture.tabId)
        #expect(forwardedEvent == nil)
    }

    @Test("a click in the empty strip starts a window drag")
    func clickInEmptyStripStartsWindowDrag() throws {
        let fixture = makeHostingViewFixture()
        var draggedEvent: NSEvent?
        fixture.hostingView.performWindowDrag = { draggedEvent = $0 }

        let event = try makeMouseDownEvent(
            atNSViewPoint: fixture.pointOutsidePill, clickCount: 1, windowNumber: fixture.window.windowNumber
        )
        fixture.hostingView.mouseDown(with: event)

        #expect(draggedEvent === event)
    }

    @Test("a never-presented tab host runs the AppKit destination reorder lifecycle")
    func neverPresentedTabHostRunsAppKitDestinationReorderLifecycle() async throws {
        let fixture = makeTabReorderHostingViewFixture()
        defer {
            fixture.window.orderOut(nil)
            try? FileManager.default.removeItem(at: fixture.harness.tempDir)
        }
        await eventually("tab adapter materializes reorder tabs") {
            fixture.hostingView.tabBarAdapter?.tabs.map(\.id) == fixture.tabIds
        }

        atom(\.managementLayer).activate()
        defer { atom(\.managementLayer).deactivate() }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test.tab-reorder-\(UUIDv7.generate())"))
        pasteboard.clearContents()
        pasteboard.setString(fixture.tabIds[0].uuidString, forType: .agentStudioTabInternal)
        let lastTabFrame = try #require(fixture.tabFrames.values.max { $0.maxX < $1.maxX })
        let localDropPoint = NSPoint(
            x: lastTabFrame.maxX + 500,
            y: fixture.hostingView.bounds.height - lastTabFrame.midY
        )
        let insertionIndex = try #require(
            DraggableTabBarHostingView.paneDropInsertionIndex(
                dropPoint: localDropPoint,
                boundsHeight: fixture.hostingView.bounds.height,
                tabFrames: fixture.tabFrames,
                orderedTabIds: fixture.tabIds
            )
        )
        #expect(insertionIndex == fixture.tabIds.count)
        let dragInfo = TabReorderDraggingInfo(
            pasteboard: pasteboard,
            location: fixture.hostingView.convert(localDropPoint, to: nil)
        )

        #expect(fixture.hostingView.draggingEntered(dragInfo) == .move)
        #expect(fixture.hostingView.performDragOperation(dragInfo))
        _ = await fixture.harness.executor.submitGesture { _ in true }.value
        #expect(fixture.harness.store.tabs.map(\.id) == [fixture.tabIds[1], fixture.tabIds[2], fixture.tabIds[0]])
    }

    @Test("a double click in the empty strip zooms when the system pref is Maximize")
    func doubleClickInEmptyStripZoomsWhenSystemPrefIsMaximize() throws {
        UserDefaults.standard.set("Maximize", forKey: Self.doubleClickActionDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.doubleClickActionDefaultsKey) }

        let fixture = makeHostingViewFixture()
        var didZoom = false
        var didDrag = false
        fixture.hostingView.performWindowZoom = { didZoom = true }
        fixture.hostingView.performWindowDrag = { _ in didDrag = true }

        let event = try makeMouseDownEvent(
            atNSViewPoint: fixture.pointOutsidePill, clickCount: 2, windowNumber: fixture.window.windowNumber
        )
        fixture.hostingView.mouseDown(with: event)

        #expect(didZoom)
        #expect(!didDrag)
    }

    @Test("a double click in the empty strip minimizes when the system pref is Minimize")
    func doubleClickInEmptyStripMinimizesWhenSystemPrefIsMinimize() throws {
        UserDefaults.standard.set("Minimize", forKey: Self.doubleClickActionDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.doubleClickActionDefaultsKey) }

        let fixture = makeHostingViewFixture()
        var didMiniaturize = false
        fixture.hostingView.performWindowMiniaturize = { didMiniaturize = true }

        let event = try makeMouseDownEvent(
            atNSViewPoint: fixture.pointOutsidePill, clickCount: 2, windowNumber: fixture.window.windowNumber
        )
        fixture.hostingView.mouseDown(with: event)

        #expect(didMiniaturize)
    }

    @Test("a double click in the empty strip does nothing when the system pref is some other value")
    func doubleClickInEmptyStripDoesNothingWhenSystemPrefIsSomeOtherValue() throws {
        // Setting an explicit non-matching value (rather than removeObject) keeps this
        // deterministic: UserDefaults.standard falls through to NSGlobalDomain, and this
        // machine's real "double-click title bar" system preference could otherwise leak
        // in as "Maximize" once the app-level override is merely removed.
        UserDefaults.standard.set("None", forKey: Self.doubleClickActionDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.doubleClickActionDefaultsKey) }

        let fixture = makeHostingViewFixture()
        var didZoom = false
        var didMiniaturize = false
        var didDrag = false
        fixture.hostingView.performWindowZoom = { didZoom = true }
        fixture.hostingView.performWindowMiniaturize = { didMiniaturize = true }
        fixture.hostingView.performWindowDrag = { _ in didDrag = true }

        let event = try makeMouseDownEvent(
            atNSViewPoint: fixture.pointOutsidePill, clickCount: 2, windowNumber: fixture.window.windowNumber
        )
        fixture.hostingView.mouseDown(with: event)

        #expect(!didZoom)
        #expect(!didMiniaturize)
        #expect(!didDrag)
    }

    @MainActor
    @Test("main split no longer owns a content chrome row")
    func mainSplitNoLongerOwnsContentChromeRow() throws {
        let source = try sourceContents("Sources/AgentStudio/App/Windows/MainSplitViewController.swift")

        #expect(!source.contains("shellChromeContainerView"))
        #expect(!source.contains("installShellChrome"))
        #expect(source.contains("makeToolbarChromeView"))
    }

    // MARK: - Fixture

    private struct HostingViewFixture {
        let hostingView: DraggableTabBarHostingView
        let window: NSWindow
        let tabId: UUID
        let pointInsidePill: NSPoint
        let pointOutsidePill: NSPoint
    }

    private struct TabReorderHostingViewFixture {
        let harness: Harness
        let hostingView: DraggableTabBarHostingView
        let window: NSWindow
        let tabIds: [UUID]
        let tabFrames: [UUID: CGRect]
    }

    private func makeTabReorderHostingViewFixture() -> TabReorderHostingViewFixture {
        let harness = makeHarness()
        let firstPane = harness.store.createPane(title: "First")
        let secondPane = harness.store.createPane(title: "Second")
        let thirdPane = harness.store.createPane(title: "Third")
        let tabs = [
            Tab(paneId: firstPane.id, name: "First"),
            Tab(paneId: secondPane.id, name: "Second"),
            Tab(paneId: thirdPane.id, name: "Third"),
        ]
        for tab in tabs {
            harness.store.appendTab(tab)
        }

        let hostingView = harness.controller.makeTabBarHostingView()
        let bounds = NSRect(x: 0, y: 0, width: 400, height: AppStyles.Shell.TabBar.height)
        hostingView.frame = bounds
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.contentView?.layoutSubtreeIfNeeded()
        let tabFrames = [
            tabs[0].id: CGRect(x: 0, y: 4, width: 100, height: 32),
            tabs[1].id: CGRect(x: 100, y: 4, width: 100, height: 32),
            tabs[2].id: CGRect(x: 200, y: 4, width: 100, height: 32),
        ]
        hostingView.updateTabFrames(tabFrames)
        hostingView.tabBarAdapter?.tabFrames = tabFrames

        return TabReorderHostingViewFixture(
            harness: harness,
            hostingView: hostingView,
            window: window,
            tabIds: tabs.map(\.id),
            tabFrames: tabFrames
        )
    }

    /// Builds a `DraggableTabBarHostingView` hosted as the content view of a real,
    /// never-ordered-front borderless window, with one tab-pill frame seeded directly
    /// via `updateTabFrames`. The window performs one layout pass so hit testing reaches
    /// the hosted SwiftUI subtree. `mouseDown` converts
    /// `event.locationInWindow` through `convert(_:from:)`, which needs a real window
    /// to resolve correctly; a borderless window sized to the view's bounds keeps
    /// window-base coordinates identical to the view's own local coordinates.
    /// `tabAtPoint` then flips NSView-space points (bottom-left origin) into the
    /// SwiftUI-space frame stored in `tabFrames` (top-left origin), so the two probe
    /// points below are chosen to land inside and outside the seeded pill frame after
    /// that flip.
    private func makeHostingViewFixture(
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) -> HostingViewFixture {
        let atoms = makeTestAtomRegistry()
        let store = WorkspaceStore(
            identityAtom: atoms.core.workspaceIdentity,
            windowMemoryAtom: atoms.core.workspaceWindowMemory,
            repositoryTopologyAtom: atoms.core.workspaceRepositoryTopology,
            paneAtom: atoms.core.workspacePane,
            tabLayoutAtom: atoms.core.workspaceTabLayout,
            mutationCoordinator: atoms.core.workspaceMutationCoordinator
        )
        let adapter = TabBarAdapter(
            store: store,
            repoCache: atoms.core.repoCache,
            performanceTraceRecorder: performanceTraceRecorder
        )
        let tabBar = CustomTabBar(
            adapter: adapter,
            onSelect: { _ in },
            canDispatchCommand: { _, _ in true },
            onCommand: { _, _ in },
            onShowArrangements: { _ in }
        )
        let hostingView = DraggableTabBarHostingView(
            rootView: tabBar,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(), performanceTraceRecorder: performanceTraceRecorder
        )
        hostingView.configure(adapter: adapter) { _, _, _ in }
        let boundsHeight: CGFloat = AppStyles.Shell.TabBar.height
        let bounds = NSRect(x: 0, y: 0, width: 400, height: boundsHeight)
        hostingView.frame = bounds

        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.contentView?.layoutSubtreeIfNeeded()

        let tabId = UUIDv7.generate()
        let pillFrame = CGRect(x: 20, y: 4, width: 100, height: AppStyles.Shell.TabBar.tabPillHeight)
        hostingView.updateTabFrames([tabId: pillFrame])

        return HostingViewFixture(
            hostingView: hostingView,
            window: window,
            tabId: tabId,
            pointInsidePill: NSPoint(x: 50, y: boundsHeight - 20),
            pointOutsidePill: NSPoint(x: 300, y: boundsHeight - 20)
        )
    }

    private func makeMouseDownEvent(
        type: NSEvent.EventType = .leftMouseDown,
        atNSViewPoint point: NSPoint,
        clickCount: Int,
        windowNumber: Int
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 10,
                clickCount: clickCount,
                pressure: 1
            )
        )
    }

    private func sourceContents(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        return try String(contentsOf: projectRoot.appending(path: relativePath), encoding: .utf8)
    }
}

private final class TabReorderDraggingInfo: NSObject, NSDraggingInfo {
    nonisolated let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint

    @MainActor
    init(pasteboard: NSPasteboard, location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        super.init()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set { _ = newValue }
    }
    var animatesToDestination: Bool {
        get { false }
        set { _ = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { 0 }
        set { _ = newValue }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions,
        for _: NSView?,
        classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
        using _: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
