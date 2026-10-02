import AgentStudioCore
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// Renderer-visibility reconciliation against the real `SurfaceManager`, gating the mock-based
/// join proved by `WorkspaceSurfaceCoordinatorRendererVisibilityTests` against production
/// attach/detach/reconcile behavior. `RecordingSurfaceRendererStateDelivery` and
/// `NoOpAppCommandDispatcher` are copied from
/// `SurfaceManagerRendererStateDeliveryTests` because that file lives in the
/// `AgentStudioTerminalTests` target, which this target cannot import.
@MainActor
@Suite("WorkspaceSurfaceCoordinator renderer visibility integration", .serialized)
struct SurfaceRendererVisibilityIntegrationTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    // MARK: - Helpers

    private func makeManager(delivery: RecordingSurfaceRendererStateDelivery) -> SurfaceManager {
        SurfaceManager(
            maxCreationRetries: 0,
            healthCheckInterval: 3600,
            rendererStateDelivery: delivery
        )
    }

    private func makeBareSurface() -> Ghostty.SurfaceView {
        Ghostty.SurfaceView(
            managedSurfaceID: UUIDv7.generate(),
            appCommandDispatcher: NoOpAppCommandDispatcher()
        )
    }

    private func acceptedSurface(
        _ surface: Ghostty.SurfaceView,
        in manager: SurfaceManager
    ) throws -> ManagedSurface {
        try manager.acceptCreatedSurface(
            surface,
            metadata: SurfaceMetadata(paneId: UUIDv7.generate())
        ).get()
    }

    /// A recorder wired to a recording sink so `reconciled` renderer lifecycle emissions can be
    /// inspected directly. Copied from `SurfaceManagerRendererStateDeliveryTests`'s
    /// `makeRendererLifecycleRecorder`/sink pattern: that file lives in the
    /// `AgentStudioTerminalTests` target, which this target cannot import.
    private func makeRendererLifecycleRecorder() -> (
        recorder: AgentStudioPerformanceTraceRecorder,
        sink: RendererVisibilityIntegrationRecordingTraceSink
    ) {
        let sink = RendererVisibilityIntegrationRecordingTraceSink()
        let runtime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": temporaryTraceDirectoryURL().path,
                "AGENTSTUDIO_TRACE_NAME": "workspace-surface-coordinator-renderer-visibility",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 928,
            sinkFactory: AgentStudioTraceSinkFactory(
                makeJSONLSink: { _ in sink },
                makeOTLPSink: { _ in sink }
            ),
            timeUnixNano: { 121 }
        )
        let recorder = AgentStudioPerformanceTraceRecorder(
            traceRuntime: runtime,
            processMemorySampleWait: { false }
        )
        return (recorder, sink)
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentstudio-workspace-surface-coordinator-renderer-visibility-tests",
                isDirectory: true
            )
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Tests

    @Test("returning to the source tab after a cross-tab move restores its remaining terminal renderer and focus")
    func sourceTabRemainingTerminalResumesAfterCrossTabMove() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let movedPane = store.createPane(title: "Moved")
            let remainingSourcePane = store.createPane(title: "Remaining source")
            let destinationPane = store.createPane(title: "Destination")
            let sourceTab = Tab(paneId: movedPane.id)
            let destinationTab = Tab(paneId: destinationPane.id)
            store.appendTab(sourceTab)
            store.appendTab(destinationTab)
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
            store.setActiveTab(sourceTab.id)

            let delivery = RecordingSurfaceRendererStateDelivery()
            let surfaceManager = makeManager(delivery: delivery)
            let viewRegistry = ViewRegistry()
            var surfacesByPaneID: [UUID: ManagedSurface] = [:]
            for paneID in [movedPane.id, remainingSourcePane.id, destinationPane.id] {
                let managedSurface = try acceptedSurface(makeBareSurface(), in: surfaceManager)
                surfacesByPaneID[paneID] = managedSurface
                surfaceManager.attach(managedSurface.id, to: paneID)
                let paneHost = PaneHostView(paneId: paneID)
                paneHost.mountContentView(
                    TerminalPaneMountView(restoredSurfaceId: managedSurface.id, paneId: paneID)
                )
                viewRegistry.register(paneHost, for: paneID)
            }
            defer {
                for (paneID, managedSurface) in surfacesByPaneID {
                    viewRegistry.view(for: paneID)?.retire()
                    surfaceManager.destroy(managedSurface.id)
                }
            }
            let remainingSurface = try #require(surfacesByPaneID[remainingSourcePane.id])
            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: viewRegistry,
                runtime: SessionRuntime(store: store),
                surfaceManager: surfaceManager,
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: EventBus<RuntimeEnvelope>(),
                windowLifecycleStore: windowLifecycleStore,
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)

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
            delivery.reset()

            // Drive the existing visibility owner synchronously; the verdict does not
            // depend on when its observation task receives the tab-selection change.
            store.setActiveTab(sourceTab.id)
            coordinator.restartRendererVisibilityObservation()
            surfaceManager.surfaceDidBecomeFirstResponder(remainingSurface.id)

            #expect(
                delivery.visibilityCalls.contains(.init(surfaceID: remainingSurface.id, visible: true)),
                "The remaining source terminal must resume drawing when its tab becomes visible"
            )
            #expect(
                delivery.focusCalls.contains(.init(surfaceID: remainingSurface.id, focused: true)),
                "The remaining source terminal must admit renderer focus after returning"
            )
            #expect(surfaceManager.activeSurfaceCount == 3)
            await coordinator.shutdown()
        }
    }

    @Test("bulk close hides every surface before publishing one attached-set change")
    func bulkClosePublishesOneAttachedSetChange() throws {
        let delivery = RecordingSurfaceRendererStateDelivery()
        let manager = makeManager(delivery: delivery)
        let paneIDs = (0..<20).map { _ in UUIDv7.generate() }
        var surfaceIDs: [UUID] = []
        for paneID in paneIDs {
            let managed = try acceptedSurface(makeBareSurface(), in: manager)
            manager.attach(managed.id, to: paneID)
            surfaceIDs.append(managed.id)
        }
        delivery.reset()
        var attachedSetChanges = 0
        manager.setAttachedBindingsChangeHandler {
            attachedSetChanges += 1
            #expect(delivery.visibilityCalls.count == paneIDs.count)
            #expect(delivery.focusCalls.count == paneIDs.count)
        }

        manager.retainSurfacesForUndo(forPaneIDs: Set(paneIDs))

        #expect(attachedSetChanges == 1)
        #expect(Set(delivery.visibilityCalls.map(\.surfaceID)) == Set(surfaceIDs))
        #expect(delivery.visibilityCalls.allSatisfy { !$0.visible })
        #expect(delivery.focusCalls.allSatisfy { !$0.focused })
        manager.retainSurfacesForUndo(forPaneIDs: Set(paneIDs))
        #expect(attachedSetChanges == 1)
        manager.setAttachedBindingsChangeHandler(nil)
        manager.releaseUndoSurfaces(forPaneIDs: Set(paneIDs))
    }

    @Test("tab switch delivers exactly the changed surfaces")
    func tabSwitchDeliversExactlyTheChangedSurfaces() async throws {
        try await withAsyncTestCoreAtoms { _ in
            // Arrange
            let store = WorkspaceStore()
            let paneOne = store.createPane()
            let tabOne = Tab(paneId: paneOne.id)
            store.appendTab(tabOne)
            let paneTwo = store.createPane()
            let tabTwo = Tab(paneId: paneTwo.id)
            store.appendTab(tabTwo)
            store.setActiveTab(tabOne.id)

            let delivery = RecordingSurfaceRendererStateDelivery()
            let surfaceManager = makeManager(delivery: delivery)
            let surfaceOne = try acceptedSurface(makeBareSurface(), in: surfaceManager)
            let surfaceTwo = try acceptedSurface(makeBareSurface(), in: surfaceManager)
            delivery.reset()
            surfaceManager.attach(surfaceOne.id, to: paneOne.id)
            surfaceManager.attach(surfaceTwo.id, to: paneTwo.id)

            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: ViewRegistry(),
                runtime: SessionRuntime(store: store),
                surfaceManager: surfaceManager,
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: EventBus<RuntimeEnvelope>(),
                windowLifecycleStore: windowLifecycleStore,
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )

            // Act — bind while tab one is active.
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)

            // Assert — attach delivered `true` for both surfaces; the initial reconciliation then
            // hides the inactive tab's surface and leaves the active tab's surface untouched
            // (its delivered value already equals the desired value).
            #expect(
                delivery.visibilityCalls.filter { $0.surfaceID == surfaceTwo.id }
                    == [
                        .init(surfaceID: surfaceTwo.id, visible: true),
                        .init(surfaceID: surfaceTwo.id, visible: false),
                    ]
            )
            #expect(
                delivery.visibilityCalls.filter { $0.surfaceID == surfaceOne.id }
                    == [.init(surfaceID: surfaceOne.id, visible: true)]
            )

            delivery.reset()

            // Act — switch the active tab.
            store.setActiveTab(tabTwo.id)

            // Assert — exactly the two changed surfaces re-deliver, in either dictionary order.
            await eventually("tab switch delivers exactly the two changed surfaces") {
                delivery.visibilityCalls.count == 2
            }
            let deliveredBySurfaceID = Dictionary(
                uniqueKeysWithValues: delivery.visibilityCalls.map { ($0.surfaceID, $0.visible) }
            )
            #expect(deliveredBySurfaceID == [surfaceOne.id: false, surfaceTwo.id: true])
            #expect(delivery.focusCalls == [.init(surfaceID: surfaceOne.id, focused: false)])

            await coordinator.shutdown()
        }
    }

    @Test("manager-local health and CWD rewrites do not force a reconciliation")
    func managerLocalRewritesDoNotReArmReconciliation() async throws {
        try await withAsyncTestCoreAtoms { _ in
            // Arrange — two tabs, each with its own attached surface, so the eventual tab switch
            // delivers exactly the two changed surfaces.
            let store = WorkspaceStore()
            let paneOne = store.createPane()
            let tabOne = Tab(paneId: paneOne.id)
            store.appendTab(tabOne)
            let paneTwo = store.createPane()
            let tabTwo = Tab(paneId: paneTwo.id)
            store.appendTab(tabTwo)
            store.setActiveTab(tabOne.id)

            let delivery = RecordingSurfaceRendererStateDelivery()
            let surfaceManager = makeManager(delivery: delivery)
            let bareSurfaceOne = makeBareSurface()
            let surfaceOne = try acceptedSurface(bareSurfaceOne, in: surfaceManager)
            let surfaceTwo = try acceptedSurface(makeBareSurface(), in: surfaceManager)
            surfaceManager.attach(surfaceOne.id, to: paneOne.id)
            surfaceManager.attach(surfaceTwo.id, to: paneTwo.id)

            let (recorder, sink) = makeRendererLifecycleRecorder()

            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: ViewRegistry(),
                runtime: SessionRuntime(store: store),
                surfaceManager: surfaceManager,
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: EventBus<RuntimeEnvelope>(),
                windowLifecycleStore: windowLifecycleStore,
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom(),
                performanceTraceRecorder: recorder
            )
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)
            delivery.reset()
            // `drain()` permanently closes the recorder's event queue, so mid-test
            // synchronization uses `flush()` (drains the queue without closing it) and `drain()`
            // is reserved for the final read below.
            try await recorder.flush()
            await sink.reset()

            // Act — real manager-local health and CWD rewrites on the currently-visible surface.
            // Neither goes through `onAttachedBindingsChanged` (attach/detach/move/undoClose), and
            // `SurfaceManager`'s `surfaceHealth`/`activeSurfaces` collections are
            // `@ObservationIgnored`, so neither write should be observed by the coordinator's
            // generation-guarded `withObservationTracking` reconciliation pass.
            bareSurfaceOne.onRendererHealthChanged?(ObjectIdentifier(bareSurfaceOne), false)
            bareSurfaceOne.onWorkingDirectoryChanged?(
                ObjectIdentifier(bareSurfaceOne), "/tmp/agentstudio-f4-cwd")
            await Task.yield()

            // Assert — no reconciliation-driven delivery from the manager-local writes.
            #expect(delivery.visibilityCalls.isEmpty)
            #expect(delivery.focusCalls.isEmpty)

            // Act — switch the active tab: a real visibility change that must force exactly one
            // emitted `reconciled` record.
            store.setActiveTab(tabTwo.id)
            await eventually("tab switch forces exactly one reconciled emission") {
                delivery.visibilityCalls.count == 2
            }
            try await recorder.drain()

            // Assert — exactly one `reconciled` record since the health/CWD writes (the sink was
            // reset immediately before them), with zero all-equal passes accumulated in between
            // (`equal_since_last_emit == 0`: the manager-local writes did not evaluate
            // reconciliation at all, let alone an all-equal pass), and deliveries covering exactly
            // the two tab surfaces.
            let records = await sink.recordedRecords()
            let reconciledRecords = records.filter {
                $0.body == "performance.renderer.lifecycle"
                    && $0.attributes["agentstudio.performance.renderer.event.kind"]
                        == .string("reconciled")
            }
            #expect(reconciledRecords.count == 1)
            #expect(
                reconciledRecords.first?.attributes[
                    "agentstudio.performance.renderer.reconcile.equal_since_last_emit"
                ] == .int(0)
            )
            let deliveredBySurfaceID = Dictionary(
                uniqueKeysWithValues: delivery.visibilityCalls.map { ($0.surfaceID, $0.visible) }
            )
            #expect(deliveredBySurfaceID == [surfaceOne.id: false, surfaceTwo.id: true])

            await coordinator.shutdown()
        }
    }

    @Test("ready nonterminal preview hides real terminals and release remains window-gated")
    func readyNonterminalPreviewHidesRealTerminalAndReleaseRemainsWindowGated() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let terminalPane = store.createPane()
            let previewPane = store.createPane(
                content: .webview(
                    WebviewState(url: URL(string: "https://example.com/preview")!)
                ),
                metadata: PaneMetadata(title: "Preview")
            )
            let terminalTab = Tab(paneId: terminalPane.id, name: "Terminal")
            let previewTab = Tab(paneId: previewPane.id, name: "Preview")
            store.appendTab(terminalTab)
            store.appendTab(previewTab)
            store.setActiveTab(terminalTab.id)

            let delivery = RecordingSurfaceRendererStateDelivery()
            let surfaceManager = makeManager(delivery: delivery)
            let managedSurface = try acceptedSurface(makeBareSurface(), in: surfaceManager)
            surfaceManager.attach(managedSurface.id, to: terminalPane.id)

            let windowLifecycleStore = WindowLifecycleAtom()
            let windowID = UUIDv7.generate()
            windowLifecycleStore.recordWindowRegistered(windowID)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: ViewRegistry(),
                runtime: SessionRuntime(store: store),
                surfaceManager: surfaceManager,
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: EventBus<RuntimeEnvelope>(),
                windowLifecycleStore: windowLifecycleStore,
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
            let heldState = HeldPanePreviewState()
            coordinator.bindHeldPanePreviewState(heldState)
            coordinator.bindRendererVisibility(toOwningWindowId: windowID)
            let target = ValidatedPanePreviewTarget(
                paneID: previewPane.id,
                owningTabID: previewTab.id,
                provider: previewPane.provider,
                sessionID: previewPane.terminalState?.zmxSessionID
            )

            #expect(heldState.beginSpaceHold(requestedTarget: target))
            #expect(heldState.acceptPresentedTarget(target, generation: 1))
            await eventually("ready preview hides the attached terminal") {
                delivery.visibilityCalls.last == .init(surfaceID: managedSurface.id, visible: false)
            }

            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: true),
                for: windowID
            )
            heldState.endSpaceHold()
            await Task.yield()
            #expect(delivery.visibilityCalls.last == .init(surfaceID: managedSurface.id, visible: false))

            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: windowID
            )
            await eventually("visible unoccluded window restores canonical terminal") {
                delivery.visibilityCalls.last == .init(surfaceID: managedSurface.id, visible: true)
            }
            await coordinator.shutdown()
        }
    }
}

