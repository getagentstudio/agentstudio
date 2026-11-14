import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneFocusExecutorTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("executor applies host responder focus without direct helper bypass")
    func executorAppliesHostResponderFocus() throws {
        let window = try makeWindow()
        let paneHost = PaneHostView(paneId: UUID())
        try attach(paneHost, to: window)

        let executor = makeExecutor()
        executor.registerHostView(paneHost)

        executor.apply(
            PaneFocusDecision.contentClick(
                PaneContentClickFocusDecision(
                    selection: .keep,
                    responder: .focusPaneHost(paneId: paneHost.paneId),
                    runtime: .preserveRuntimeFocus,
                    content: .preserve,
                    reason: .explicitRefocus
                )
            )
        )

        #expect(window.firstResponder === paneHost)
    }

    @Test("executor focuses mounted content for explicit non-terminal refocus")
    func executorFocusesMountedContentForNonTerminalRefocus() throws {
        let window = try makeWindow()
        let paneHost = PaneHostView(paneId: UUID())
        let mountedContent = FocusableMountedContentView()
        paneHost.mountContentView(mountedContent)
        try attach(paneHost, to: window)

        let executor = makeExecutor()
        executor.registerHostView(paneHost)

        executor.apply(
            PaneFocusDecision.refocusRequest(
                PaneRefocusRequestDecision(
                    responder: .focusMountedContent(paneId: paneHost.paneId),
                    runtime: .preserveRuntimeFocus,
                    reason: .explicitRefocus
                )
            )
        )

        #expect(window.firstResponder === mountedContent)
    }

    @Test("active webview content click preserves the mounted responder")
    func activeWebviewContentClickPreservesMountedResponder() throws {
        let window = try makeWindow()
        let paneHost = PaneHostView(paneId: UUID())
        let mountedContent = FocusableMountedContentView()
        paneHost.mountContentView(mountedContent)
        try attach(paneHost, to: window)
        window.makeFirstResponder(mountedContent)

        let executor = makeExecutor()
        executor.registerHostView(paneHost)

        let decision = PaneFocusOrchestrator.decide(
            trigger: .contentClick(
                PaneContentClickFocusTrigger(
                    targetPaneId: paneHost.paneId,
                    location: .content,
                    clickPhase: .completed
                )
            ),
            context: PaneFocusContext(
                activeTabId: UUID(),
                activePaneId: paneHost.paneId,
                activeDrawer: nil,
                targetPaneId: paneHost.paneId,
                targetTabId: UUID(),
                targetPaneKind: .webview,
                targetPaneIsAlreadyActive: true,
                targetMountedContent: .nonTerminal(acceptsFirstResponder: true),
                managementLayer: .inactive,
                windowState: .key
            )
        )

        executor.apply(decision)

        #expect(window.firstResponder === mountedContent)
        #expect(window.firstResponder !== paneHost)
    }

    @Test("executor does not unfocus all terminal runtime surfaces when mounted surface is missing")
    func executorDoesNotSyncRuntimeWhenMountedSurfaceIsMissing() throws {
        let paneHost = PaneHostView(paneId: UUID())
        var syncedSurfaceIds: [UUID?] = []

        let executor = PaneFocusExecutor(
            hostViewProvider: { _ in nil },
            hostViewsProvider: { [] },
            selectTab: { _ in },
            selectPane: { _, _ in },
            selectDrawerPane: { _, _ in },
            selectEmptyDrawer: { _ in },
            syncRuntimeFocus: { syncedSurfaceIds.append($0) }
        )
        executor.registerHostView(paneHost)

        executor.apply(
            .refocusRequest(
                PaneRefocusRequestDecision(
                    responder: .preserveCurrentResponder,
                    runtime: .syncTerminalSurface(paneId: paneHost.paneId),
                    reason: .explicitRefocus
                )
            )
        )

        #expect(syncedSurfaceIds.isEmpty)
    }

    @Test("drawer browser content taps preserve the native editing descendant", arguments: [false, true])
    func drawerBrowserContentTapPreservesNativeDescendant(alreadyActive: Bool) throws {
        // Arrange: native editing has taken focus before the completed-tap callback runs.
        let parentPaneId = UUIDv7.generate()
        let tabId = UUIDv7.generate()
        let paneHost = PaneHostView(paneId: UUIDv7.generate())
        let mountedContent = FocusableMountedContentView()
        let editingDescendant = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        editingDescendant.string = "selected browser text"
        editingDescendant.setSelectedRange(NSRange(location: 0, length: 8))
        mountedContent.addSubview(editingDescendant)
        paneHost.mountContentView(mountedContent)
        let window = try makeWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try attach(paneHost, to: window)
        #expect(window.makeFirstResponder(editingDescendant))
        var selectedDrawerPaneId: UUID?
        let executor = PaneFocusExecutor(
            hostViewProvider: { _ in paneHost },
            hostViewsProvider: { [paneHost] },
            selectTab: { _ in },
            selectPane: { _, _ in Issue.record("drawer content must not select a main pane") },
            selectDrawerPane: { parentId, childId in
                #expect(parentId == parentPaneId)
                selectedDrawerPaneId = childId
            },
            selectEmptyDrawer: { _ in },
            syncRuntimeFocus: { _ in Issue.record("browser content must not change terminal runtime focus") }
        )
        let context = PaneFocusContext(
            activeTabId: tabId,
            activePaneId: alreadyActive ? paneHost.paneId : parentPaneId,
            activeDrawer: .init(parentPaneId: parentPaneId, paneId: paneHost.paneId),
            targetPaneId: paneHost.paneId,
            targetTabId: tabId,
            targetPaneKind: .webview,
            targetPaneIsAlreadyActive: alreadyActive,
            targetMountedContent: .nonTerminal(acceptsFirstResponder: true),
            managementLayer: .inactive,
            windowState: .key
        )

        // Act: use the same ingress mapping as the leaf's completed content tap.
        let trigger = PaneLeafContainer.contentClickFocusTrigger(
            paneId: paneHost.paneId, drawerParentPaneId: parentPaneId
        )
        #expect(executor.apply(PaneFocusOrchestrator.decide(trigger: trigger, context: context)))

        // Assert: selection and native responder ownership are separate outcomes.
        #expect(window.firstResponder === editingDescendant)
        #expect(editingDescendant.selectedRange() == NSRange(location: 0, length: 8))
        #expect(selectedDrawerPaneId == (alreadyActive ? nil : paneHost.paneId))
    }

    private func makeExecutor() -> PaneFocusExecutor {
        PaneFocusExecutor(
            hostViewProvider: { _ in nil },
            hostViewsProvider: { [] },
            selectTab: { _ in },
            selectPane: { _, _ in },
            selectDrawerPane: { _, _ in },
            selectEmptyDrawer: { _ in },
            syncRuntimeFocus: { _ in }
        )
    }

    private func makeWindow() throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        _ = try #require(window.contentView)
        return window
    }

    private func attach(_ view: NSView, to window: NSWindow) throws {
        let contentView = try #require(window.contentView)
        view.frame = contentView.bounds
        contentView.addSubview(view)
        view.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class FocusableMountedContentView: NSView, PaneMountedContent {
    override var acceptsFirstResponder: Bool { true }

    func setContentInteractionEnabled(_: Bool) {}
}
