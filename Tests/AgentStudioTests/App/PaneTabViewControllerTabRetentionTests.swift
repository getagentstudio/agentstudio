import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneTabViewControllerTabRetentionTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }
    private struct Harness {
        let store: WorkspaceStore
        let viewRegistry: ViewRegistry
        let controller: PaneTabViewController
        let windowLifecycleStore: WindowLifecycleAtom
        let window: NSWindow
        let tempDir: URL
    }

    private func makeHarness() -> Harness {
        let atomRegistry = AtomRegistry(core: CoreAtomScope.store)
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-tab-retention-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let appLifecycleStore = AppLifecycleAtom()
        let windowLifecycleStore = WindowLifecycleAtom()
        let applicationLifecycleMonitor = ApplicationLifecycleMonitor(
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore
        )
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: MockPersistentTabSurfaceManager(),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: windowLifecycleStore
        )
        let controller = PaneTabViewController(
            store: store,
            octiconLoader: makeTestOcticonLoader(),
            repoCache: RepoCacheAtom(),
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            appLifecycleStore: appLifecycleStore,
            executor: WorkspaceActionExecutor(coordinator: coordinator, store: store),
            runtimeCommandDispatcher: coordinator,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(), synchronizeRuntimeFocus: { _ in },
            tabBarAdapter: TabBarAdapter(
                store: store,
                repoCache: RepoCacheAtom(),
            ),
            viewRegistry: viewRegistry,
            bridgePaneAttendance: atomRegistry.bridgePaneAttendance,
            editorChooser: atomRegistry.editorChooser,
            heldPanePreviewState: HeldPanePreviewState(),
            registersAsCommandHandler: false
        )
        PaneViewRepresentable.onDismantleForTesting = { [weak controller] in
            controller?.recordPaneRepresentableDismantleForTesting()
        }
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1200, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return Harness(
            store: store,
            viewRegistry: viewRegistry,
            controller: controller,
            windowLifecycleStore: windowLifecycleStore,
            window: window,
            tempDir: tempDir
        )
    }

    private func registerPaneHost(_ paneId: UUID, in harness: Harness) {
        harness.viewRegistry.register(PaneHostView(paneId: paneId), for: paneId)
    }

    private func registerAttachedPaneHost(_ paneId: UUID, in harness: Harness) throws {
        let host = PaneHostView(paneId: paneId)
        harness.viewRegistry.register(host, for: paneId)
        let contentView = try #require(harness.window.contentView)
        host.frame = contentView.bounds
        contentView.addSubview(host)
    }

    @Test("registering a tab host seeds its pane slots before SwiftUI can render")
    func registeringTabHostSeedsPaneSlotsBeforeRender() {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "New tab")
        harness.store.appendTab(tab)

        harness.controller.viewWillLayout()

        #expect(harness.viewRegistry.slotPaneIdsForTesting.contains(pane.id))
    }

    @Test
    func inactivePersistentTab_allowsMissingHostUntilSelected() throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let activePane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let inactivePane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let activeTab = Tab(paneId: activePane.id, name: "Active")
        let inactiveTab = Tab(paneId: inactivePane.id, name: "Inactive")
        harness.store.appendTab(activeTab)
        harness.store.appendTab(inactiveTab)
        registerPaneHost(activePane.id, in: harness)
        harness.viewRegistry.ensureSlot(for: inactivePane.id)

        harness.store.setActiveTab(activeTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        let inactiveTabHost = try #require(harness.controller.tabHostViewForTesting(tabId: inactiveTab.id))
        #expect(inactiveTabHost.isHidden)
        #expect(harness.viewRegistry.view(for: inactivePane.id) == nil)
    }

    @Test
    func selectingInactivePersistentTab_restoresMissingHostBeforeVisibleRender() throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let activePane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let inactivePane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let activeTab = Tab(paneId: activePane.id, name: "Active")
        let inactiveTab = Tab(paneId: inactivePane.id, name: "Inactive")
        harness.store.appendTab(activeTab)
        harness.store.appendTab(inactiveTab)
        registerPaneHost(activePane.id, in: harness)
        harness.viewRegistry.ensureSlot(for: inactivePane.id)
        harness.windowLifecycleStore.recordTerminalContainerBounds(
            NSRect(x: 0, y: 0, width: 1000, height: 700)
        )
        harness.windowLifecycleStore.recordLaunchLayoutSettled()
        harness.store.setActiveTab(activeTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        #expect(harness.viewRegistry.view(for: inactivePane.id) == nil)

        harness.controller.selectTab(at: 1)

        #expect(harness.store.activeTabId == inactiveTab.id)
        #expect(harness.viewRegistry.view(for: inactivePane.id) != nil)
    }

    @Test
    func switchingTabs_reusesPersistentHosts() throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let firstPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let secondPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let firstTab = Tab(paneId: firstPane.id, name: "First")
        let secondTab = Tab(paneId: secondPane.id, name: "Second")
        harness.store.appendTab(firstTab)
        harness.store.appendTab(secondTab)
        registerPaneHost(firstPane.id, in: harness)
        registerPaneHost(secondPane.id, in: harness)
        harness.store.setActiveTab(firstTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        let firstHost = try #require(harness.controller.tabHostViewForTesting(tabId: firstTab.id))

        harness.store.setActiveTab(secondTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()
        let secondHost = try #require(harness.controller.tabHostViewForTesting(tabId: secondTab.id))
        #expect(firstHost.isHidden)
        #expect(secondHost.isHidden == false)

        harness.store.setActiveTab(firstTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()
        let firstHostAfterRoundTrip = try #require(
            harness.controller.tabHostViewForTesting(tabId: firstTab.id)
        )

        #expect(firstHostAfterRoundTrip === firstHost)
        #expect(secondHost !== firstHost)
        #expect(firstHostAfterRoundTrip.isHidden == false)
        #expect(secondHost.isHidden)
    }

    @Test
    func selectingTabViaCommand_focusesTheTargetTabPane() async throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let firstPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let secondPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let firstTab = Tab(paneId: firstPane.id, name: "First")
        let secondTab = Tab(paneId: secondPane.id, name: "Second")
        harness.store.appendTab(firstTab)
        harness.store.appendTab(secondTab)
        try registerAttachedPaneHost(firstPane.id, in: harness)
        try registerAttachedPaneHost(secondPane.id, in: harness)
        harness.store.setActiveTab(firstTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        harness.controller.selectTab(at: 1)
        harness.controller.view.layoutSubtreeIfNeeded()

        let secondHost = try #require(harness.viewRegistry.view(for: secondPane.id))
        await eventually("command tab selection should refocus the target pane") {
            harness.window.firstResponder === secondHost
        }
        #expect(harness.store.activeTabId == secondTab.id)
        #expect(harness.window.firstResponder === secondHost)
    }

    @Test
    func selectingTabViaCommand_restoresExpandedDrawerPaneFocus() async throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let parentPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let otherPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let parentTab = Tab(paneId: parentPane.id, name: "Parent")
        let otherTab = Tab(paneId: otherPane.id, name: "Other")
        harness.store.appendTab(parentTab)
        harness.store.appendTab(otherTab)
        let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
        try registerAttachedPaneHost(parentPane.id, in: harness)
        try registerAttachedPaneHost(drawerPane.id, in: harness)
        try registerAttachedPaneHost(otherPane.id, in: harness)
        harness.store.setActiveTab(parentTab.id)
        harness.store.setActivePane(parentPane.id, inTab: parentTab.id)
        harness.controller.handlePaneFocusTrigger(
            .drawer(.selectPane(parentPaneId: parentPane.id, drawerPaneId: drawerPane.id)))
        harness.controller.view.layoutSubtreeIfNeeded()

        let drawerHost = try #require(harness.viewRegistry.view(for: drawerPane.id))
        await eventually("drawer pane should own responder before tab round trip") {
            harness.window.firstResponder === drawerHost
        }

        harness.controller.selectTab(at: 1)
        harness.controller.view.layoutSubtreeIfNeeded()
        harness.controller.selectTab(at: 0)
        harness.controller.view.layoutSubtreeIfNeeded()

        await eventually("tab round trip should restore drawer pane responder") {
            harness.window.firstResponder === drawerHost
        }
        #expect(harness.store.activeTabId == parentTab.id)
        #expect(atom(\.workspaceFocusOwner).owner == .drawerPane(parentPaneId: parentPane.id, paneId: drawerPane.id))
        #expect(harness.window.firstResponder === drawerHost)
    }

    @Test
    func selectingTabViaCommand_restoresExpandedEmptyDrawerFocus() async throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let parentPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let otherPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let parentTab = Tab(paneId: parentPane.id, name: "Parent")
        let otherTab = Tab(paneId: otherPane.id, name: "Other")
        harness.store.appendTab(parentTab)
        harness.store.appendTab(otherTab)
        try registerAttachedPaneHost(parentPane.id, in: harness)
        try registerAttachedPaneHost(otherPane.id, in: harness)
        harness.store.setActiveTab(parentTab.id)
        harness.store.setActivePane(parentPane.id, inTab: parentTab.id)
        harness.store.toggleDrawer(for: parentPane.id)
        atom(\.workspaceFocusOwner).focusEmptyDrawer(parentPaneId: parentPane.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        harness.controller.selectTab(at: 1)
        harness.controller.view.layoutSubtreeIfNeeded()
        harness.controller.selectTab(at: 0)
        harness.controller.view.layoutSubtreeIfNeeded()

        let contentView = try #require(harness.window.contentView)
        await eventually("tab round trip should restore empty drawer responder") {
            harness.window.firstResponder === contentView
        }
        #expect(harness.store.activeTabId == parentTab.id)
        #expect(atom(\.workspaceFocusOwner).owner == .emptyDrawer(parentPaneId: parentPane.id))
        #expect(harness.window.firstResponder === contentView)
    }

    @Test
    func activeTabChanges_doNotDismantleStillExistingTabHosts() throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let firstPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let secondPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let firstTab = Tab(paneId: firstPane.id, name: "First")
        let secondTab = Tab(paneId: secondPane.id, name: "Second")
        harness.store.appendTab(firstTab)
        harness.store.appendTab(secondTab)
        registerPaneHost(firstPane.id, in: harness)
        registerPaneHost(secondPane.id, in: harness)
        harness.store.setActiveTab(firstTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        let dismantleCountBeforeSwitch = harness.controller.paneRepresentableDismantleCountForTesting

        harness.store.setActiveTab(secondTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        #expect(
            harness.controller.paneRepresentableDismantleCountForTesting == dismantleCountBeforeSwitch
        )
    }

    @Test
    func withinTabStateChanges_doNotDismantleRepresentables() throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "Focused")
        harness.store.appendTab(tab)
        registerPaneHost(pane.id, in: harness)
        harness.store.setActiveTab(tab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        let dismantleCountBeforeMutation = harness.controller.paneRepresentableDismantleCountForTesting

        harness.store.setActivePane(pane.id, inTab: tab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        #expect(
            harness.controller.paneRepresentableDismantleCountForTesting == dismantleCountBeforeMutation
        )
    }

    @Test
    func closingTab_removesPersistentHost() throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let firstPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let secondPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let firstTab = Tab(paneId: firstPane.id, name: "First")
        let secondTab = Tab(paneId: secondPane.id, name: "Second")
        harness.store.appendTab(firstTab)
        harness.store.appendTab(secondTab)
        registerPaneHost(firstPane.id, in: harness)
        registerPaneHost(secondPane.id, in: harness)
        harness.store.setActiveTab(firstTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        #expect(harness.controller.tabHostViewForTesting(tabId: secondTab.id) != nil)

        harness.store.removeTab(secondTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        #expect(harness.controller.tabHostViewForTesting(tabId: secondTab.id) == nil)
        #expect(harness.controller.tabHostViewForTesting(tabId: firstTab.id) != nil)
    }

    @Test
    func addingTab_createsPersistentHostWithoutReplacingExistingHost() throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let firstPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let firstTab = Tab(paneId: firstPane.id, name: "First")
        harness.store.appendTab(firstTab)
        registerPaneHost(firstPane.id, in: harness)
        harness.store.setActiveTab(firstTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        let firstHost = try #require(harness.controller.tabHostViewForTesting(tabId: firstTab.id))
        let dismantleCountBeforeAdd = harness.controller.paneRepresentableDismantleCountForTesting

        let secondPane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let secondTab = Tab(paneId: secondPane.id, name: "Second")
        harness.store.appendTab(secondTab)
        registerPaneHost(secondPane.id, in: harness)
        harness.store.setActiveTab(secondTab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        let firstHostAfterAdd = try #require(harness.controller.tabHostViewForTesting(tabId: firstTab.id))
        let secondHost = try #require(harness.controller.tabHostViewForTesting(tabId: secondTab.id))

        #expect(firstHostAfterAdd === firstHost)
        #expect(firstHostAfterAdd.isHidden)
        #expect(secondHost.isHidden == false)
        #expect(
            harness.controller.paneRepresentableDismantleCountForTesting == dismantleCountBeforeAdd
        )
    }

    @Test
    func latePaneHostRegistration_recordsHostWithoutReplacingTabHost() throws {
        let harness = makeHarness()
        defer {
            PaneViewRepresentable.onDismantleForTesting = nil
            try? FileManager.default.removeItem(at: harness.tempDir)
        }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "Late")
        harness.store.appendTab(tab)
        harness.viewRegistry.ensureSlot(for: pane.id)
        harness.store.setActiveTab(tab.id)
        harness.controller.view.layoutSubtreeIfNeeded()
        let tabHostBeforeRegistration = try #require(harness.controller.tabHostViewForTesting(tabId: tab.id))

        let latePaneHost = PaneHostView(paneId: pane.id)
        #expect(harness.viewRegistry.view(for: pane.id) == nil)

        harness.viewRegistry.register(latePaneHost, for: pane.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        let tabHostAfterRegistration = try #require(harness.controller.tabHostViewForTesting(tabId: tab.id))
        #expect(tabHostAfterRegistration === tabHostBeforeRegistration)
        #expect(harness.viewRegistry.view(for: pane.id) === latePaneHost)
        #expect(harness.viewRegistry.slot(for: pane.id).host === latePaneHost)
    }

}

@MainActor
private final class MockPersistentTabSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config _: Ghostty.SurfaceConfiguration,
        metadata _: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> { .failure(.operationFailed("test")) }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        _ = surfaceId
        _ = paneId
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        _ = surfaceId
        _ = reason
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {
        _ = surfaceId
    }
}
