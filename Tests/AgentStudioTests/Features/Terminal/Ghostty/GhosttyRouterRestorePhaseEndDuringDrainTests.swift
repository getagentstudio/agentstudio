import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioTerminal

/// F2 (review round 1, 2026-10-01): proves the `TerminalLocalActionAccumulator`
/// fix against the REAL production pipeline, not the accumulator alone
/// (`TerminalLocalActionAccumulatorRestorePhaseTests.restorePhaseEndDuringAnInFlightDrainSchedulesFollowUp`
/// already proves the accumulator's own contract directly).
///
/// Drives a real drain through `Ghostty.ActionRouter.localActionAccumulator`
/// (the process-wide singleton every production `offer`/`markRestorePhaseEnded`
/// call reaches) and the real scheduler
/// (`TerminalLocalActionDrainScheduler.scheduleImmediate` ->
/// `enqueueMainActorDrain` -> a real `Task { @MainActor in await drain(...) }`
/// -- confirmed by reading `TerminalLocalActionDrainScheduler.swift` directly,
/// not guessed). That drain uses `.live` dependencies
/// (`GhosttyActionRouter+LocalActions.swift:30`), whose `submitActivityInput`
/// is `{ await Ghostty.ActionRouter.submitTerminalActivityInput($0) }` --
/// confirmed by reading `TerminalLocalActionDrainDependencies.live` directly
/// -- so a sink bound through `Ghostty.ActionRouter.bindTerminalActivityInput`
/// intercepts it for real, with no hand-rolled drain substitute.
///
/// The real suspension point F2 names ("the real MainActor drain suspends
/// while submitting activity input") is
/// `publishActivityProjectionIfNeeded`'s `await dependencies.submitActivityInput(.aggregate(...))`
/// -- confirmed by reading that function directly. A `HeldStep` in the bound
/// sink's `.aggregate` arm parks the real drain Task there, deterministically
/// (no sleep, no poll): the test awaits the step's `firstArrival()` to know
/// the drain is suspended at that exact point before doing anything else,
/// then calls `markRestorePhaseEnded` directly on the same singleton the
/// real latch (`GhosttySurfaceView+Input.swift:522`) would call through, then
/// releases the step and awaits the `.restorePhaseEnded` fact the resulting
/// follow-up drain must produce.
///
/// `.live`'s `mountedHostResolver` is `.surfaceManager`
/// (`surfaceForID: { SurfaceManager.shared.surface(for: $0) }`) --
/// confirmed by reading it directly -- so this surface is registered in
/// `SurfaceManager.shared` through its own real `acceptCreatedSurface` +
/// `attach` (the same pair `SurfaceManagerNativeRetirementTests` and the A5
/// replacement-latch suite already use), not a substitute resolver. Freshly
/// generated `UUIDv7` identities, so this cannot collide with another test's
/// entries; torn down at the end of the test.
@MainActor
@Suite("Ghostty router restore-phase end during drain", .serialized)
struct GhosttyRouterRestorePhaseEndDuringDrainTests {
    private enum DrainFact: Sendable, Equatable {
        case restorePhaseEnded(generation: RestoreGeneration)
    }

    private func vocabulary() -> FactVocabulary<UUID, DrainFact> {
        FactVocabulary(
            describeScope: { $0.uuidString },
            describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                if case .restorePhaseEnded = fact { return true }
                return false
            }
        )
    }

    @Test("input landing while the real drain is suspended still schedules a follow-up that delivers it")
    func restorePhaseEndWhileRealDrainIsSuspendedStillDelivers() async throws {
        let surfaceID = UUIDv7.generate()
        let paneID = UUIDv7.generate()
        let generation = RestoreGeneration(rawValue: 11)
        let bindingID = UUIDv7.generate()

        let surface = Ghostty.SurfaceView(
            managedSurfaceID: surfaceID, appCommandDispatcher: DuringDrainNoOpAppCommandDispatcher())
        guard
            case .success = SurfaceManager.shared.acceptCreatedSurface(
                surface, metadata: SurfaceMetadata(paneId: paneID))
        else {
            Issue.record("expected SurfaceManager.shared to accept the test surface")
            throw DuringDrainTestFailure.setupDidNotSucceed
        }
        SurfaceManager.shared.attach(surfaceID, to: paneID)
        defer { SurfaceManager.shared.destroy(surfaceID) }

        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        let suspensionPoint = HeldStep<Void>("real drain suspended submitting ordinary activity")

        Ghostty.ActionRouter.bindTerminalActivityInput(
            id: bindingID,
            context: { _ in
                TerminalActivityProjectionContext(
                    isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
            },
            sink: { input in
                switch input {
                case .aggregate:
                    // The real suspension point: parks the real drain Task
                    // here until the test releases it.
                    try? await suspensionPoint.arrive(())
                case .orderedControl(_, let inputPaneID, _, let control):
                    if case .restorePhaseEnded(let endedGeneration) = control {
                        source.sink(inputPaneID, .restorePhaseEnded(generation: endedGeneration))
                    }
                case .restorePhaseArmed, .restorePhaseEnded, .paneRetiredPermanently:
                    break
                }
            }
        )
        defer { Ghostty.ActionRouter.unbindTerminalActivityInput(id: bindingID) }
        defer { Ghostty.ActionRouter.retireLocalActions(for: surfaceID) }

        // Arrange -- ordinary output schedules a real drain through the
        // real scheduler. It will suspend inside the bound sink's
        // `.aggregate` arm, above.
        Ghostty.ActionRouter.localActionAccumulator.offer(
            .scrollbar(ScrollbarState(top: 0, bottom: 10, total: 10), observedAtMilliseconds: 1000),
            for: surfaceID
        )
        _ = try await suspensionPoint.firstArrival()

        // Act -- input ends the restore phase while that real drain is
        // genuinely suspended mid-flight, exactly as a real keyDown's
        // `endRestorePhaseIfLatched()` would.
        Ghostty.ActionRouter.localActionAccumulator.markRestorePhaseEnded(
            surfaceID: surfaceID,
            generation: generation,
            contextBeforeControl: TerminalActivityProjectionContext(
                isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
        )

        // Release the suspended drain: it finishes with no additional
        // ordinary work, and (with the F2 fix) schedules a real follow-up
        // through the real scheduler.
        suspensionPoint.release()

        let endedFact = try await recorder.expectNext(
            in: paneID,
            where: {
                if case .restorePhaseEnded = $0 { return true }
                return false
            },
            "restorePhaseEnded"
        )
        guard case .restorePhaseEnded(let endedGeneration) = endedFact else {
            Issue.record("expected restorePhaseEnded, got \(endedFact)")
            throw DuringDrainTestFailure.setupDidNotSucceed
        }
        #expect(endedGeneration == generation)
    }
}

private enum DuringDrainTestFailure: Error {
    case setupDidNotSucceed
}

/// No-op dispatcher used only to satisfy `Ghostty.SurfaceView`'s bare test
/// initializer, matching every other test file in this directory that needs
/// one.
@MainActor
private final class DuringDrainNoOpAppCommandDispatcher: AppCommandDispatching {
    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
