import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct TerminalPaneMountViewExitBehaviorTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }
    @MainActor
    private struct PaneTabControllerHarness {
        let store: WorkspaceStore
        let controller: PaneTabViewController
        let coordinator: WorkspaceSurfaceCoordinator
        let executor: WorkspaceActionExecutor
        let viewRegistry: ViewRegistry
        let surfaceManager: MockTerminalExitSurfaceManager
        let appEventBus: EventBus<AppEvent>
        let tempDir: URL

        func shutdown() async {
            controller.shutdown()
            await executor.stopAcceptingCommandsAndDrain()
            await coordinator.shutdown()
        }
    }

    @MainActor
    private struct ProcessExitEventHandlingResult {
        let receivedEvents: [AppEvent]
        let didHandleTermination: Bool
    }

    private final class WeakControllerBox {
        weak var value: PaneTabViewController?

        init(_ value: PaneTabViewController?) {
            self.value = value
        }
    }

    private func makePaneTabControllerHarness(
        appEventBus: EventBus<AppEvent> = EventBus<AppEvent>(),
        surfaceManager: MockTerminalExitSurfaceManager = MockTerminalExitSurfaceManager()
    ) -> PaneTabControllerHarness {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-terminal-exit-tests-\(UUID().uuidString)")
        let store: WorkspaceStore
        do {
            store = try makeWorkspaceJournalTestStore()
        } catch {
            preconditionFailure("Could not prepare the terminal-exit journal fixture: \(error)")
        }
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let appLifecycleStore = AppLifecycleAtom()
        let windowLifecycleStore = WindowLifecycleAtom()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: surfaceManager,
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: windowLifecycleStore
        )
        let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
        let applicationLifecycleMonitor = ApplicationLifecycleMonitor(
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore
        )
        let editorPreference = EditorPreferenceAtom()
        let editorChooserRuntime = EditorChooserRuntimeAtom()
        let editorChooser = EditorChooserState(
            preferenceAtom: editorPreference,
            runtimeAtom: editorChooserRuntime
        )
        let controller = PaneTabViewController(
            store: store,
            octiconLoader: makeTerminalTestOcticonLoader(),
            repoCache: RepoCacheAtom(),
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            appLifecycleStore: appLifecycleStore,
            executor: executor,
            runtimeCommandDispatcher: coordinator,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(), synchronizeRuntimeFocus: { _ in },
            tabBarAdapter: TabBarAdapter(
                store: store,
                repoCache: RepoCacheAtom(),
            ),
            viewRegistry: viewRegistry,
            bridgePaneAttendance: BridgePaneAttendanceAtom(),
            editorChooser: editorChooser,
            heldPanePreviewState: HeldPanePreviewState(),
            registersAsCommandHandler: false,
            appEventBus: appEventBus
        )
        return PaneTabControllerHarness(
            store: store,
            controller: controller,
            coordinator: coordinator,
            executor: executor,
            viewRegistry: viewRegistry,
            surfaceManager: surfaceManager,
            appEventBus: appEventBus,
            tempDir: tempDir
        )
    }

    private func waitForAppEventBusSubscriberCount(
        _ expectedCount: Int,
        on appEventBus: EventBus<AppEvent>
    ) async {
        for _ in 0..<1000 {
            if await appEventBus.subscriberCount == expectedCount {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for AppEventBus subscriberCount == \(expectedCount)")
    }

    private func makeSubscribedPaneTabControllerHarness() async -> PaneTabControllerHarness {
        let harness = makePaneTabControllerHarness()
        await waitForAppEventBusSubscriberCount(1, on: harness.appEventBus)
        return harness
    }

    private func waitForAppEventBusSubscriber(
        named subscriberName: String,
        on appEventBus: EventBus<AppEvent>,
        isPresent: Bool
    ) async {
        for _ in 0..<1000 {
            let activeSubscriberNames =
                await appEventBus
                .diagnosticsSnapshot()
                .activeSubscribers
                .map(\.subscriberName)
            if activeSubscriberNames.contains(subscriberName) == isPresent {
                return
            }
            await Task.yield()
        }
        Issue.record(
            "Timed out waiting for AppEventBus subscriber \(subscriberName) presence == \(isPresent)"
        )
    }

    private func makeProcessExitMountView(
        paneId: UUID = UUID(),
        surfaceId: UUID = UUIDv7.generate(),
        showsRestorePresentationDuringStartup: Bool = false,
        appEventBus: EventBus<AppEvent> = EventBus<AppEvent>(),
        terminationAcknowledgementClock: TestPushClock? = nil,
        surfaceManager: SurfaceManager? = nil
    ) -> TerminalPaneMountView {
        TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            restoredSurfaceId: surfaceId,
            paneId: paneId,
            title: "Terminal",
            showsRestorePresentationDuringStartup: showsRestorePresentationDuringStartup,
            appEventBus: appEventBus,
            terminationAcknowledgementClock: terminationAcknowledgementClock
        )
    }

    private func registerBareSurface(for pane: Pane, zmxSessionID: ZmxSessionID, manager: SurfaceManager) throws -> UUID
    {
        let surfaceId = UUIDv7.generate()
        let bareSurface = Ghostty.SurfaceView(
            managedSurfaceID: surfaceId,
            appCommandDispatcher: AppTerminalFixtureCommandDispatcher()
        )
        _ = try manager.acceptCreatedSurface(
            bareSurface,
            metadata: SurfaceMetadata(paneId: pane.id, zmxSessionID: zmxSessionID)
        ).get()
        _ = manager.attach(surfaceId, to: pane.id)
        return surfaceId
    }

    private func makeProcessExitEventHandlerTask(
        paneId: UUID,
        sentinelPaneId: UUID,
        harness: PaneTabControllerHarness,
        appEventBus: EventBus<AppEvent>,
        eventStream: EventBusSubscription<AppEvent>
    ) -> Task<ProcessExitEventHandlingResult, Never> {
        Task { @MainActor in
            var receivedEvents: [AppEvent] = []
            var didHandleTermination = false
            for await event in eventStream {
                receivedEvents.append(event)
                if case .terminalProcessTerminated(let terminatedPaneId) = event,
                    terminatedPaneId == paneId
                {
                    didHandleTermination = harness.controller.handleTerminalProcessTerminated(paneId: paneId)
                    await harness.executor.stopAcceptingCommandsAndDrain()
                    await appEventBus.post(.terminalProcessTerminationHandled(paneId: paneId))
                }
                if case .worktreeBellRang(let observedSentinelPaneId) = event,
                    observedSentinelPaneId == sentinelPaneId
                {
                    return ProcessExitEventHandlingResult(
                        receivedEvents: receivedEvents,
                        didHandleTermination: didHandleTermination
                    )
                }
            }
            return ProcessExitEventHandlingResult(
                receivedEvents: receivedEvents,
                didHandleTermination: didHandleTermination
            )
        }
    }

    private func events(
        through sentinelPaneId: UUID,
        from stream: EventBusSubscription<AppEvent>
    ) async -> [AppEvent] {
        var receivedEvents: [AppEvent] = []
        for await event in stream {
            receivedEvents.append(event)
            if case .worktreeBellRang(let paneId) = event, paneId == sentinelPaneId {
                return receivedEvents
            }
        }
        return receivedEvents
    }

    private func simulateGhosttyCloseCallback(
        processExited: Bool,
        on mountView: TerminalPaneMountView
    ) -> Task<Void, Never>? {
        mountView.simulateSurfaceCloseForTesting(processExited: processExited)
    }

    private func makeSubscribedPaneId(in store: WorkspaceStore) -> UUID {
        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/\(UUID().uuidString)")!)),
            metadata: PaneMetadata(title: "Terminal")
        )
        store.appendTab(Tab(paneId: pane.id))
        return pane.id
    }

    @Test("Ghostty close callback while running does not dispatch pane close")
    func ghosttyCloseCallbackWhileRunning_doesNotClosePane() async {
        let store = WorkspaceStore()
        let paneId = makeSubscribedPaneId(in: store)
        let tabId = store.tabs[0].id
        let appEventBus = EventBus<AppEvent>()
        let eventRecorder = await appEventBus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "TerminalPaneMountViewExitBehaviorTests.liveCloseRecorder"
        )
        let mountView = makeProcessExitMountView(
            paneId: paneId,
            appEventBus: appEventBus
        )

        // fire-and-forget: a running-process close callback starts no termination task.
        _ = simulateGhosttyCloseCallback(processExited: false, on: mountView)

        let sentinelPaneId = UUIDv7.generate()
        await appEventBus.post(.worktreeBellRang(paneId: sentinelPaneId))
        let receivedEvents = await events(through: sentinelPaneId, from: eventRecorder)

        #expect(
            !receivedEvents.contains { event in
                if case .terminalProcessTerminated = event { return true }
                return false
            })
        #expect(store.tabLayoutAtom.tab(tabId) != nil)
        #expect(store.paneAtom.pane(paneId) != nil)
        #expect(mountView.isProcessRunning)
        #expect(!mountView.isShowingErrorOverlayForTesting)

    }

    @Test(
        "process exit closes the pane and Undo Close requests a fresh zmx surface",
        arguments: [false, true]
    )
    func ghosttyProcessExitClosesTerminalPaneAndUndoRestoresIt(
        showsRestorePresentationDuringStartup: Bool
    ) async throws {
        let controllerEventBus = EventBus<AppEvent>()
        let manager = makeAppTerminalFixtureSurfaceManager()
        let surfaceManager = MockTerminalExitSurfaceManager(delegatingTo: manager)
        let harness = makePaneTabControllerHarness(
            appEventBus: controllerEventBus,
            surfaceManager: surfaceManager
        )
        try FileManager.default.createDirectory(at: harness.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            title: "Exited zmx terminal",
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        let zmxSessionID = try #require(pane.terminalState?.zmxSessionID)
        let surfaceId = try registerBareSurface(for: pane, zmxSessionID: zmxSessionID, manager: manager)
        defer {
            if manager.hasNativeAttachments(for: zmxSessionID) {
                manager.destroy(surfaceId)
            }
        }

        let appEventBus = EventBus<AppEvent>()
        let eventStream = await appEventBus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "TerminalPaneMountViewExitBehaviorTests.processExitCloseHandler"
        )
        let sentinelPaneId = UUIDv7.generate()
        let eventHandlerTask = makeProcessExitEventHandlerTask(
            paneId: pane.id,
            sentinelPaneId: sentinelPaneId,
            harness: harness,
            appEventBus: appEventBus,
            eventStream: eventStream
        )

        let mountView = makeProcessExitMountView(
            paneId: pane.id,
            surfaceId: surfaceId,
            showsRestorePresentationDuringStartup: showsRestorePresentationDuringStartup,
            appEventBus: appEventBus, surfaceManager: manager
        )
        if showsRestorePresentationDuringStartup {
            mountView.beginRestorePresentationForTesting()
            #expect(mountView.isShowingStartupOverlayForTesting)
        }

        let terminationTask = simulateGhosttyCloseCallback(processExited: true, on: mountView)
        guard let terminationTask else {
            Issue.record("An exited process must start pane termination handling")
            await harness.shutdown()
            return
        }
        mountView.applyHealthUpdateForTesting(.processExited(exitCode: nil))
        await terminationTask.value
        await appEventBus.post(.worktreeBellRang(paneId: sentinelPaneId))
        let eventHandling = await eventHandlerTask.value

        #expect(eventHandling.didHandleTermination)
        #expect(
            eventHandling.receivedEvents.contains { event in
                if case .terminalProcessTerminated(let terminatedPaneId) = event {
                    return terminatedPaneId == pane.id
                }
                return false
            }
        )
        #expect(harness.store.tabLayoutAtom.tab(tab.id) == nil)
        #expect(harness.store.paneAtom.pane(pane.id) == nil)
        #expect(harness.executor.undoStack.count == 1)
        #expect(manager.hasNativeAttachments(for: zmxSessionID))
        #expect(!mountView.isProcessRunning)
        #expect(mountView.isProcessExitedOverlaySuppressedAfterTerminationForTesting)
        #expect(!mountView.isShowingErrorOverlayForTesting)
        #expect(!mountView.isShowingStartupOverlayForTesting)

        harness.coordinator.sessionConfig = SessionConfiguration(
            isEnabled: true,
            zmxPath: "/usr/bin/zmx",
            zmxDir: harness.tempDir.path,
            healthCheckInterval: 30,
            maxCheckpointAge: 86_400
        )
        harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        #expect(try await harness.coordinator.undoCloseTab())
        let restoredPane = harness.store.paneAtom.pane(pane.id)
        #expect(restoredPane?.terminalState?.zmxSessionID == zmxSessionID)
        #expect(harness.viewRegistry.terminalView(for: pane.id) != nil)
        #expect(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id) != nil)
        #expect(!manager.hasNativeAttachments(for: zmxSessionID))
        let surfaceCreation = try #require(harness.surfaceManager.surfaceCreationRequests.last)
        #expect(surfaceCreation.metadata.zmxSessionID == zmxSessionID)
        #expect(
            surfaceCreation.configuration.startupStrategy.startupCommandForSurface?.contains(zmxSessionID.rawValue)
                == true
        )
        await harness.shutdown()
    }

    @Test("undelivered process termination shows the Process Exited fallback")
    func ghosttyProcessExit_withoutHandler_showsProcessExitedFallback() async {
        let mountView = makeProcessExitMountView()

        let terminationTask = mountView.simulateSurfaceCloseForTesting(processExited: true)
        guard let terminationTask else {
            Issue.record("An exited process must start pane termination handling")
            return
        }
        await terminationTask.value
        #expect(mountView.isProcessRunning == false)
        #expect(!mountView.hasObservedEffectiveTerminationDeliveryForTesting)
        #expect(!mountView.isProcessExitedOverlaySuppressedAfterTerminationForTesting)
        #expect(mountView.isShowingErrorOverlayForTesting)
    }

    @Test("unhealthy overlay close dispatches closePane directly for its pane")
    func unhealthyOverlayCloseDispatchesPaneClose() async throws {
        let harness = makePaneTabControllerHarness()
        let paneId = makeSubscribedPaneId(in: harness.store)
        let tabId = try #require(harness.store.tabLayoutAtom.tabContaining(paneId: paneId)?.id)
        var submittedActions: [WorkspaceActionCommand] = []
        harness.coordinator.workspaceActionSubmission = { action in
            submittedActions.append(action)
        }

        let mountView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(),
            paneId: paneId,
            title: "Terminal",
            appEventBus: EventBus<AppEvent>()
        )
        _ = harness.coordinator.registerHostedView(mountedView: mountView, for: paneId)
        mountView.applyHealthUpdateForTesting(.dead)
        try #require(mountView.errorOverlay).onDismiss?()

        #expect(submittedActions == [.closePane(tabId: tabId, paneId: paneId)])
        await harness.shutdown()
    }

    @Test("fatal terminal errors still show the error overlay during startup restore")
    func fatalTerminalError_stillShowsErrorOverlayDuringStartupRestore() {
        let mountView = makeProcessExitMountView(showsRestorePresentationDuringStartup: true)

        mountView.beginRestorePresentationForTesting()
        #expect(mountView.isShowingStartupOverlayForTesting)

        mountView.applyHealthUpdateForTesting(.dead)

        #expect(mountView.isShowingErrorOverlayForTesting)
    }

    @Test("terminal process termination delivered through AppEventBus closes a single-pane tab")
    func terminalProcessTermination_deliveredThroughAppEventBus_closesSinglePaneTab() async {
        let harness = makePaneTabControllerHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/\(UUID().uuidString)")!)),
            metadata: PaneMetadata(title: "Solo")
        )
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)

        await waitForAppEventBusSubscriberCount(1, on: harness.appEventBus)
        await harness.appEventBus.post(.terminalProcessTerminated(paneId: pane.id))

        await eventually("single-pane tab should close after AppEventBus delivery") {
            harness.store.tabs.isEmpty
        }
        await harness.shutdown()
    }

    @Test("terminal process termination delivered through AppEventBus closes drawer children")
    func terminalProcessTermination_deliveredThroughAppEventBus_closesDrawerChild() async {
        let harness = makePaneTabControllerHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let parentPane = harness.store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/\(UUID().uuidString)")!)),
            metadata: PaneMetadata(title: "Parent")
        )
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        guard
            let drawerPane = harness.store.addDrawerPane(
                to: parentPane.id,
                parentFallbackCWD: FileManager.default.homeDirectoryForCurrentUser
            )
        else {
            Issue.record("Expected drawer pane creation to succeed")
            await harness.shutdown()
            return
        }

        await waitForAppEventBusSubscriberCount(1, on: harness.appEventBus)
        await harness.appEventBus.post(.terminalProcessTerminated(paneId: drawerPane.id))

        await eventually("drawer child should close after AppEventBus delivery") {
            harness.store.pane(drawerPane.id) == nil
        }
        #expect(harness.store.pane(parentPane.id) != nil)
        await harness.shutdown()
    }

    @Test("terminal termination delivered through AppEventBus removes minimized panes from the active arrangement")
    func terminalProcessTermination_deliveredThroughAppEventBus_removesMinimizedOwnedPane() async {
        let harness = makePaneTabControllerHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let paneA = harness.store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/a-\(UUID().uuidString)")!)),
            metadata: PaneMetadata(title: "A")
        )
        let paneB = harness.store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/b-\(UUID().uuidString)")!)),
            metadata: PaneMetadata(title: "B")
        )
        let minimizedPane = harness.store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/c-\(UUID().uuidString)")!)),
            metadata: PaneMetadata(title: "Minimized")
        )

        let tab = Tab(paneId: paneA.id)
        harness.store.appendTab(tab)
        harness.store.insertPane(
            paneB.id, inTab: tab.id, at: paneA.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)
        harness.store.insertPane(
            minimizedPane.id, inTab: tab.id, at: paneB.id, direction: .horizontal, position: .after,
            sizingMode: .halveTarget)
        guard harness.store.minimizePane(minimizedPane.id, inTab: tab.id) else {
            Issue.record("Expected pane minimization to succeed")
            await harness.shutdown()
            return
        }
        #expect(harness.store.tab(tab.id)?.panes.contains(minimizedPane.id) == true)
        #expect(harness.store.tab(tab.id)?.activeMinimizedPaneIds.contains(minimizedPane.id) == true)

        await waitForAppEventBusSubscriberCount(1, on: harness.appEventBus)
        await harness.appEventBus.post(.terminalProcessTerminated(paneId: minimizedPane.id))

        await eventually("minimized owned pane should be removed without closing the whole tab") {
            harness.store.pane(minimizedPane.id) == nil
        }
        #expect(harness.store.tab(tab.id) != nil)
        #expect(harness.store.tab(tab.id)?.panes.contains(minimizedPane.id) == false)
        #expect(Set(harness.store.tab(tab.id)?.paneIds ?? []) == Set([paneA.id, paneB.id]))
        await harness.shutdown()
    }

    @Test("process exit waits for its matching acknowledgment and drains the timeout")
    func terminationWaitsForMatchingAcknowledgment() async {
        let clock = TestPushClock()
        let appEventBus = EventBus<AppEvent>()
        let terminationConsumer = await appEventBus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "TerminalPaneMountViewExitBehaviorTests.terminationConsumer"
        )
        var terminationEvents = terminationConsumer.makeAsyncIterator()
        let mountView = makeProcessExitMountView(
            appEventBus: appEventBus,
            terminationAcknowledgementClock: clock
        )
        let terminationTask = mountView.simulateSurfaceCloseForTesting(processExited: true)
        guard let terminationTask else {
            Issue.record("An exited process must start pane termination handling")
            return
        }
        let terminationEvent = await terminationEvents.next()
        #expect(
            terminationEvent.map { event in
                if case .terminalProcessTerminated(let paneId) = event {
                    return paneId == mountView.paneId
                }
                return false
            } == true
        )
        await clock.waitForPendingSleepCount(atLeast: 1)
        #expect(mountView.isProcessExitedOverlaySuppressedAfterTerminationForTesting)
        #expect(!mountView.hasObservedEffectiveTerminationDeliveryForTesting)

        await appEventBus.post(.terminalProcessTerminationHandled(paneId: UUIDv7.generate()))
        await appEventBus.post(.terminalProcessTerminationHandled(paneId: mountView.paneId))
        await terminationTask.value

        #expect(mountView.hasObservedEffectiveTerminationDeliveryForTesting)
        #expect(!mountView.isShowingErrorOverlayForTesting)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test("controller subscribes before view load and unregisters on teardown")
    func controller_subscribesBeforeViewLoad_andUnregistersOnTeardown() async {
        var harness: PaneTabControllerHarness? = makePaneTabControllerHarness()
        let tempDir = harness?.tempDir
        let weakController = WeakControllerBox(harness?.controller)

        let appEventBus = harness?.appEventBus
        if let appEventBus {
            await waitForAppEventBusSubscriberCount(1, on: appEventBus)
        }
        #expect(weakController.value != nil)

        harness = nil

        await eventually("controller should deallocate after teardown") {
            weakController.value == nil
        }
        if let appEventBus {
            await waitForAppEventBusSubscriberCount(0, on: appEventBus)
        }

        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }
}

