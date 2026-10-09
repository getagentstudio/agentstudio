import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("TerminalPaneMountView displaySurface", .serialized)
struct TerminalPaneMountViewDisplaySurfaceTests {
    @Test("same-surface display skips rewrap only when the current scroll wrapper is mounted")
    func sameSurfaceDisplaySkipsRewrapOnlyForMountedCurrentWrapper() {
        #expect(
            TerminalPaneMountView.shouldReuseMountedSurfaceWrapper(
                currentSurfaceMatchesIncoming: true,
                currentWrapperExists: true,
                currentWrapperIsMounted: true
            )
        )
        #expect(
            !TerminalPaneMountView.shouldReuseMountedSurfaceWrapper(
                currentSurfaceMatchesIncoming: false,
                currentWrapperExists: true,
                currentWrapperIsMounted: true
            )
        )
        #expect(
            !TerminalPaneMountView.shouldReuseMountedSurfaceWrapper(
                currentSurfaceMatchesIncoming: true,
                currentWrapperExists: false,
                currentWrapperIsMounted: false
            )
        )
        #expect(
            !TerminalPaneMountView.shouldReuseMountedSurfaceWrapper(
                currentSurfaceMatchesIncoming: true,
                currentWrapperExists: true,
                currentWrapperIsMounted: false
            )
        )
    }

    @Test("same-surface display plan preserves required post-display effects without rewrap reset")
    func sameSurfaceDisplayPlanPreservesSkipPathEffects() {
        let plan = TerminalPaneMountView.surfaceDisplayPlan(
            currentSurfaceMatchesIncoming: true,
            currentWrapperExists: true,
            currentWrapperIsMounted: true,
            hasBoundRuntime: true,
            observedRuntimeMatchesBoundRuntime: true,
            runtimeBoundToDisplayedSurfaceMatchesBoundRuntime: true
        )

        #expect(plan.reusesMountedWrapper)
        #expect(plan.resetsGeometryReportDedup)
        #expect(!plan.resetsTerminationFlags)
        #expect(!plan.observesRuntime)
        #expect(plan.appliesRuntimeSnapshot)
        #expect(!plan.bindsRuntimeToSurface)
        #expect(plan.installsCloseCallback)
        #expect(!plan.beginsRestorePresentation)
    }

    @Test("same-surface display plan binds runtime when the surface has not been bound yet")
    func sameSurfaceDisplayPlanBindsRuntimeWhenNeeded() {
        let plan = TerminalPaneMountView.surfaceDisplayPlan(
            currentSurfaceMatchesIncoming: true,
            currentWrapperExists: true,
            currentWrapperIsMounted: true,
            hasBoundRuntime: true,
            observedRuntimeMatchesBoundRuntime: false,
            runtimeBoundToDisplayedSurfaceMatchesBoundRuntime: false
        )

        #expect(plan.reusesMountedWrapper)
        #expect(plan.observesRuntime)
        #expect(plan.appliesRuntimeSnapshot)
        #expect(plan.bindsRuntimeToSurface)
        #expect(!plan.resetsTerminationFlags)
        #expect(!plan.beginsRestorePresentation)
    }

    @Test("rewrap display plan resets termination state and binds runtime")
    func rewrapDisplayPlanResetsTerminationStateAndBindsRuntime() {
        let plan = TerminalPaneMountView.surfaceDisplayPlan(
            currentSurfaceMatchesIncoming: false,
            currentWrapperExists: true,
            currentWrapperIsMounted: true,
            hasBoundRuntime: true,
            observedRuntimeMatchesBoundRuntime: true,
            runtimeBoundToDisplayedSurfaceMatchesBoundRuntime: true
        )

        #expect(!plan.reusesMountedWrapper)
        #expect(plan.resetsGeometryReportDedup)
        #expect(plan.resetsTerminationFlags)
        #expect(!plan.observesRuntime)
        #expect(plan.appliesRuntimeSnapshot)
        #expect(plan.bindsRuntimeToSurface)
        #expect(plan.installsCloseCallback)
        #expect(plan.beginsRestorePresentation)
    }

    @Test("display epilogue verifies geometry without repairing it first")
    func displayEpilogueVerifiesGeometryWithoutRepairingItFirst() {
        #expect(TerminalPaneMountView.geometryVerificationMode(for: .displayEpilogue) == .verifyOnlyAfterLayout)
        #expect(TerminalPaneMountView.geometryVerificationMode(for: .explicitGeometrySync) == .syncThenVerify)
    }

    @Test("redisplaying the same surface preserves its mounted wrapper and host")
    func redisplayingSameSurfacePreservesMountedWrapperAndHost() throws {
        let surfaceID = UUIDv7.generate()
        let mountView = TerminalPaneMountView(
            surfaceOperations: makeTerminalFixtureMountOperations(),
            restoredSurfaceId: surfaceID,
            paneId: UUIDv7.generate(),
            title: "Mount reuse"
        )
        let surface = Ghostty.SurfaceView(
            managedSurfaceID: surfaceID,
            appCommandDispatcher: NoOpTerminalMountTestDispatcher()
        )
        defer {
            mountView.removeSurface()
        }

        mountView.displaySurface(surface)
        let capturedWrapper = try #require(mountView.surfaceScrollView)
        let capturedHost = try #require(capturedWrapper.superview)

        mountView.displaySurface(surface)

        #expect(mountView.ghosttySurface === surface)
        #expect(mountView.surfaceScrollView === capturedWrapper)
        #expect(capturedWrapper.superview === capturedHost)
        #expect(surface.superview === capturedWrapper.documentView)
    }
}

@MainActor
private final class NoOpTerminalMountTestDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
