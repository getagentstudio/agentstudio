import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInfrastructure
@testable import AgentStudioSharedComponents
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Zoom split bounds interactions", .serialized)
struct ZoomSplitInteractionTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("divider drag stops at the maximum terminal share")
    func dividerDragStopsAtMaximumTerminalShare() throws {
        let harness = makeMountedZoomSplit(initialRatio: 0.4)
        defer { close(harness.window) }

        try sendDrag(fromX: 160, toX: 380, in: harness.window)

        #expect(lastZoomRatio(in: harness.actions.actions) == 0.6)
    }

    @Test("divider drag stops at the minimum terminal share")
    func dividerDragStopsAtMinimumTerminalShare() throws {
        let harness = makeMountedZoomSplit(initialRatio: 0.4)
        defer { close(harness.window) }

        try sendDrag(fromX: 160, toX: 0, in: harness.window)

        #expect(lastZoomRatio(in: harness.actions.actions) == 0.3)
    }

    /// At these widths `(width * bound) / width` misrounds (1714: 0.3 → 0.29999999999999993,
    /// 0.6 → 0.5999999999999999), so the committed ratio must be clamped after the division
    /// or the exact-bounds validator rejects the drag and the stored ratio goes stale.
    @Test(
        "divider drag commits the exact bound through the workspace validator",
        arguments: [CGFloat(1714), CGFloat(431)]
    )
    func dividerDragCommitsExactBoundThroughWorkspaceValidator(width: CGFloat) async throws {
        // Arrange
        let fixture = makeValidatedZoomSplit(width: width)

        // Act: drag fully left, commit; then drag fully right, commit.
        try sendDrag(fromX: width * 0.4, toX: 0, in: fixture.window)
        let minimumCommits = await fixture.gestures.awaitSubmitted()
        let minimumStoredRatio = fixture.storedRatio()
        try sendDrag(fromX: width * 0.3, toX: width, in: fixture.window)
        let maximumCommits = await fixture.gestures.awaitSubmitted()
        let maximumStoredRatio = fixture.storedRatio()

        // Assert
        #expect(minimumCommits == [true])
        #expect(minimumStoredRatio == AppPolicies.PaneZoomSplit.minimumTerminalRatio)
        #expect(maximumCommits == [true])
        #expect(maximumStoredRatio == AppPolicies.PaneZoomSplit.maximumTerminalRatio)

        close(fixture.window)
        await fixture.executor.stopAcceptingCommandsAndDrain()
        await fixture.coordinator.shutdown()
    }

    @Test("double-clicking the divider resets terminal share to forty percent")
    func doubleClickResetsTerminalShareToDefault() throws {
        let harness = makeMountedZoomSplit(initialRatio: 0.55)
        defer { close(harness.window) }

        try sendDoubleClick(atX: 220, in: harness.window)

        #expect(lastZoomRatio(in: harness.actions.actions) == 0.4)
    }

    private func makeMountedZoomSplit(initialRatio: Double) -> MountedZoomSplit {
        let actions = ZoomSplitActionRecorder()
        let sourcePaneId = UUIDv7.generate()
        let companionPaneId = UUIDv7.generate()
        let actionDispatcher = PaneTabActionDispatcher(
            dispatch: { actions.actions.append($0) },
            shouldHandleSplitDragPayload: { _ in false },
            shouldAcceptDrop: { _, _, _, _ in false },
            handleDrop: { _, _, _, _ in }
        )
        let rootView = ZoomPresentationContainer(
            tabId: UUIDv7.generate(),
            sourcePaneId: sourcePaneId,
            sourceOrdinal: 1,
            sourceContent: AnyView(Color.clear),
            companionContent: AnyView(Color.clear),
            parentToolbarPresentation: .zoom(ZoomToolbarModel(viewerAction: nil, zoomAction: nil)),
            splitRatio: initialRatio,
            store: WorkspaceStore(),
            octiconLoader: makeTestOcticonLoader(),
            editorChooser: makeTestAtomRegistry().editorChooser,
            actionDispatcher: actionDispatcher,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(),
            arrangementInlineRenameState: ArrangementInlineRenameState(),
            onPaneFocusTrigger: { _ in },
            viewRegistry: ViewRegistry(),
            surfaceId: "zoom-split-interaction-test",
            renderedPaneIds: [sourcePaneId, companionPaneId]
        )
        let hostingView = NSHostingView(rootView: rootView.frame(width: 400, height: 240))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        return MountedZoomSplit(window: window, actions: actions)
    }

    /// Mounts the split over a real store, coordinator, and executor so divider
    /// commits take the production `submitGesture` → validator → atom route.
    private func makeValidatedZoomSplit(width: CGFloat) -> ValidatedZoomSplit {
        let store = WorkspaceStore()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: GeometryReevaluationCapturingSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
        let sourcePane = store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: sourcePane.id,
            viewerPresentation: .unavailableVisible
        )
        let gestures = SubmittedZoomSplitGestures()
        let actionDispatcher = PaneTabActionDispatcher(
            dispatch: { action in
                gestures.tasks.append(executor.submitGesture { execute in await execute(action) })
            },
            shouldHandleSplitDragPayload: { _ in false },
            shouldAcceptDrop: { _, _, _, _ in false },
            handleDrop: { _, _, _, _ in }
        )
        let rootView = ZoomPresentationContainer(
            tabId: tab.id,
            sourcePaneId: sourcePane.id,
            sourceOrdinal: 1,
            sourceContent: AnyView(Color.clear),
            companionContent: AnyView(Color.clear),
            parentToolbarPresentation: .zoom(ZoomToolbarModel(viewerAction: nil, zoomAction: nil)),
            splitRatio: AppPolicies.PaneZoomSplit.defaultTerminalRatio,
            store: store,
            octiconLoader: makeTestOcticonLoader(),
            editorChooser: makeTestAtomRegistry().editorChooser,
            actionDispatcher: actionDispatcher,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(),
            arrangementInlineRenameState: ArrangementInlineRenameState(),
            onPaneFocusTrigger: { _ in },
            viewRegistry: ViewRegistry(),
            surfaceId: "zoom-split-validated-interaction-test",
            renderedPaneIds: [sourcePane.id]
        )
        let hostingView = NSHostingView(rootView: rootView.frame(width: width, height: 240))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        return ValidatedZoomSplit(
            window: window,
            store: store,
            coordinator: coordinator,
            executor: executor,
            gestures: gestures,
            tabId: tab.id
        )
    }

    private func sendDrag(fromX startX: CGFloat, toX endX: CGFloat, in window: NSWindow) throws {
        let y: CGFloat = 120
        window.sendEvent(try mouseEvent(.leftMouseDown, at: CGPoint(x: startX, y: y), window: window, number: 1))
        window.sendEvent(try mouseEvent(.leftMouseDragged, at: CGPoint(x: endX, y: y), window: window, number: 2))
        window.sendEvent(try mouseEvent(.leftMouseUp, at: CGPoint(x: endX, y: y), window: window, number: 3))
    }

    private func sendDoubleClick(atX x: CGFloat, in window: NSWindow) throws {
        let point = CGPoint(x: x, y: 120)
        window.sendEvent(try mouseEvent(.leftMouseDown, at: point, window: window, number: 1, clickCount: 1))
        window.sendEvent(try mouseEvent(.leftMouseUp, at: point, window: window, number: 2, clickCount: 1))
        window.sendEvent(try mouseEvent(.leftMouseDown, at: point, window: window, number: 3, clickCount: 2))
        window.sendEvent(try mouseEvent(.leftMouseUp, at: point, window: window, number: 4, clickCount: 2))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        window: NSWindow,
        number: Int,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: Double(number) / 10,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: clickCount,
                pressure: type == .leftMouseUp ? 0 : 1
            )
        )
    }

    private func lastZoomRatio(in actions: [WorkspaceActionCommand]) -> Double? {
        for action in actions.reversed() {
            if case .setZoomSplitRatio(_, let ratio) = action {
                return ratio
            }
        }
        return nil
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private struct MountedZoomSplit {
    let window: NSWindow
    let actions: ZoomSplitActionRecorder
}

@MainActor
private struct ValidatedZoomSplit {
    let window: NSWindow
    let store: WorkspaceStore
    let coordinator: WorkspaceSurfaceCoordinator
    let executor: WorkspaceActionExecutor
    let gestures: SubmittedZoomSplitGestures
    let tabId: UUID

    func storedRatio() -> Double? {
        store.panePresentationAtom.zoomPresentationsByTabId[tabId]?.transientSplitRatio
    }
}

/// Holds the executor tasks the divider submitted, so the test awaits each
/// commit's own completion instead of waiting on time.
@MainActor
private final class SubmittedZoomSplitGestures {
    var tasks: [Task<Bool, Never>] = []

    func awaitSubmitted() async -> [Bool] {
        let submitted = tasks
        tasks = []
        var results: [Bool] = []
        for task in submitted {
            results.append(await task.value)
        }
        return results
    }
}

@MainActor
private final class ZoomSplitActionRecorder {
    var actions: [WorkspaceActionCommand] = []
}