@MainActor
private final class MockTerminalExitSurfaceManager: WorkspaceSurfaceManaging {
    private let delegatedSurfaceManager: SurfaceManager?
    private(set) var surfaceCreationRequests:
        [(
            configuration: Ghostty.SurfaceConfiguration,
            metadata: SurfaceMetadata
        )] = []

    init(delegatingTo surfaceManager: SurfaceManager? = nil) {
        delegatedSurfaceManager = surfaceManager
    }

    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {
        delegatedSurfaceManager?.retainSurfacesForUndo(forPaneIDs: paneIDs)
    }

    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {
        delegatedSurfaceManager?.retireActiveAndHiddenSurfaces(forPaneIDs: paneIDs)
    }

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {
        delegatedSurfaceManager?.releaseUndoSurfaces(forPaneIDs: paneIDs)
    }

    func syncFocus(activeSurfaceId surfaceId: UUID?) {
        delegatedSurfaceManager?.syncFocus(activeSurfaceId: surfaceId)
    }

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        surfaceCreationRequests.append((configuration: config, metadata: metadata))
        return .failure(.ghosttyNotInitialized)
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        delegatedSurfaceManager?.attach(surfaceId, to: paneId)
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        delegatedSurfaceManager?.detach(surfaceId, reason: reason)
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? {
        delegatedSurfaceManager?.undoClose(forPaneId: paneId)
    }

    func destroy(_ surfaceId: UUID) {
        delegatedSurfaceManager?.destroy(surfaceId)
    }
}