// MARK: - Test Doubles (copied from SurfaceManagerRendererStateDeliveryTests;
// AgentStudioTerminalTests is a separate SwiftPM target and cannot be imported here)

@MainActor
private final class RecordingSurfaceRendererStateDelivery: SurfaceRendererStateDelivery {
    struct VisibilityCall: Equatable {
        let surfaceID: UUID
        let visible: Bool
    }
    struct FocusCall: Equatable {
        let surfaceID: UUID
        let focused: Bool
    }
    var visibilityCalls: [VisibilityCall] = []
    var focusCalls: [FocusCall] = []
    var onVisibilityDelivery: ((Ghostty.SurfaceView, Bool) -> Void)?

    func deliverVisibility(_ visible: Bool, to surface: Ghostty.SurfaceView) -> Bool {
        onVisibilityDelivery?(surface, visible)
        visibilityCalls.append(.init(surfaceID: surface.managedSurfaceID, visible: visible))
        return true
    }

    func deliverFocus(_ focused: Bool, to surface: Ghostty.SurfaceView) -> Bool {
        focusCalls.append(.init(surfaceID: surface.managedSurfaceID, focused: focused))
        return true
    }

    func reset() {
        visibilityCalls.removeAll()
        focusCalls.removeAll()
    }
}

private actor RendererVisibilityIntegrationRecordingTraceSink: AgentStudioTraceSink {
    private var records: [AgentStudioTraceRecord] = []

    func record(_ record: AgentStudioTraceRecord) {
        records.append(record)
    }

    func flush() {}

    func shutdown() {}

    func diagnostics() -> AgentStudioTraceWriterDiagnostics {
        .empty
    }

    func recordedRecords() -> [AgentStudioTraceRecord] {
        records
    }

    func reset() {
        records.removeAll()
    }
}

@MainActor
private final class NoOpAppCommandDispatcher: AppCommandDispatching {
    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
