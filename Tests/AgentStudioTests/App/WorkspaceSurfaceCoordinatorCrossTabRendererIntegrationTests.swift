import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Cross-tab move renderer edge cases", .serialized)
struct CrossTabMoveRendererIntegrationTests {
    @Test("moving the final source pane closes the tab without losing or duplicating surfaces")
    func movingFinalSourcePanePreservesDestinationSurfaces() async throws {
        try await withFixture(hasRemainingSourcePane: false) { fixture in
            fixture.movePane()

            #expect(fixture.store.tabLayoutAtom.tab(fixture.sourceTab.id) == nil)
            #expect(fixture.store.tabLayoutAtom.activeTabId == fixture.destinationTab.id)
            #expect(fixture.manager.activeSurfaceCount == 2)
            #expect(fixture.manager.hiddenSurfaceCount == 0)
            fixture.expectAttachedRenderer(fixture.movedPane.id, visible: true)
            fixture.expectAttachedRenderer(fixture.destinationPane.id, visible: true)
        }
    }

    @Test("moved drawer children retain destination attachment and renderer visibility")
    func movedDrawerChildrenRemainAttached() async throws {
        try await withFixture { fixture in
            let firstChild = try #require(fixture.store.addDrawerPane(to: fixture.movedPane.id))
            let secondChild = try #require(fixture.store.addDrawerPane(to: fixture.movedPane.id))
            try fixture.registerSurface(for: firstChild.id)
            try fixture.registerSurface(for: secondChild.id)
            fixture.coordinator.restartRendererVisibilityObservation()

            fixture.movePane()

            let destinationTab = try #require(fixture.store.tabLayoutAtom.tab(fixture.destinationTab.id))
            #expect(destinationTab.allPaneIds.contains(firstChild.id))
            #expect(destinationTab.allPaneIds.contains(secondChild.id))
            #expect(fixture.store.paneAtom.pane(firstChild.id)?.parentPaneId == fixture.movedPane.id)
            #expect(fixture.manager.activeSurfaceCount == 5)
            #expect(fixture.manager.hiddenSurfaceCount == 0)
            fixture.expectAttachedRenderer(firstChild.id, visible: true)
            fixture.expectAttachedRenderer(secondChild.id, visible: true)
        }
    }

    @Test("moving a Zoom source cancels Zoom and restores the remaining source renderer on return")
    func movingZoomSourcePreservesRemainingRenderer() async throws {
        try await withFixture { fixture in
            let remainingPane = try #require(fixture.remainingSourcePane)
            fixture.store.panePresentationAtom.enterZoom(
                inTab: fixture.sourceTab.id,
                sourcePaneId: fixture.movedPane.id,
                viewerPresentation: .unavailable
            )
            fixture.coordinator.restartRendererVisibilityObservation()
            fixture.expectAttachedRenderer(remainingPane.id, visible: false)

            fixture.movePane()
            #expect(fixture.store.panePresentationAtom.zoomPresentation(forTab: fixture.sourceTab.id) == nil)
            fixture.selectTab(fixture.sourceTab.id)

            fixture.expectAttachedRenderer(remainingPane.id, visible: true)
            fixture.expectRendererFocus(remainingPane.id)
            #expect(fixture.manager.activeSurfaceCount == 3)
        }
    }

