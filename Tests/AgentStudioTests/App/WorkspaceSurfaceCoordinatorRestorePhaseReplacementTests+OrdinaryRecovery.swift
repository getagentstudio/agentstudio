import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// R3-1 split out of `WorkspaceSurfaceCoordinatorRestorePhaseReplacementTests.swift`
/// (Lead 2026-10-02) purely for the repo's file-length ceiling -- same
/// `@Suite`, same type, via `extension`, so lane inventory and discovery
/// are unaffected. `ReplacementScenario`, `vocabulary()`,
/// `SucceedingRestoreSurfaceManager`, `makeCoordinator`, `makeTabbedPane`,
/// `makeFallbackPlan`, `bindProjector`, `ReplacementOutcomeRecorder`,
/// `drainAndAssertRestorePhaseEndedExactlyOnce`, `ReplacementTestFailure`,
/// and `makeReplacementAggregate` stay in the original file (shared with
/// the tests that remained there) and are called here across the split as
/// internal, non-`private` members.
extension WorkspaceSurfaceRestorePhaseReplacementTests {
    /// R3-1 (Lead decision 2026-10-02): the generation this arrange leaves
    /// pending must be installed by the one shared successful-mount
    /// boundary (`installRestorePhaseLatchIfPending`, +ViewLifecycle.swift)
    /// ordinary recovery reaches too -- not `executeRepair`'s own manual
    /// reinstall branches (already proven by
    /// `arrangeArmedPaneSurvivingOneFailedRepairBeforeASuccessfulOne` in
    /// the original file). Arms and mounts the initial surface; repairs
    /// while bounds are empty, so `createViewForContentUsingCurrentGeometry`
    /// returns `nil` after registering a `.preparing` placeholder and
    /// `executeRepair` takes its explicit-failure branch, leaving the
    /// generation in `pendingRestorePhaseLatchesByPaneID` (recorded before
    /// teardown, so it survives); then restores real bounds and drives
    /// `restoreVisiblePaneIfNeeded` -- never another `executeRepair` call
    /// -- which must pick the pending generation up at the shared boundary.
    ///
    /// This pane has no `worktreeId`/`repoId`, so `mountCurrentTerminalContent`
    /// routes both mounts through `createTopologyIndependentTerminalView`,
    /// not `createView` -- confirmed by reading it directly. Both got the
    /// identical fix in the same commit, so this is still a faithful proof
    /// of the shared boundary.
    ///
    /// `coordinator.sessionConfig` is overwritten with a deterministic
    /// `/usr/bin/true` zmx path before anything reads it: ordinary
    /// recovery's own mount can only reach `restoreKind: nil`
    /// (`createViewForContent` has no `restoreKind` parameter to carry
    /// `.cold(plan)` through, unlike the initial mount above), which forces
    /// `prepareTerminalSurfaceStartup` through `zmxAttachCommand`'s
    /// `sessionConfiguration.isOperational` check against this machine's
    /// real zmx binary -- confirmed by reading both directly, the same
    /// uninjectable dependency `arrangeArmedAndRepairedPane` avoids with
    /// `.cold(plan)`. `sessionConfig` is a plain, non-`private` `lazy var`,
    /// assignable before its own first read; `SessionConfiguration`'s
    /// memberwise initializer does none of `.detect()`'s environment
    /// probing, so this is deterministic on every machine.
    /// Step 1 (arm and mount the initial surface) of
    /// `arrangeArmedPaneRecoveredThroughOrdinaryRestoreAfterOneRepairWithEmptyBounds`,
    /// extracted only to keep that function under SwiftLint's
    /// `function_body_length` limit -- identical to
    /// `arrangeArmedAndRepairedPane`'s own first step in the original file;
    /// see that function's comments for why each call is shaped this way.
    private func armAndMountInitialSurfaceForOrdinaryRecoveryTest(
        coordinator: WorkspaceSurfaceCoordinator,
        pane: Pane,
        projector: TerminalActivityProjector,
        recorder: FactRecorder<UUID, ReplacementFact>
    ) async throws -> (generation: RestoreGeneration, initialSurface: Ghostty.SurfaceView) {
        let generation = coordinator.allocateRestoreGeneration()
        let acknowledgment = await Ghostty.ActionRouter.armRestorePhase(
            paneID: pane.id, restoreGeneration: generation)
        #expect(acknowledgment == .armed)
        let armedFact = try await recorder.expectNext(
            in: pane.id,
            where: {
                if case .restorePhaseArmed = $0 { return true }
                return false
            },
            "restorePhaseArmed"
        )
        guard case .restorePhaseArmed(let armedGeneration) = armedFact, armedGeneration == generation else {
            Issue.record("expected restorePhaseArmed(\(generation)), got \(armedFact)")
            throw ReplacementTestFailure.setupDidNotSucceed
        }
        #expect(await projector.isRestorePhaseActive(paneID: pane.id))

        let authority: TerminalSurfaceCreationAuthority = .released(PaneId(existingUUID: pane.id))
        let sessionID = try #require(pane.terminalState?.zmxSessionID)
        guard
            case .mounted(let initialMount) = coordinator.createTopologyIndependentTerminalView(
                for: pane,
                initialFrame: NSRect(x: 0, y: 0, width: 400, height: 300),
                treatAsRestoredSessionStart: true,
                authority: authority,
                restoreKind: .cold(makeFallbackPlan(sessionID: sessionID)),
                armedRestoreGeneration: generation
            )
        else {
            Issue.record("expected the initial mount to succeed")
            throw ReplacementTestFailure.setupDidNotSucceed
        }
        let initialSurface = try #require(initialMount.view.ghosttySurface)
        #expect(initialSurface.restorePhaseLatch == generation)
        return (generation: generation, initialSurface: initialSurface)
    }

