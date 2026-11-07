import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// Coordinator-level renderer-visibility reconciliation: the coordinator joins each
/// attached pane binding against the owning window's presentation facts and the
/// current visibility-tier projection, then asks the surface manager to reconcile.
/// These tests exercise that join against a capturing mock; `WorkspaceSurfaceCoordinatorRendererVisibilityIntegrationTests`
/// exercises the same join against the real `SurfaceManager`.
@MainActor
@Suite("WorkspaceSurfaceCoordinator renderer visibility", .serialized)
struct WorkspaceSurfaceCoordinatorRendererVisibilityTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    private func makeCoordinator(
        store: WorkspaceStore,
        surfaceManager: RendererVisibilityCapturingSurfaceManager,
        windowLifecycleStore: WindowLifecycleAtom
    ) -> WorkspaceSurfaceCoordinator {
        WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: EventBus<RuntimeEnvelope>(),
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }

    @Test("binding then stopping renderer visibility observation does not retain the coordinator")
    func bindingThenStoppingDoesNotRetainTheCoordinator() async {
        await withAsyncTestCoreAtoms { _ in
            // Arrange
            let store = WorkspaceStore()
            let pane = store.createPane()
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            let surfaceManager = RendererVisibilityCapturingSurfaceManager(bindings: [:])
            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            weak var weakCoordinator: WorkspaceSurfaceCoordinator?

            // Act — bind, stop, and drop every strong reference; the observation registrations
            // (renderer visibility and bridge pane activity) must not keep the coordinator alive.
            autoreleasepool {
                let coordinator = makeCoordinator(
                    store: store,
                    surfaceManager: surfaceManager,
                    windowLifecycleStore: windowLifecycleStore
                )
                weakCoordinator = coordinator
                coordinator.bindRendererVisibility(toOwningWindowId: windowID)
                coordinator.stopRendererVisibilityObservation()
            }

            // Assert
            #expect(weakCoordinator == nil)
        }
    }

    @Test("joins attached panes with active tab and owning window facts")
    func joinsAttachedPanesWithActiveTabAndWindowFacts() async {
        await withAsyncTestCoreAtoms { _ in
            // Arrange
            let store = WorkspaceStore()
            let paneA = store.createPane()
            let tabA = Tab(paneId: paneA.id)
            store.appendTab(tabA)
            let paneB = store.createPane()
            let tabB = Tab(paneId: paneB.id)
            store.appendTab(tabB)
            store.setActiveTab(tabA.id)

            let surfaceA = UUIDv7.generate()
            let surfaceB = UUIDv7.generate()
            let surfaceManager = RendererVisibilityCapturingSurfaceManager(
                bindings: [surfaceA: paneA.id, surfaceB: paneB.id]
            )
            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            let coordinator = makeCoordinator(
                store: store,
                surfaceManager: surfaceManager,
                windowLifecycleStore: windowLifecycleStore
            )

            // Act — bind with no presentation facts recorded (defaults to hidden).
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)

            // Assert
            #expect(surfaceManager.reconciliations.last == [surfaceA: false, surfaceB: false])

            // Act — window becomes visible, not miniaturized, not occluded.
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            await eventually("visible window reveals the active tab's surface") {
                surfaceManager.reconciliations.last == [surfaceA: true, surfaceB: false]
            }

            // Act — the active tab switches to the second tab.
            store.setActiveTab(tabB.id)
            await eventually("active tab switch flips the exact results") {
                surfaceManager.reconciliations.last == [surfaceA: false, surfaceB: true]
            }

            // Act — an attached-binding membership change explicitly rearms observation.
            let reconciliationCountBeforeBindingChange = surfaceManager.reconciliations.count
            surfaceManager.replaceBindings([surfaceA: paneA.id])

            // Assert
            #expect(surfaceManager.reconciliations.count == reconciliationCountBeforeBindingChange + 1)
            #expect(surfaceManager.reconciliations.last == [surfaceA: false])

            // Act — shutdown tears down observation; a further membership change does not reconcile.
            await coordinator.shutdown()
            let reconciliationCountAfterShutdown = surfaceManager.reconciliations.count
            surfaceManager.replaceBindings([surfaceB: paneB.id])

            // Assert
            #expect(surfaceManager.reconciliations.count == reconciliationCountAfterShutdown)
        }
    }

    @Test("miniaturization and occlusion independently hide attached panes")
    func miniaturizationAndOcclusionIndependentlyHide() async {
        await withAsyncTestCoreAtoms { _ in
            // Arrange
            let store = WorkspaceStore()
            let pane = store.createPane()
            store.appendTab(Tab(paneId: pane.id))
            let surfaceID = UUIDv7.generate()
            let surfaceManager = RendererVisibilityCapturingSurfaceManager(
                bindings: [surfaceID: pane.id]
            )
            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            let coordinator = makeCoordinator(
                store: store,
                surfaceManager: surfaceManager,
                windowLifecycleStore: windowLifecycleStore
            )
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)

            // Act and assert — visible.
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            await eventually("visible renderer") {
                surfaceManager.reconciliations.last == [surfaceID: true]
            }

            // Act and assert — miniaturized.
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: true, isOccluded: false),
                for: windowID
            )
            await eventually("miniaturized renderer") {
                surfaceManager.reconciliations.last == [surfaceID: false]
            }

            // Act and assert — back visible but occluded.
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: true),
                for: windowID
            )
            await eventually("occluded renderer") {
                surfaceManager.reconciliations.last == [surfaceID: false]
            }

            await coordinator.shutdown()
        }
    }

    @Test("switching arrangements observes the active minimized-pane set")
    func arrangementSwitchObservesMinimizedSet() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let firstPane = store.createPane()
            let secondPane = store.createPane()
            let tab = Tab(paneId: firstPane.id)
            store.appendTab(tab)
            #expect(
                store.insertPane(
                    secondPane.id,
                    inTab: tab.id,
                    at: firstPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                ))
            let defaultArrangementID = tab.activeArrangementId
            let alternateArrangementID = try #require(
                store.createArrangement(name: "Alternate", inTab: tab.id)
            )
            #expect(store.minimizePane(firstPane.id, inTab: tab.id))
            store.switchArrangement(to: defaultArrangementID, inTab: tab.id)

            let surfaceID = UUIDv7.generate()
            let surfaceManager = RendererVisibilityCapturingSurfaceManager(
                bindings: [surfaceID: firstPane.id]
            )
            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            let coordinator = makeCoordinator(
                store: store,
                surfaceManager: surfaceManager,
                windowLifecycleStore: windowLifecycleStore
            )
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)
            #expect(surfaceManager.reconciliations.last == [surfaceID: true])

            store.switchArrangement(to: alternateArrangementID, inTab: tab.id)
            await eventually("alternate arrangement hides the minimized renderer") {
                surfaceManager.reconciliations.last == [surfaceID: false]
            }

            store.switchArrangement(to: defaultArrangementID, inTab: tab.id)
            await eventually("default arrangement reveals the renderer") {
                surfaceManager.reconciliations.last == [surfaceID: true]
            }

            await coordinator.shutdown()
        }
    }

    @Test("minimizing a drawer parent hides both parent and drawer-child renderers")
    func minimizingDrawerParentHidesParentAndChild() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let parentPane = store.createPane()
            let siblingPane = store.createPane()
            let tab = Tab(paneId: parentPane.id)
            store.appendTab(tab)
            #expect(
                store.insertPane(
                    siblingPane.id,
                    inTab: tab.id,
                    at: parentPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                ))
            let drawerPane = try #require(store.addDrawerPane(to: parentPane.id))

            let parentSurfaceID = UUIDv7.generate()
            let drawerSurfaceID = UUIDv7.generate()
            let surfaceManager = RendererVisibilityCapturingSurfaceManager(
                bindings: [
                    parentSurfaceID: parentPane.id,
                    drawerSurfaceID: drawerPane.id,
                ]
            )
            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            let coordinator = makeCoordinator(
                store: store,
                surfaceManager: surfaceManager,
                windowLifecycleStore: windowLifecycleStore
            )
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)
            #expect(
                surfaceManager.reconciliations.last
                    == [parentSurfaceID: true, drawerSurfaceID: true]
            )

            #expect(store.minimizePane(parentPane.id, inTab: tab.id))
            await eventually("minimized drawer parent hides its renderer cohort") {
                surfaceManager.reconciliations.last
                    == [parentSurfaceID: false, drawerSurfaceID: false]
            }

            store.expandPane(parentPane.id, inTab: tab.id)
            await eventually("expanded drawer parent reveals its renderer cohort") {
                surfaceManager.reconciliations.last
                    == [parentSurfaceID: true, drawerSurfaceID: true]
            }

            await coordinator.shutdown()
        }
    }

    @Test("zoom keeps the source pane and its expanded drawer children on")
    func zoomKeepsSourceAndExpandedDrawerChildrenOn() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let parentPane = store.createPane()
            let siblingPane = store.createPane()
            let tab = Tab(paneId: parentPane.id)
            store.appendTab(tab)
            #expect(
                store.insertPane(
                    siblingPane.id,
                    inTab: tab.id,
                    at: parentPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                ))
            let drawerChild = try #require(store.addDrawerPane(to: parentPane.id))
            store.panePresentationAtom.enterZoom(
                inTab: tab.id,
                sourcePaneId: parentPane.id,
                viewerPresentation: .unavailable
            )

            let parentSurfaceID = UUIDv7.generate()
            let childSurfaceID = UUIDv7.generate()
            let siblingSurfaceID = UUIDv7.generate()
            let surfaceManager = RendererVisibilityCapturingSurfaceManager(
                bindings: [
                    parentSurfaceID: parentPane.id,
                    childSurfaceID: drawerChild.id,
                    siblingSurfaceID: siblingPane.id,
                ]
            )
            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            let coordinator = makeCoordinator(
                store: store,
                surfaceManager: surfaceManager,
                windowLifecycleStore: windowLifecycleStore
            )

            // Act
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)

            // Assert
            #expect(
                surfaceManager.reconciliations.last
                    == [parentSurfaceID: true, childSurfaceID: true, siblingSurfaceID: false]
            )

            await coordinator.shutdown()
        }
    }

    @Test("a ready nonterminal preview replaces canonical terminal visibility and release restores it")
    func readyNonterminalPreviewReplacesCanonicalTerminalVisibilityAndReleaseRestoresIt() async {
        await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let terminalPane = store.createPane()
            let previewPane = store.createPane(
                content: .webview(WebviewState(url: URL(string: "https://example.com/preview")!)),
                metadata: PaneMetadata(title: "Preview")
            )
            let terminalTab = Tab(paneId: terminalPane.id)
            let previewTab = Tab(paneId: previewPane.id)
            store.appendTab(terminalTab)
            store.appendTab(previewTab)
            store.setActiveTab(terminalTab.id)

            let surfaceID = UUIDv7.generate()
            let surfaceManager = RendererVisibilityCapturingSurfaceManager(
                bindings: [surfaceID: terminalPane.id]
            )
            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            let coordinator = makeCoordinator(
                store: store,
                surfaceManager: surfaceManager,
                windowLifecycleStore: windowLifecycleStore
            )
            let heldState = HeldPanePreviewState()
            coordinator.bindHeldPanePreviewState(heldState)
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)
            #expect(surfaceManager.reconciliations.last == [surfaceID: true])

            let target = ValidatedPanePreviewTarget(
                paneID: previewPane.id,
                owningTabID: previewTab.id,
                provider: previewPane.provider,
                sessionID: previewPane.terminalState?.zmxSessionID
            )
            #expect(heldState.beginSpaceHold(requestedTarget: target))
            #expect(surfaceManager.reconciliations.last == [surfaceID: true])
            #expect(heldState.acceptPresentedTarget(target, generation: 1))

            await eventually("ready nonterminal preview hides canonical terminal") {
                surfaceManager.reconciliations.last == [surfaceID: false]
            }

            heldState.endSpaceHold()
            await eventually("release restores canonical terminal visibility") {
                surfaceManager.reconciliations.last == [surfaceID: true]
            }
            await coordinator.shutdown()
        }
    }

    // F1 retention test intentionally omitted: `WorkspaceSurfaceCoordinator` cannot deallocate in
    // this harness for a reason unrelated to this file's `[weak self]` fix. A verified-independent
    // pre-existing bug in `WorkspaceSurfaceCoordinator+BridgePaneActivity.swift`'s
    // `observeBridgePaneActivityInputs` (its outer `withObservationTracking` `onChange` closure
    // also lacks `[weak self]`, and `startBridgePaneActivityObservation()` runs unconditionally at
    // init) holds its own live Observation registration on the coordinator for the lifetime of any
    // instance built in this test harness, since nothing here mutates the tracked pane
    // graph/app-lifecycle inputs after construction. Diagnostically adding `[weak self]` there
    // made a `bindRendererVisibility` → `stopRendererVisibilityObservation` → drop-refs test pass;
    // that file is outside this brief's scope, so the diagnostic edit was reverted and this test is
    // dropped rather than pinning an unrelated retainer. The production fix above stands.
}

