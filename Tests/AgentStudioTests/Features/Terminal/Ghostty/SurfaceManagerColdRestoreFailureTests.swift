import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioTerminal

/// SR5; Program Design item 3: `reportColdRestoreFailure`'s paneID-to-health
/// wiring (`WorkspaceSurfaceManaging`'s doc comment carries the full
/// rationale). `checkSurfaceHealth`'s widened reconciliation guard -- that a
/// real exited process doesn't downgrade this reason back to generic
/// "Process Exited" -- needs a real native `ghostty_surface_t`, which this
/// suite's lightweight `acceptCreatedSurface` construction doesn't carry
/// (`managed.surface.surface` is nil, so `checkSurfaceHealth` would settle
/// `.dead` before ever reaching the process-exited branch); that interaction
/// is proven in the real-app/E2E lane instead.
@MainActor
@Suite("Surface manager cold restore failure", .serialized)
struct SurfaceManagerColdRestoreFailureTests {
    @Test("reportColdRestoreFailure marks the pane's attached surface unhealthy with the specific reason")
    func marksTheAttachedSurfaceUnhealthy() throws {
        // Arrange
        let manager = SurfaceManager(maxCreationRetries: 0, healthCheckInterval: 3600)
        let paneID = UUIDv7.generate()
        let surfaceView = Ghostty.SurfaceView(
            managedSurfaceID: UUIDv7.generate(), appCommandDispatcher: ColdRestoreFailureNoOpAppCommandDispatcher())
        let managed = try manager.acceptCreatedSurface(
            surfaceView, metadata: SurfaceMetadata(paneId: paneID)
        ).get()
        manager.attach(managed.id, to: paneID)
        let failure = ColdStartFailure.exitedBeforeHandoff(exitStatus: 17)

        // Act
        manager.reportColdRestoreFailure(paneID: paneID, failure: failure)

        // Assert
        #expect(manager.health(for: managed.id) == .unhealthy(reason: .coldRestoreFailed(failure)))
        withExtendedLifetime(surfaceView) {}
    }

    @Test("reportColdRestoreFailure for a paneID with no attached surface is a safe no-op")
    func noAttachedSurfaceIsANoOp() {
        // Arrange
        let manager = SurfaceManager(maxCreationRetries: 0, healthCheckInterval: 3600)
        let unattachedPaneID = UUIDv7.generate()

        // Act / Assert: doesn't crash, and no surface silently gains health.
        manager.reportColdRestoreFailure(
            paneID: unattachedPaneID,
            failure: .exitedBeforeHandoff(exitStatus: nil)
        )
        #expect(manager.activeSurfaceIds.isEmpty)
    }
}

@MainActor
private final class ColdRestoreFailureNoOpAppCommandDispatcher: AppCommandDispatching {
    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