    private func arrangeArmedPaneRecoveredThroughOrdinaryRestoreAfterOneRepairWithEmptyBounds(
        bindingID: UUID
    ) async throws -> ReplacementScenario {
        let windowLifecycleStore = WindowLifecycleAtom()
        // Bounds intentionally left empty here -- set only after the
        // empty-bounds repair attempt below.
        let surfaceManager = SucceedingRestoreSurfaceManager()
        let coordinator = try makeCoordinator(
            surfaceManager: surfaceManager, windowLifecycleStore: windowLifecycleStore)
        coordinator.sessionConfig = SessionConfiguration(
            isEnabled: true,
            zmxPath: "/usr/bin/true",
            zmxDir: FileManager.default.temporaryDirectory.path,
            healthCheckInterval: 30,
            maxCheckpointAge: 7 * 24 * 60 * 60
        )
        let pane = makeTabbedPane(coordinator: coordinator, launchDirectory: URL(fileURLWithPath: "/tmp"))

        let projector = TerminalActivityProjector()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        bindProjector(projector, bindingID: bindingID, factSink: source.sink)

        // 1. Arm and mount the initial surface.
        let (generation, initialSurface) = try await armAndMountInitialSurfaceForOrdinaryRecoveryTest(
            coordinator: coordinator, pane: pane, projector: projector, recorder: recorder)

        // 2. Repair while bounds are still empty -- the real failure
        // branch, never a hand-set pending entry.
        coordinator.executeRepair(.recreateSurface(paneId: pane.id))
        #expect(
            coordinator.viewRegistry.terminalStatusPlaceholderView(for: pane.id)?.mode == .preparing,
            "an empty-bounds repair attempt must register the preparing placeholder, not hold a real surface"
        )
        #expect(
            coordinator.pendingRestorePhaseLatchesByPaneID[pane.id] == generation,
            "the open generation must survive the empty-bounds attempt instead of being dropped"
        )
        #expect(
            surfaceManager.createdSurfaceIDsInOrder.count == 1,
            "the empty-bounds attempt must not register a new surface"
        )

        // 3. Restore real bounds and drive ordinary visible-pane recovery
        // -- never another `executeRepair` call, so only the shared
        // `installRestorePhaseLatchIfPending` boundary can be what
        // reinstalls the generation here.
        windowLifecycleStore.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 400, height: 300))
        coordinator.restoreVisiblePaneIfNeeded(pane.id, forceWhenBoundsExist: true)
        let recoveredSurface = try #require(coordinator.viewRegistry.terminalView(for: pane.id)?.ghosttySurface)
        #expect(
            recoveredSurface !== initialSurface, "ordinary recovery must mount a new native surface, not reuse it")
        #expect(
            surfaceManager.createdSurfaceIDsInOrder.count == 2,
            "expected one surface from the initial mount and a second from ordinary recovery"
        )
        #expect(
            recoveredSurface.restorePhaseLatch == generation,
            "ordinary recovery must reinstall the generation it found pending, not leave it nil forever"
        )
        #expect(
            coordinator.pendingRestorePhaseLatchesByPaneID[pane.id] == nil,
            "the pending entry must clear once ordinary recovery actually installs it"
        )

        // Register with `SurfaceManager.shared` and replay a pre-end output
        // burst -- identical to `arrangeArmedAndRepairedPane`'s own closing
        // steps; see that function's comments for why each is needed.
        guard
            case .success = SurfaceManager.shared.acceptCreatedSurface(
                recoveredSurface, metadata: SurfaceMetadata(paneId: pane.id))
        else {
            Issue.record("expected SurfaceManager.shared to accept the recovered surface")
            throw ReplacementTestFailure.setupDidNotSucceed
        }
        SurfaceManager.shared.attach(recoveredSurface.managedSurfaceID, to: pane.id)

        let outcomes = ReplacementOutcomeRecorder()
        await projector.configure(outcomeSink: { recorded in outcomes.record(recorded) })
        await projector.ingest(
            surfaceID: recoveredSurface.managedSurfaceID,
            paneID: pane.id,
            aggregate: makeReplacementAggregate(firstTotal: 100, latestTotal: 140),
            latestState: ScrollbarState(top: 130, bottom: 140, total: 140),
            context: TerminalActivityProjectionContext(
                isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
        )

        return ReplacementScenario(
            coordinator: coordinator, projector: projector, outcomes: outcomes, facts: recorder, paneID: pane.id,
            generation: generation, preRepairSurface: initialSurface, repairedSurface: recoveredSurface,
            bindingID: bindingID
        )
    }

    @Test(
        "a generation stuck pending through an empty-bounds repair still reinstalls through ordinary visible-pane recovery, then a real keyDown ends the restore phase exactly once at the projector"
    )
    func realKeyDownAfterOrdinaryRecoveryFollowingEmptyBoundsRepairEndsRestorePhase() async throws {
        let bindingID = UUIDv7.generate()
        let scenario = try await arrangeArmedPaneRecoveredThroughOrdinaryRestoreAfterOneRepairWithEmptyBounds(
            bindingID: bindingID)
        do {
            // Real first-person input on the surface ordinary recovery
            // mounted -- never `markRestorePhaseEnded` or
            // `applyOrderedControl` by hand, and never a hand-set latch:
            // the arrange helper above proved the latch got there through
            // the real empty-bounds-repair-then-ordinary-recovery chain
            // alone.
            scenario.repairedSurface.keyDown(
                with: try #require(makeKeyEvent(characters: "a", charactersIgnoringModifiers: "a")))

            try await drainAndAssertRestorePhaseEndedExactlyOnce(scenario)
        } catch {
            await scenario.tearDown()
            throw error
        }
        await scenario.tearDown()
    }
}