/// Mirrors `SurfaceManager`'s renderer-visibility contract without any native Ghostty
/// handle: `bindings` stands in for `SurfaceManager.activeSurfaces`, `reconciliations`
/// records every `reconcileAttachedVisibility` pass in call order, and `replaceBindings`
/// stands in for a real attach/detach mutation that fires `onAttachedBindingsChanged`.
@MainActor
private final class RendererVisibilityCapturingSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    private(set) var bindings: [UUID: UUID]
    private var bindingsChangeHandler: (() -> Void)?
    private(set) var reconciliations: [[UUID: Bool]] = []

    init(bindings: [UUID: UUID]) {
        self.bindings = bindings
    }

    func replaceBindings(_ bindings: [UUID: UUID]) {
        self.bindings = bindings
        bindingsChangeHandler?()
    }

    func setAttachedBindingsChangeHandler(_ handler: (() -> Void)?) {
        bindingsChangeHandler = handler
    }

    func reconcileAttachedVisibility(
        _ visibilityForPaneID: (UUID) -> Bool
    ) -> SurfaceVisibilityReconciliationResult {
        let visibilityBySurfaceID = bindings.mapValues(visibilityForPaneID)
        reconciliations.append(visibilityBySurfaceID)
        return SurfaceVisibilityReconciliationResult(
            applied: visibilityBySurfaceID.count,
            equal: 0,
            missing: 0
        )
    }

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? { nil }
    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }
    func destroy(_ surfaceId: UUID) {}
}
