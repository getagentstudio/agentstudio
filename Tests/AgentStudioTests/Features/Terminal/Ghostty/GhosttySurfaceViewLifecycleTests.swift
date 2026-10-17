import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("GhosttySurfaceViewLifecycleTests", .serialized)
struct GhosttySurfaceViewLifecycleTests {
    @Test("close completion includes the host callback's held effect")
    func closeCompletionIncludesHeldHostEffect() async throws {
        var fixtures: [HeldSurfaceCloseFixture] = []
        do {
            try await proveReplyDependsOnStep(
                makeScenario: {
                    let fixture = HeldSurfaceCloseFixture()
                    fixtures.append(fixture)
                    return fixture.scenario()
                },
                replyReportsFailure: { reply, _ in reply == .failed },
                assertCommitted: { reply, _ in #expect(reply == .released) }
            )
        } catch {
            for fixture in fixtures { await fixture.closeAndJoin() }
            throw error
        }
        for fixture in fixtures { await fixture.closeAndJoin() }
    }

    @Test("bare surface has no native handle and deinitializes without a native free")
    func bareSurfaceDeinitializesWithoutNativeHandle() {
        // Arrange
        weak var weakSurface: Ghostty.SurfaceView?

        // Act
        autoreleasepool {
            var surface: Ghostty.SurfaceView? = Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(),
                appCommandDispatcher: LifecycleNoOpAppCommandDispatcher()
            )
            weakSurface = surface
            #expect(surface?.surface == nil)
            surface = nil
        }

        // Assert
        #expect(weakSurface == nil)
    }

    @Test("retirement detaches a retained view and clears its host callbacks")
    func retirementDetachesRetainedView() {
        let parent = NSView()
        let surface = Ghostty.SurfaceView(
            managedSurfaceID: UUIDv7.generate(),
            appCommandDispatcher: LifecycleNoOpAppCommandDispatcher())
        surface.wantsLayer = true
        parent.addSubview(surface)
        surface.onCloseRequested = { _ in nil }

        surface.retireNativeSurface()
        surface.retireNativeSurface()

        #expect(surface.superview == nil)
        #expect(surface.layer == nil)
        #expect(surface.onCloseRequested == nil)
        #expect(surface.surface == nil)
        withExtendedLifetime(surface) {}
    }

    @Test("live delivery reports no side effect for a bare surface")
    func liveDeliveryReportsNoSideEffectForBareSurface() {
        // Arrange
        let surface = Ghostty.SurfaceView(
            managedSurfaceID: UUIDv7.generate(),
            appCommandDispatcher: LifecycleNoOpAppCommandDispatcher()
        )

        // Act
        let visibilityDelivered = LiveSurfaceRendererStateDelivery.shared.deliverVisibility(false, to: surface)
        let focusDelivered = LiveSurfaceRendererStateDelivery.shared.deliverFocus(false, to: surface)

        // Assert
        #expect(visibilityDelivered == false)
        #expect(focusDelivered == false)
    }
}

@MainActor
private final class LifecycleNoOpAppCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}

private enum HeldSurfaceCloseOutcome: Sendable, Equatable {
    case pending
    case failed
    case released
}

@MainActor
private final class HeldSurfaceCloseFixture {
    private let surface = Ghostty.SurfaceView(
        managedSurfaceID: UUIDv7.generate(), appCommandDispatcher: LifecycleNoOpAppCommandDispatcher()
    )
    private let heldEffect = HeldStep<Void>("surface close host callback effect")
    private var outcome: HeldSurfaceCloseOutcome = .pending
    private var callbackTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    init() {
        surface.onCloseRequested = { [weak self] _ in
            guard let self else { return nil }
            let task = Task { @MainActor [self] in
                do {
                    try await heldEffect.arrive(())
                    outcome = .released
                } catch {
                    outcome = .failed
                }
            }
            callbackTask = task
            return task
        }
    }

    func scenario() -> HeldReplyScenario<HeldSurfaceCloseFixture, Void, HeldSurfaceCloseOutcome> {
        .init(context: self, step: heldEffect, produceReply: { [self] in await closeAndObserve() })
    }

    private func closeAndObserve() async -> HeldSurfaceCloseOutcome {
        let completion = surface.handleCloseRequested()
        closeTask = completion
        await completion.value
        // Cache the reply before cleanup joins any callback Task separately.
        return outcome
    }

    func closeAndJoin() async {
        heldEffect.retire()
        await closeTask?.value
        await callbackTask?.value
        surface.retireNativeSurface()
    }
}
