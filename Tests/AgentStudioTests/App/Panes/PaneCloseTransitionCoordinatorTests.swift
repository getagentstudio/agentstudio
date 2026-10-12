import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneCloseTransitionCoordinatorTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("close transition marks pane closing until the injected clock advances")
    func beginClosingPane_marksPaneClosingUntilClockAdvances() async throws {
        let clock = TestPushClock()
        let coordinator = PaneCloseTransitionCoordinator(clock: clock)
        let paneId = UUID()
        var closeActionFired = false
        var closeActionContinuation: CheckedContinuation<Void, Never>?

        coordinator.beginClosingPane(paneId, delay: .milliseconds(120)) {
            closeActionFired = true
            closeActionContinuation?.resume()
            closeActionContinuation = nil
        }

        #expect(coordinator.closingPaneIds.contains(paneId))
        #expect(closeActionFired == false)

        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(120))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closeActionFired {
                continuation.resume()
            } else {
                closeActionContinuation = continuation
            }
        }

        #expect(closeActionFired == true)
        #expect(coordinator.closingPaneIds.contains(paneId) == false)
    }

    @Test("cancelCloseTransition stops the pending performClose")
    func paneCloseTransitionCoordinator_cancel_stopsPerformClose() async throws {
        let clock = TestPushClock()
        let coordinator = PaneCloseTransitionCoordinator(clock: clock)
        let paneId = UUID()
        var performCloseRan = false

        coordinator.beginClosingPane(paneId, delay: .milliseconds(120)) {
            performCloseRan = true
        }

        await clock.waitForPendingSleepCount()
        coordinator.cancelCloseTransition(paneId)
        await clock.waitForPendingSleepCount(exactly: 0)
        clock.advance(by: .milliseconds(120))

        #expect(performCloseRan == false)
        #expect(coordinator.closingPaneIds.contains(paneId) == false)
    }

    @Test("coordinator deinitialization cancels pending close tasks")
    func deinit_cancelsPendingCloseTask() async throws {
        let clock = TestPushClock()
        weak var weakCoordinator: PaneCloseTransitionCoordinator?

        do {
            let coordinator = PaneCloseTransitionCoordinator(clock: clock)
            weakCoordinator = coordinator
            coordinator.beginClosingPane(UUID(), delay: .milliseconds(120)) {}

            await clock.waitForPendingSleepCount()
            #expect(clock.pendingSleepCount == 1)
        }

        await clock.waitForPendingSleepCount(exactly: 0)

        #expect(weakCoordinator == nil)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test("drawer child close transition removes the last drawer pane into empty drawer context")
    func drawerChildCloseTransition_lastDrawerPane_landsInEmptyDrawerContext() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let parentPane = harness.store.createPane()
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        let parentMountedContent = FocusablePaneTabCommandMountedContentView()
        let drawerMountedContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: parentPane.id,
            in: harness,
            to: window,
            mountedContent: parentMountedContent
        )
        let drawerHost = try attachPaneHost(
            paneId: drawerPane.id,
            in: harness,
            to: window,
            mountedContent: drawerMountedContent
        )

        let clock = TestPushClock()
        let closeCoordinator = PaneCloseTransitionCoordinator(clock: clock)
        var closeActionFinished = false
        var closeActionContinuation: CheckedContinuation<Void, Never>?
        let actionDispatcher = PaneTabActionDispatcher(
            dispatch: { action in
                Issue.record("Unexpected legacy action dispatch during drawer close transition: \(action)")
            },
            shouldHandleSplitDragPayload: { _ in true },
            shouldAcceptDrop: { _, _, _, _ in false },
            handleDrop: { _, _, _, _ in }
        )
        let commandDispatcher = DrawerCloseTransitionCommandDispatcher(
            paneId: drawerPane.id
        ) {
            Task {
                do { try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: drawerPane.id)) } catch {
                    Issue.record(error)
                }
                closeActionFinished = true
                closeActionContinuation?.resume()
                closeActionContinuation = nil
            }
        }

        let leaf = PaneLeafContainer(
            paneHost: drawerHost,
            octiconLoader: makeTestOcticonLoader(),
            tabId: tab.id,
            isActive: true,
            isSplit: false,
            isSplitResizing: false,
            store: harness.store,
            repoCache: RepoCacheAtom(),
            editorChooser: EditorChooserState(),
            closeTransitionCoordinator: closeCoordinator,
            actionDispatcher: actionDispatcher,
            commandDispatcher: commandDispatcher,
            onPaneFocusTrigger: { _ in },
            onOpenPaneGitHub: { _ in },
            workspaceWindowId: nil,
            toolbarPresentation: .hidden
        )

        window.makeFirstResponder(drawerHost)

        leaf.beginCloseTransition()

        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(120))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closeActionFinished {
                continuation.resume()
            } else {
                closeActionContinuation = continuation
            }
        }

        #expect(harness.store.pane(parentPane.id)?.drawer?.paneIds.isEmpty == true)
        #expect(closeCoordinator.closingPaneIds.contains(drawerPane.id) == false)
        #expect(window.firstResponder !== drawerHost)
        #expect(window.firstResponder !== drawerMountedContent)
        #expect(PaneTabViewController.isNeutralResponderForRawCharacter(window.firstResponder))
    }
}

@MainActor
private final class DrawerCloseTransitionCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    private let paneId: UUID
    private let performClose: @MainActor () -> Void

    init(
        paneId: UUID,
        performClose: @escaping @MainActor () -> Void
    ) {
        self.paneId = paneId
        self.performClose = performClose
    }

    func dispatch(_: AppCommand) -> Bool { false }

    func dispatch(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) {
        guard canDispatch(command, target: target, targetType: targetType) else {
            return
        }
        performClose()
    }

    func canDispatch(_: AppCommand) -> Bool {
        false
    }

    func canDispatch(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) -> Bool {
        command == .closePane
            && target == paneId
            && targetType == .pane
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func dispatchMovePaneToTab(
        sourcePaneId _: UUID,
        sourceTabId _: UUID?,
        targetTabId _: UUID
    ) {}
}