    @Test("an already-hidden destination surface is not reattached by a cross-tab move")
    func hiddenDestinationSurfaceStaysDetached() async throws {
        try await withFixture { fixture in
            let hiddenPane = fixture.store.createPane(title: "Hidden destination")
            #expect(
                fixture.store.insertPane(
                    hiddenPane.id,
                    inTab: fixture.destinationTab.id,
                    at: fixture.destinationPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
            try fixture.registerSurface(for: hiddenPane.id)
            #expect(fixture.store.tabLayoutAtom.minimizePane(hiddenPane.id, inTab: fixture.destinationTab.id))
            let hiddenSurfaceID = try #require(fixture.surfacesByPaneID[hiddenPane.id]?.id)
            fixture.manager.detach(hiddenSurfaceID, reason: .hide)

            fixture.movePane()

            #expect(fixture.manager.managedSurface(for: hiddenSurfaceID)?.state == .hidden)
            #expect(fixture.manager.managedSurface(for: hiddenSurfaceID)?.lastDeliveredVisibility == false)
            #expect(fixture.manager.hiddenSurfaceCount == 1)
            fixture.expectAttachedRenderer(fixture.movedPane.id, visible: true)
            fixture.expectAttachedRenderer(fixture.destinationPane.id, visible: true)
        }
    }

    @Test("the shown tab has visible attached surfaces after moving from the active source")
    func moveFromActiveSourceShowsDestinationRenderers() async throws {
        try await withFixture { fixture in
            try expectShownTabRenderersAfterMove(fixture)
        }
    }

    @Test("the shown tab has visible attached surfaces when the destination was already active")
    func moveIntoActiveDestinationShowsDestinationRenderers() async throws {
        try await withFixture { fixture in
            fixture.selectTab(fixture.destinationTab.id)
            try expectShownTabRenderersAfterMove(fixture)
        }
    }

    private func expectShownTabRenderersAfterMove(_ fixture: CrossTabRendererFixture) throws {
        fixture.movePane()
        #expect(fixture.store.tabLayoutAtom.activeTabId == fixture.destinationTab.id)
        fixture.expectAttachedRenderer(fixture.movedPane.id, visible: true)
        fixture.expectAttachedRenderer(fixture.destinationPane.id, visible: true)
        let remainingPane = try #require(fixture.remainingSourcePane)
        fixture.expectAttachedRenderer(remainingPane.id, visible: false)

        fixture.selectTab(fixture.sourceTab.id)
        fixture.expectAttachedRenderer(remainingPane.id, visible: true)
        fixture.expectAttachedRenderer(fixture.movedPane.id, visible: false)
        fixture.expectAttachedRenderer(fixture.destinationPane.id, visible: false)
        fixture.expectRendererFocus(remainingPane.id)
    }

    private func withFixture(
        hasRemainingSourcePane: Bool = true,
        body: (CrossTabRendererFixture) throws -> Void
    ) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            atoms.managementLayer.deactivate()
            let fixture = try CrossTabRendererFixture(hasRemainingSourcePane: hasRemainingSourcePane)
            do {
                try body(fixture)
            } catch {
                await fixture.shutdown()
                throw error
            }
            await fixture.shutdown()
        }
    }
}

/// Only libghostty renderer delivery is replaced. Workspace mutation, surface membership,
/// tab visibility projection and focus admission use their production owners.
@MainActor
private final class CrossTabRendererFixture {
    let store = WorkspaceStore()
    let registry = ViewRegistry()
    let delivery = CrossTabRendererDelivery()
    let manager: SurfaceManager
    let coordinator: WorkspaceSurfaceCoordinator
    let movedPane: Pane
    let remainingSourcePane: Pane?
    let destinationPane: Pane
    let sourceTab: Tab
    let destinationTab: Tab
    private(set) var surfacesByPaneID: [UUID: ManagedSurface] = [:]

