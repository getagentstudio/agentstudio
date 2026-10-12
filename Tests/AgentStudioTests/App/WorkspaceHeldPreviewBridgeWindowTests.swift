import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.WorkspaceHeldPreviewBridgeAdmissionTests {
    private struct BridgePreviewWorkspace {
        let bridgePane: Pane
        let bridgeTab: Tab
        let canonicalPane: Pane
        let canonicalTab: Tab
        let previousActiveTabID: UUID?
        let store: WorkspaceStore
    }

    @MainActor
    private struct BridgePreviewWindowFixture {
        let bridgeHost: PaneHostView
        let bridgeMount: BridgePaneMountView
        let controller: BridgePaneController
        let coordinator: WorkspaceSurfaceCoordinator
        let heldState: HeldPanePreviewState
        let paneTabController: PaneTabViewController
        let viewRegistry: ViewRegistry
        let window: NSWindow
        let workspace: BridgePreviewWorkspace

        func finish() async {
            paneTabController.shutdown()
            await coordinator.shutdown()
            window.orderOut(nil)
            window.close()
            workspace.store.removePane(workspace.bridgePane.id)
            workspace.store.removePane(workspace.canonicalPane.id)
            workspace.store.setActiveTab(workspace.previousActiveTabID)
        }
    }

    @Test("cancelling a displayed Bridge Files preview restores the canonical host")
    func heldBridgePreviewCancellationRestoresCanonicalHost() async throws {
        let repoURL = try await FilesystemTestGitRepo.create(
            named: "held-bridge-preview-cancellation"
        )
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repoURL)
        let fixture = try await makeBridgePreviewWindowFixture(repoURL: repoURL)
        do {
            try await assertBridgePreviewCancellationRestoresCanonicalHost(fixture)
        } catch {
            await fixture.finish()
            throw error
        }
        await fixture.finish()
    }

    private func makeBridgePreviewWorkspace(
        controller: BridgePaneController,
        coreAtoms: CoreAtoms
    ) throws -> BridgePreviewWorkspace {
        let store = WorkspaceStore(
            identityAtom: coreAtoms.workspaceIdentity,
            windowMemoryAtom: coreAtoms.workspaceWindowMemory,
            repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
            paneAtom: coreAtoms.workspacePane,
            tabLayoutAtom: coreAtoms.workspaceTabLayout,
            mutationCoordinator: coreAtoms.workspaceMutationCoordinator,
            startsObserving: false
        )
        let previousActiveTabID = store.tabLayoutAtom.activeTabId
        let bridgePane = Pane(
            id: controller.paneId,
            content: .bridgePanel(controller.bridgePaneState),
            metadata: controller.runtime.metadata
        )
        try #require(store.paneAtom.insertRestoredPane(bridgePane))
        let canonicalPane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com")!)),
            metadata: PaneMetadata(title: "Canonical pane")
        )
        var admissionCompleted = false
        defer {
            if !admissionCompleted {
                store.removePane(bridgePane.id)
                store.removePane(canonicalPane.id)
                store.setActiveTab(previousActiveTabID)
            }
        }
        let canonicalTab = Tab(paneId: canonicalPane.id, name: "Workspace")
        let bridgeTab = Tab(paneId: bridgePane.id, name: "Bridge Files")
        store.appendTab(canonicalTab)
        store.appendTab(bridgeTab)
        store.setActiveTab(canonicalTab.id)

        try #require(store.paneAtom === coreAtoms.workspacePane)
        try #require(store.tabLayoutAtom === coreAtoms.workspaceTabLayout)
        let arrangementView = atom(\.arrangementView)
        try #require(
            arrangementView.activeVisiblePaneIds(forTab: canonicalTab.id)
                .contains(canonicalPane.id)
        )
        try #require(
            arrangementView.activeVisiblePaneIds(forTab: bridgeTab.id)
                .contains(bridgePane.id)
        )
        admissionCompleted = true
        return BridgePreviewWorkspace(
            bridgePane: bridgePane,
            bridgeTab: bridgeTab,
            canonicalPane: canonicalPane,
            canonicalTab: canonicalTab,
            previousActiveTabID: previousActiveTabID,
            store: store
        )
    }

    private func makeBridgePreviewWindowFixture(repoURL: URL) async throws -> BridgePreviewWindowFixture {
        let coreAtoms = CoreAtomScope.store
        let atomRegistry = AtomRegistry(core: coreAtoms)
        let controller = WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests()
            .makeController(
                repoURL: repoURL,
                traceRecorder: BridgeProductWebKitCarrierTraceRecorder()
            )
        let workspace: BridgePreviewWorkspace
        do {
            workspace = try makeBridgePreviewWorkspace(
                controller: controller,
                coreAtoms: coreAtoms
            )
        } catch {
            _ = await controller.beginTeardown().value
            throw error
        }
        let viewRegistry = ViewRegistry()
        let canonicalHost = PaneHostView(paneId: workspace.canonicalPane.id)
        viewRegistry.register(canonicalHost, for: workspace.canonicalPane.id)
        let heldState = HeldPanePreviewState()
        let appLifecycleStore = AppLifecycleAtom()
        let windowLifecycleStore = WindowLifecycleAtom()
        let owningWindowID = UUIDv7.generate()
        appLifecycleStore.setActive(true)
        windowLifecycleStore.recordWindowRegistered(owningWindowID)
        windowLifecycleStore.recordWindowPresentation(
            WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
            for: owningWindowID
        )
        windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: 960, height: 720)
        )
        let coordinator = WorkspaceSurfaceCoordinator(
            store: workspace.store,
            viewRegistry: viewRegistry,
            runtime: SessionRuntime(store: workspace.store),
            surfaceManager: BridgeActivityIntegrationSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: makeTestPaneRuntimeEventBus(),
            windowLifecycleStore: windowLifecycleStore,
            appLifecycleStore: appLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: atomRegistry.bridgePaneAttendance
        )
        coordinator.bindHeldPanePreviewState(heldState)
        let bridgeMount = BridgePaneMountView(paneId: workspace.bridgePane.id, controller: controller)
        let bridgeHost = coordinator.registerHostedView(
            mountedView: bridgeMount,
            for: workspace.bridgePane.id
        )
        let repoCache = coreAtoms.repoCache
        let paneTabController = PaneTabViewController(
            store: workspace.store,
            octiconLoader: makeTestOcticonLoader(),
            repoCache: repoCache,
            applicationLifecycleMonitor: ApplicationLifecycleMonitor(
                appLifecycleStore: appLifecycleStore,
                windowLifecycleStore: windowLifecycleStore
            ),
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore,
            workspaceWindowId: owningWindowID,
            executor: WorkspaceActionExecutor(coordinator: coordinator, store: workspace.store),
            runtimeCommandDispatcher: coordinator,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(), synchronizeRuntimeFocus: { _ in },
            tabBarAdapter: TabBarAdapter(store: workspace.store, repoCache: repoCache),
            viewRegistry: viewRegistry,
            bridgePaneAttendance: atomRegistry.bridgePaneAttendance,
            editorChooser: atomRegistry.editorChooser,
            heldPanePreviewState: heldState,
            registersAsCommandHandler: false
        )
        let window = makeOrderedPreviewWindow(paneTabController: paneTabController)
        let fixture = BridgePreviewWindowFixture(
            bridgeHost: bridgeHost,
            bridgeMount: bridgeMount,
            controller: controller,
            coordinator: coordinator,
            heldState: heldState,
            paneTabController: paneTabController,
            viewRegistry: viewRegistry,
            window: window,
            workspace: workspace
        )
        do {
            try requireCanonicalWindowMounted(fixture, canonicalHost: canonicalHost)
        } catch {
            await fixture.finish()
            throw error
        }
        return fixture
    }

    private func requireCanonicalWindowMounted(
        _ fixture: BridgePreviewWindowFixture,
        canonicalHost: PaneHostView
    ) throws {
        let window = fixture.window
        let paneTabController = fixture.paneTabController
        let workspace = fixture.workspace
        let viewRegistry = fixture.viewRegistry
        try #require(window.contentViewController === paneTabController)
        try #require(paneTabController.view.window === window)
        try #require(workspace.store.tabLayoutAtom.activeTabId == workspace.canonicalTab.id)
        try #require(viewRegistry.view(for: workspace.canonicalPane.id) === canonicalHost)
        let canonicalTabHost = try #require(
            paneTabController.tabHostViewForTesting(tabId: workspace.canonicalTab.id)
        )
        try #require(canonicalTabHost.window === window)
        try #require(!canonicalTabHost.isHiddenOrHasHiddenAncestor)
        try #require(canonicalTabHost.bounds.width > 0)
        try #require(canonicalHost.window === window)
    }

    private func makeOrderedPreviewWindow(paneTabController: PaneTabViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentViewController = paneTabController
        window.setContentSize(CGSize(width: 960, height: 720))
        window.makeKeyAndOrderFront(nil)
        paneTabController.viewWillLayout()
        paneTabController.view.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func assertBridgePreviewCancellationRestoresCanonicalHost(
        _ fixture: BridgePreviewWindowFixture
    ) async throws {
        let controller = fixture.controller
        controller.loadApp()
        await WebPageEventWaits.waitForBridgeReady(controller)
        try await WebPageEventWaits.waitForDocumentSelector(
            controller.page,
            "[data-testid='bridge-viewer-context-file']"
        )
        try #require(await BridgeProductWebKitCarrierTestSupport.activateFileMode(controller.page))
        let target = ValidatedPanePreviewTarget(
            paneID: fixture.workspace.bridgePane.id,
            owningTabID: fixture.workspace.bridgeTab.id,
            provider: fixture.workspace.bridgePane.provider,
            sessionID: fixture.workspace.bridgePane.terminalState?.zmxSessionID
        )
        try #require(fixture.heldState.beginSpaceHold(requestedTarget: target))
        // fire-and-forget: the test asserts the synchronous preparation this starts
        _ = fixture.coordinator.beginHeldPanePreviewPreparation()
        try #require(fixture.heldState.presentedTarget == target)
        fixture.paneTabController.viewWillLayout()
        fixture.paneTabController.view.layoutSubtreeIfNeeded()
        try #require(fixture.bridgeHost.window === fixture.window)
        try #require(fixture.bridgeMount.controller === controller)
        try #require(
            fixture.paneTabController.tabHostViewForTesting(tabId: fixture.workspace.bridgeTab.id)?
                .isHidden == false
        )
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const fileHost = document.querySelector(
                  '[data-bridge-viewer-mode-host="file"][data-bridge-viewer-mode-active="true"]'
                );
                const fileShell = fileHost?.querySelector('[data-testid="bridge-file-viewer-shell"]');
                return fileShell?.getAttribute('data-file-display-status') === 'ready'
                  && Number(fileShell.getAttribute('data-file-display-item-count')) > 0
                  ? true : null;
                """
        )

        fixture.heldState.cancelIfHeld()
        fixture.paneTabController.viewWillLayout()
        fixture.paneTabController.view.layoutSubtreeIfNeeded()
        try #require(fixture.heldState.presentedTarget == nil)
        try #require(
            fixture.paneTabController.tabHostViewForTesting(tabId: fixture.workspace.canonicalTab.id)?
                .isHidden == false
        )
        try #require(
            fixture.paneTabController.tabHostViewForTesting(tabId: fixture.workspace.bridgeTab.id)?
                .isHidden == true
        )
        try #require(fixture.viewRegistry.view(for: fixture.workspace.bridgePane.id) === fixture.bridgeHost)
        try #require(fixture.viewRegistry.allBridgeViews[fixture.workspace.bridgePane.id] === fixture.bridgeMount)
        let pageResponse = try await controller.page.callJavaScript("return 1 + 1;")
        try #require((pageResponse as? NSNumber)?.intValue == 2)

        try #require(fixture.heldState.beginSpaceHold(requestedTarget: target))
        // fire-and-forget: the test asserts the synchronous preparation this starts
        _ = fixture.coordinator.beginHeldPanePreviewPreparation()
        fixture.paneTabController.viewWillLayout()
        fixture.paneTabController.view.layoutSubtreeIfNeeded()
        try #require(fixture.heldState.presentedTarget == target)
        try #require(fixture.bridgeHost.window === fixture.window)
        try #require(
            fixture.paneTabController.tabHostViewForTesting(tabId: fixture.workspace.bridgeTab.id)?
                .isHidden == false
        )
        let repeatedPageResponse = try await controller.page.callJavaScript("return 2 + 2;")
        try #require((repeatedPageResponse as? NSNumber)?.intValue == 4)
        fixture.heldState.cancelIfHeld()
        fixture.paneTabController.viewWillLayout()
        fixture.paneTabController.view.layoutSubtreeIfNeeded()
        try #require(
            fixture.paneTabController.tabHostViewForTesting(tabId: fixture.workspace.canonicalTab.id)?
                .isHidden == false
        )
        try #require(fixture.viewRegistry.allBridgeViews[fixture.workspace.bridgePane.id] === fixture.bridgeMount)
        let restoredPageResponse = try await controller.page.callJavaScript("return 3 + 3;")
        try #require((restoredPageResponse as? NSNumber)?.intValue == 6)
    }
}
