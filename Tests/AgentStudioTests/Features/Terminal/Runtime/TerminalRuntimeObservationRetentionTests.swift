import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite(.serialized)
struct TerminalRuntimeObservationRetentionTests {
    @Test("binding a runtime to terminal views does not retain it after the views are gone")
    func boundRuntimeIsReleasedWithItsViews() {
        // Arrange
        weak var weakRuntime: TerminalRuntime?
        autoreleasepool {
            var runtime: TerminalRuntime? = TerminalRuntime(
                paneId: PaneId.generateUUIDv7(), metadata: PaneMetadata(title: "Retention"),
                surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
            )
            weakRuntime = runtime
            var mountView: TerminalPaneMountView? = TerminalPaneMountView(
                surfaceOperations: makeTerminalFixtureMountOperations(),
                restoredSurfaceId: UUIDv7.generate(), paneId: UUIDv7.generate(), title: "Retention")
            var surfaceView: Ghostty.SurfaceView? = Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(), appCommandDispatcher: NoOpDispatcher())
            // Act — register both observers
            mountView?.bind(runtime: runtime!)
            surfaceView?.bindRuntime(runtime!)
            surfaceView = nil
            mountView = nil
            runtime = nil
        }
        // Assert
        #expect(weakRuntime == nil)  // guards the withObservationTracking onChange retain cycle fixed in S5b
    }
}

@MainActor
private final class NoOpDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