    init(hasRemainingSourcePane: Bool) throws {
        movedPane = store.createPane(title: "Moved")
        remainingSourcePane = hasRemainingSourcePane ? store.createPane(title: "Remaining source") : nil
        destinationPane = store.createPane(title: "Destination")
        sourceTab = Tab(paneId: movedPane.id)
        destinationTab = Tab(paneId: destinationPane.id)
        store.appendTab(sourceTab)
        store.appendTab(destinationTab)
        if let remainingSourcePane {
            #expect(
                store.insertPane(
                    remainingSourcePane.id,
                    inTab: sourceTab.id,
                    at: movedPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
        }
        store.setActiveTab(sourceTab.id)
        manager = SurfaceManager(maxCreationRetries: 0, healthCheckInterval: 3600, rendererStateDelivery: delivery)
        let lifecycle = WindowLifecycleAtom()
        let windowID = UUIDv7.generate()
        lifecycle.recordWindowRegistered(windowID)
        lifecycle.recordWindowPresentation(
            WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
            for: windowID
        )
        coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: registry,
            runtime: SessionRuntime(store: store),
            surfaceManager: manager,
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: EventBus<RuntimeEnvelope>(),
            windowLifecycleStore: lifecycle,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        for pane in [movedPane, remainingSourcePane, destinationPane].compactMap({ $0 }) {
            try registerSurface(for: pane.id)
        }
        coordinator.bindRendererVisibility(toOwningWindowId: windowID)
    }

    func registerSurface(for paneID: UUID) throws {
        let bareSurface = Ghostty.SurfaceView(
            managedSurfaceID: UUIDv7.generate(),
            appCommandDispatcher: CrossTabRendererCommandDispatcher()
        )
        let managedSurface = try manager.acceptCreatedSurface(
            bareSurface, metadata: SurfaceMetadata(paneId: paneID)
        ).get()
        surfacesByPaneID[paneID] = managedSurface
        manager.attach(managedSurface.id, to: paneID)
        let host = PaneHostView(paneId: paneID)
        host.mountContentView(TerminalPaneMountView(restoredSurfaceId: managedSurface.id, paneId: paneID))
        registry.register(host, for: paneID)
    }

    func movePane() {
        coordinator.executeMovePaneAcrossTabs(
            CrossTabPaneMoveRequest(
                paneId: movedPane.id,
                sourceTabId: sourceTab.id,
                destTabId: destinationTab.id,
                targetPaneId: destinationPane.id,
                direction: .horizontal,
                position: .after
            )
        )
        coordinator.restartRendererVisibilityObservation()
    }

    func selectTab(_ tabID: UUID) {
        store.setActiveTab(tabID)
        coordinator.restartRendererVisibilityObservation()
    }

    func expectAttachedRenderer(_ paneID: UUID, visible: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let surfaceID = surfacesByPaneID[paneID]?.id
        let managed = surfaceID.flatMap(manager.managedSurface(for:))
        #expect(managed?.state == .active(paneId: paneID), sourceLocation: sourceLocation)
        #expect(managed?.lastDeliveredVisibility == visible, sourceLocation: sourceLocation)
        #expect(surfaceID.flatMap { delivery.visibilityBySurfaceID[$0] } == visible, sourceLocation: sourceLocation)
    }

    func expectRendererFocus(_ paneID: UUID, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let surfaceID = surfacesByPaneID[paneID]?.id else {
            Issue.record("No registered surface for pane", sourceLocation: sourceLocation)
            return
        }
        manager.surfaceDidBecomeFirstResponder(surfaceID)
        #expect(delivery.focusBySurfaceID[surfaceID] == true, sourceLocation: sourceLocation)
    }

    func shutdown() async {
        await coordinator.shutdown()
        for (paneID, managedSurface) in surfacesByPaneID {
            registry.view(for: paneID)?.retire()
            manager.destroy(managedSurface.id)
        }
    }
}

@MainActor
private final class CrossTabRendererDelivery: SurfaceRendererStateDelivery {
    private(set) var visibilityBySurfaceID: [UUID: Bool] = [:]
    private(set) var focusBySurfaceID: [UUID: Bool] = [:]

    func deliverVisibility(_ visible: Bool, to surface: Ghostty.SurfaceView) -> Bool {
        visibilityBySurfaceID[surface.managedSurfaceID] = visible
        return true
    }

    func deliverFocus(_ focused: Bool, to surface: Ghostty.SurfaceView) -> Bool {
        focusBySurfaceID[surface.managedSurfaceID] = focused
        return true
    }
}

@MainActor
private final class CrossTabRendererCommandDispatcher: AppCommandDispatching {
    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
