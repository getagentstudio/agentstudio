import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("WorkspaceSurfaceCoordinator cross-tab move view transitions", .serialized)
struct WorkspaceCrossTabMoveTransitionTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test(
        "cross-tab move preserves remaining source attachments and reattaches only destination visibility transitions")
    func crossTabMoveTransitionsExcludeDestinationPanesThatWereAlreadyVisible() {
        let movedPane = UUIDv7.generate()
        let existingDestinationPane = UUIDv7.generate()
        let otherExistingDestinationPane = UUIDv7.generate()

        let transitions = WorkspaceSurfaceCoordinator.computeCrossTabMoveViewTransitions(
            destinationVisibleBefore: [existingDestinationPane, otherExistingDestinationPane],
            destinationVisibleAfter: [
                movedPane,
                existingDestinationPane,
                otherExistingDestinationPane,
            ],
            movedPaneIds: [movedPane]
        )

        #expect(transitions.paneIdsToDetach == [movedPane])
        #expect(transitions.paneIdsToReattach == [movedPane])
    }

    @Test("cross-tab move reattaches moved drawer children visible in the destination active view")
    func crossTabMoveTransitionsReattachVisibleMovedDrawerChildren() {
        let movedParentPane = UUIDv7.generate()
        let visibleMovedDrawerChildPane = UUIDv7.generate()
        let existingDestinationPane = UUIDv7.generate()

        let transitions = WorkspaceSurfaceCoordinator.computeCrossTabMoveViewTransitions(
            destinationVisibleBefore: [existingDestinationPane],
            destinationVisibleAfter: [movedParentPane, existingDestinationPane, visibleMovedDrawerChildPane],
            movedPaneIds: [movedParentPane, visibleMovedDrawerChildPane]
        )

        #expect(transitions.paneIdsToDetach == [movedParentPane, visibleMovedDrawerChildPane])
        #expect(transitions.paneIdsToReattach == [movedParentPane, visibleMovedDrawerChildPane])
    }

    @Test("cross-tab move detaches destination panes that transition from visible to hidden")
    func crossTabMoveTransitionsDetachDestinationPanesThatBecomeHidden() {
        let movedPane = UUIDv7.generate()
        let remainingDestinationPane = UUIDv7.generate()
        let hiddenDestinationPane = UUIDv7.generate()

        let transitions = WorkspaceSurfaceCoordinator.computeCrossTabMoveViewTransitions(
            destinationVisibleBefore: [remainingDestinationPane, hiddenDestinationPane],
            destinationVisibleAfter: [movedPane, remainingDestinationPane],
            movedPaneIds: [movedPane]
        )

        #expect(transitions.paneIdsToDetach == [movedPane, hiddenDestinationPane])
        #expect(transitions.paneIdsToReattach == [movedPane])
    }

    @Test("executeMovePaneAcrossTabs reattaches only moved pane, not already-visible destination panes")
    func executeMovePaneAcrossTabsReattachesOnlyMovedDestinationDelta() {
        withTestCoreAtoms { atoms in
            atoms.managementLayer.deactivate()

            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: "agentstudio-cross-tab-move-\(UUIDv7.generate().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let store = WorkspaceStore()
            let viewRegistry = ViewRegistry()
            let surfaceManager = CrossTabMoveSurfaceManager()
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: viewRegistry,
                runtime: SessionRuntime(store: store),
                surfaceManager: surfaceManager,
                runtimeRegistry: RuntimeRegistry(),
                windowLifecycleStore: WindowLifecycleAtom(),
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )

            let movedPane = store.createPane(title: "A")
            let sourceLeftPane = store.createPane(title: "B")
            let existingDestinationPane = store.createPane(title: "C")
            let otherExistingDestinationPane = store.createPane(title: "D")

            let sourceTab = Tab(paneId: movedPane.id)
            let destinationTab = Tab(paneId: existingDestinationPane.id)
            store.appendTab(sourceTab)
            store.appendTab(destinationTab)
            #expect(
                store.insertPane(
                    sourceLeftPane.id,
                    inTab: sourceTab.id,
                    at: movedPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
            #expect(
                store.insertPane(
                    otherExistingDestinationPane.id,
                    inTab: destinationTab.id,
                    at: existingDestinationPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )

            let surfaceIdsByPaneId = [
                movedPane.id: UUIDv7.generate(),
                sourceLeftPane.id: UUIDv7.generate(),
                existingDestinationPane.id: UUIDv7.generate(),
                otherExistingDestinationPane.id: UUIDv7.generate(),
            ]
            surfaceManager.paneIdsBySurfaceId = Dictionary(
                uniqueKeysWithValues: surfaceIdsByPaneId.map { paneId, surfaceId in
                    (surfaceId, paneId)
                }
            )
            for (paneId, surfaceId) in surfaceIdsByPaneId {
                registerTerminalHost(
                    viewRegistry: viewRegistry,
                    paneId: paneId,
                    surfaceId: surfaceId
                )
            }

            coordinator.executeMovePaneAcrossTabs(
                CrossTabPaneMoveRequest(
                    paneId: movedPane.id,
                    sourceTabId: sourceTab.id,
                    destTabId: destinationTab.id,
                    targetPaneId: existingDestinationPane.id,
                    direction: .horizontal,
                    position: .after
                )
            )

            #expect(surfaceManager.attachedPaneIds == [movedPane.id])
            #expect(Set(surfaceManager.detachedPaneIds) == [movedPane.id])
            #expect(!surfaceManager.attachedPaneIds.contains(existingDestinationPane.id))
            #expect(!surfaceManager.attachedPaneIds.contains(otherExistingDestinationPane.id))
        }
    }

    @Test("executeMovePaneAcrossTabs reattaches moved drawer children visible in destination")
    func executeMovePaneAcrossTabsReattachesVisibleMovedDrawerChildren() throws {
        try withTestCoreAtoms { atoms in
            atoms.managementLayer.deactivate()

            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: "agentstudio-cross-tab-drawer-move-\(UUIDv7.generate().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let store = WorkspaceStore()
            let viewRegistry = ViewRegistry()
            let surfaceManager = CrossTabMoveSurfaceManager()
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: viewRegistry,
                runtime: SessionRuntime(store: store),
                surfaceManager: surfaceManager,
                runtimeRegistry: RuntimeRegistry(),
                windowLifecycleStore: WindowLifecycleAtom(),
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )

            let movedPane = store.createPane(title: "A")
            let sourceLeftPane = store.createPane(title: "B")
            let existingDestinationPane = store.createPane(title: "C")

            let sourceTab = Tab(paneId: movedPane.id)
            let destinationTab = Tab(paneId: existingDestinationPane.id)
            store.appendTab(sourceTab)
            store.appendTab(destinationTab)
            store.setActiveTab(destinationTab.id)
            #expect(
                store.insertPane(
                    sourceLeftPane.id,
                    inTab: sourceTab.id,
                    at: movedPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
            let drawerPane = try #require(store.addDrawerPane(to: movedPane.id))

            let surfaceIdsByPaneId = [
                movedPane.id: UUIDv7.generate(),
                sourceLeftPane.id: UUIDv7.generate(),
                existingDestinationPane.id: UUIDv7.generate(),
                drawerPane.id: UUIDv7.generate(),
            ]
            surfaceManager.paneIdsBySurfaceId = Dictionary(
                uniqueKeysWithValues: surfaceIdsByPaneId.map { paneId, surfaceId in
                    (surfaceId, paneId)
                }
            )
            for (paneId, surfaceId) in surfaceIdsByPaneId {
                registerTerminalHost(
                    viewRegistry: viewRegistry,
                    paneId: paneId,
                    surfaceId: surfaceId
                )
            }

            coordinator.executeMovePaneAcrossTabs(
                CrossTabPaneMoveRequest(
                    paneId: movedPane.id,
                    sourceTabId: sourceTab.id,
                    destTabId: destinationTab.id,
                    targetPaneId: existingDestinationPane.id,
                    direction: .horizontal,
                    position: .after
                )
            )

            #expect(Set(surfaceManager.attachedPaneIds) == [movedPane.id, drawerPane.id])
            #expect(Set(surfaceManager.detachedPaneIds) == [movedPane.id, drawerPane.id])
            #expect(!surfaceManager.attachedPaneIds.contains(existingDestinationPane.id))
        }
    }

    private func registerTerminalHost(
        viewRegistry: ViewRegistry,
        paneId: UUID,
        surfaceId: UUID
    ) {
        let host = PaneHostView(paneId: paneId)
        let terminalView = TerminalPaneMountView(restoredSurfaceId: surfaceId, paneId: paneId)
        host.mountContentView(terminalView)
        viewRegistry.register(host, for: paneId)
    }
}

@MainActor
private final class CrossTabMoveSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    var paneIdsBySurfaceId: [UUID: UUID] = [:]
    private(set) var attachedPaneIds: [UUID] = []
    private(set) var detachedPaneIds: [UUID] = []

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        attachedPaneIds.append(paneId)
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        guard let paneId = paneIdsBySurfaceId[surfaceId] else { return }
        detachedPaneIds.append(paneId)
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {}
}
