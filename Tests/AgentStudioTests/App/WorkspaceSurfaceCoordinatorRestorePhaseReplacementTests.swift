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

@MainActor
@Suite("Workspace surface coordinator restore-phase replacement", .serialized)
struct WorkspaceSurfaceRestorePhaseReplacementTests {
    /// R1 gate (Lead 2026-10-01, fix 2): this suite only worked when
    /// another suite had already called `CoreAtomScope.setUp(_:)` in the
    /// same process -- it crashed alone with "CoreAtomScope.store accessed
    /// before CoreAtomScope.setUp(_:)". Matches the sibling pattern in
    /// `WorkspaceSurfaceCoordinatorPostAttachRecreationCheckTests.swift:22-23`
    /// and `WorkspaceSurfaceCoordinatorPostAttachRealMountFirstRenderTests.swift:47-48`;
    /// `installTestCoreAtomsIfNeeded()` is idempotent per process
    /// (`Tests/AgentStudioTests/TestSupport/TestAtomRegistry.swift:17-21`),
    /// so calling it here never conflicts with a sibling suite calling it
    /// too.
    init() {
        installTestCoreAtomsIfNeeded()
    }

    /// Not private: shared with +OrdinaryRecovery.swift (vocabulary()'s return type).
    enum ReplacementFact: Sendable, Equatable {
        case restorePhaseEnded(generation: RestoreGeneration)
    }

    /// Not `private` (test-file split, Lead 2026-10-02): shared with
    /// `WorkspaceSurfaceCoordinatorRestorePhaseReplacementTests+OrdinaryRecovery.swift`
    /// -- `private` is file-scoped and does not cross the split.
    func vocabulary() -> FactVocabulary<UUID, ReplacementFact> {
        FactVocabulary(
            describeScope: { $0.uuidString },
            describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                if case .restorePhaseEnded = fact { return true }
                return false
            }
        )
    }

    /// Succeeds at `createSurface`, following
    /// `WorkspaceSurfaceCoordinatorColdRestoreRestorePhaseIntersectionTests`'s
    /// own proven `SucceedingRestoreSurfaceManager` pattern: every surface it
    /// hands back is a real `Ghostty.SurfaceView`, just one with no native
    /// `ghostty_surface_t` (this suite never needs one -- see the suite doc
    /// comment above).
    ///
    /// Not private: shared with +OrdinaryRecovery.swift.
    @MainActor
    final class SucceedingRestoreSurfaceManager: WorkspaceSurfaceManaging {
        var routing: RestorePhaseCallbackTestFixture?
        private(set) var createdSurfaceIDsInOrder: [UUID] = []
        private var surfacesByID: [UUID: Ghostty.SurfaceView] = [:]

        func syncFocus(activeSurfaceId: UUID?) {}
        func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
        func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {
            routing?.manager.retireActiveAndHiddenSurfaces(forPaneIDs: paneIDs)
        }
        func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

        func createSurface(
            config: Ghostty.SurfaceConfiguration,
            metadata: SurfaceMetadata
        ) -> Result<ManagedSurface, SurfaceError> {
            let surfaceID = UUIDv7.generate()
            let surface = Ghostty.SurfaceView(
                managedSurfaceID: surfaceID,
                appCommandDispatcher: AppTerminalFixtureCommandDispatcher(),
                callbackHandling: routing?.handler
            )
            if let paneID = metadata.paneId { routing?.register(surface, paneID: paneID) }
            surfacesByID[surfaceID] = surface
            createdSurfaceIDsInOrder.append(surfaceID)
            return .success(ManagedSurface(id: surfaceID, surface: surface, metadata: metadata))
        }

        @discardableResult
        func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? { surfacesByID[surfaceId] }
        func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}
        func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }
        func destroy(_ surfaceId: UUID) { routing?.manager.destroy(surfaceId) }
        func reportColdRestoreFailure(paneID: UUID, failure: ColdStartFailure) {}
    }

    /// R2-2 (review round 2, Lead 2026-10-01): the second `createSurface`
    /// call -- the suite's first repair attempt, after the initial mount's
    /// own successful first call -- fails; every call after that succeeds,
    /// the same shape `SucceedingRestoreSurfaceManager` uses otherwise.
    /// `SucceedingRestoreSurfaceManager` cannot fail for this residual at
    /// all (the review's own words), so this exists specifically to prove
    /// the preserved generation survives one real failed replacement and
    /// reinstalls on the next one that succeeds.
    @MainActor
    private final class FailingFirstRepairSurfaceManager: WorkspaceSurfaceManaging {
        var routing: RestorePhaseCallbackTestFixture?
        private(set) var createdSurfaceIDsInOrder: [UUID] = []
        private var surfacesByID: [UUID: Ghostty.SurfaceView] = [:]
        private var callCount = 0

        func syncFocus(activeSurfaceId: UUID?) {}
        func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
        func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {
            routing?.manager.retireActiveAndHiddenSurfaces(forPaneIDs: paneIDs)
        }
        func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

        func createSurface(
            config: Ghostty.SurfaceConfiguration,
            metadata: SurfaceMetadata
        ) -> Result<ManagedSurface, SurfaceError> {
            callCount += 1
            guard callCount != 2 else {
                return .failure(.creationFailed(retries: 0))
            }
            let surfaceID = UUIDv7.generate()
            let surface = Ghostty.SurfaceView(
                managedSurfaceID: surfaceID,
                appCommandDispatcher: AppTerminalFixtureCommandDispatcher(),
                callbackHandling: routing?.handler
            )
            if let paneID = metadata.paneId { routing?.register(surface, paneID: paneID) }
            surfacesByID[surfaceID] = surface
            createdSurfaceIDsInOrder.append(surfaceID)
            return .success(ManagedSurface(id: surfaceID, surface: surface, metadata: metadata))
        }

        @discardableResult
        func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? { surfacesByID[surfaceId] }
        func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}
        func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }
        func destroy(_ surfaceId: UUID) { routing?.manager.destroy(surfaceId) }
        func reportColdRestoreFailure(paneID: UUID, failure: ColdStartFailure) {}
    }

    /// Not private: shared with +OrdinaryRecovery.swift.
    func makeCoordinator(
        surfaceManager: any WorkspaceSurfaceManaging,
        windowLifecycleStore: WindowLifecycleAtom
    ) throws -> WorkspaceSurfaceCoordinator {
        let store = try makeWorkspaceJournalTestStore()
        return WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }

    /// `createTopologyIndependentTerminalView` (used for the initial arm)
    /// only requires the pane to already exist in the store -- confirmed by
    /// reading `isCurrentTerminalPane`, its first guard, directly. The
    /// repair path separately requires the pane to sit in a real tab with a
    /// resolvable frame (`createViewForContentUsingCurrentGeometry` ->
    /// `resolveInitialFramesByTabId`, confirmed by reading both), so this
    /// pane is placed in a single-pane tab up front.
    /// Not private: shared with +OrdinaryRecovery.swift.
    func makeTabbedPane(
        coordinator: WorkspaceSurfaceCoordinator, launchDirectory: URL
    ) -> Pane {
        let pane = coordinator.store.paneAtom.createPane(
            launchDirectory: launchDirectory,
            title: "Restore-phase replacement test pane",
            provider: .zmx,
            lifetime: .persistent,
            zmxSessionID: .generateUUIDv7()
        )
        coordinator.store.tabLayoutAtom.appendTab(Tab(paneId: pane.id))
        return pane
    }

    /// Lead 2026-10-01 (CI fix): the same shape as
    /// `WorkspaceSurfaceCoordinatorPostAttachRealMountFirstRenderTests
    /// .makeFallbackPlan` in this directory -- `zmxExecutable` is `/usr/bin/true`,
    /// a binary every machine has, because `ZmxBackend.buildColdRestoreCommand(plan)`
    /// only interpolates this path into a command *string*
    /// (`TerminalRestoreRuntime.startupCommand(for:kind:)`'s `.cold` arm); this
    /// suite's `SucceedingRestoreSurfaceManager` never executes it. No shared
    /// helper exists yet for this shape (every file in this directory that
    /// needs one writes its own), so this mirrors rather than imports the
    /// sibling's.
    /// Not private: shared with +OrdinaryRecovery.swift.
    func makeFallbackPlan(sessionID: ZmxSessionID) -> TerminalColdRestorePlan {
        TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            zmxDirectory: URL(fileURLWithPath: "/tmp"),
            sessionID: sessionID,
            loginShell: URL(fileURLWithPath: "/bin/zsh"),
            folderCandidates: [URL(fileURLWithPath: "/tmp")],
            notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
            replayFile: nil,
            resume: nil,
            attemptID: .generate()
        )
    }

    func bindProjector(
        _ projector: TerminalActivityProjector,
        coordinator: WorkspaceSurfaceCoordinator,
        factSink: @escaping @Sendable (UUID, ReplacementFact) -> Void
    ) async -> RestorePhaseCallbackTestFixture {
        let routing = RestorePhaseCallbackTestFixture(projector: projector)
        routing.inputObserved = { input in
            if case .orderedControl(_, let paneID, _, .restorePhaseEnded(let generation)) = input {
                factSink(paneID, .restorePhaseEnded(generation: generation))
            }
        }
        coordinator.terminalActivityRouter = routing.router
        await routing.router.start()
        return routing
    }

    /// Not private: shared with +OrdinaryRecovery.swift.
    struct ReplacementScenario {
        let coordinator: WorkspaceSurfaceCoordinator
        let projector: TerminalActivityProjector
        let outcomes: ReplacementOutcomeRecorder
        let facts: FactRecorder<UUID, ReplacementFact>
        let paneID: UUID
        let generation: RestoreGeneration
        let preRepairSurface: Ghostty.SurfaceView
        let repairedSurface: Ghostty.SurfaceView
        let routing: RestorePhaseCallbackTestFixture

        @MainActor
        func tearDown() async {
            await routing.closeAndJoin()
            await projector.reset()
        }
    }

    /// A minimal, file-local stand-in for `AgentStudioTerminalTests
    /// .OutcomeRecorder` -- that type lives in a separate test target
    /// (`Tests/AgentStudioTests/Features/Terminal/TestSupport/TerminalActivityProjectorTestSupport.swift`,
    /// the `AgentStudioTerminalTests` target) this suite's own
    /// `AgentStudioTests` target cannot see. This suite only ever needs the
    /// flattened `outcomes` snapshot after the fact (`drainAndAssertRestorePhaseEndedExactlyOnce`'s
    /// own baseline assertion), never the full recorder's wait/predicate
    /// machinery, so this carries only `record(_:)` and `outcomes`.
    /// Not private: shared with +OrdinaryRecovery.swift.
    final class ReplacementOutcomeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedOutcomes: [TerminalActivityProjectionOutcome] = []

        func record(_ batch: [TerminalActivityProjectionOutcome]) {
            lock.lock()
            defer { lock.unlock() }
            recordedOutcomes.append(contentsOf: batch)
        }

        var outcomes: [TerminalActivityProjectionOutcome] {
            lock.lock()
            defer { lock.unlock() }
            return recordedOutcomes
        }
    }

    /// Shared arrange: a real coordinator and succeeding surface manager, a
    /// real pane in a real tab, a real armed-and-latched initial surface,
    /// then a real repair through `executeRepair(.recreateSurface)`. Stops
    /// short of delivering input -- each `@Test` does that itself, since the
    /// two cases differ only in which real entry point they call.
    private func arrangeArmedAndRepairedPane() async throws -> ReplacementScenario {
        let windowLifecycleStore = WindowLifecycleAtom()
        windowLifecycleStore.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 400, height: 300))
        let surfaceManager = SucceedingRestoreSurfaceManager()
        let coordinator = try makeCoordinator(
            surfaceManager: surfaceManager, windowLifecycleStore: windowLifecycleStore)
        let pane = makeTabbedPane(coordinator: coordinator, launchDirectory: URL(fileURLWithPath: "/tmp"))

        let projector = TerminalActivityProjector()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        let routing = await bindProjector(projector, coordinator: coordinator, factSink: source.sink)
        surfaceManager.routing = routing

        // 1. Arm through the real router entry point -- the same call
        // `mountPreparedTerminalContent` makes for every cold pane.
        let generation = coordinator.allocateRestoreGeneration()
        let acknowledgment = await routing.router.armRestorePhase(
            paneID: pane.id, restoreGeneration: generation)
        #expect(acknowledgment == .armed)
        #expect(await projector.restorePhaseGenerationsByPane[pane.id] == generation)

        // Set the latch on the initial surface -- the same call
        // `mountPreparedTerminalContent` makes right after that arm
        // acknowledgment (`WorkspaceSurfaceCoordinator+ViewLifecycle.swift:333`).
        //
        // CI fix (Lead 2026-10-01): `restoreKind: .cold(plan)`, matching what
        // `mountPreparedTerminalContent` actually passes for a real cold
        // pane's admission -- not `nil`, which forces `prepareTerminalSurfaceStartup`
        // through `zmxAttachCommand`'s `sessionConfiguration.isOperational`
        // check against this machine's own real zmx binary (uninjectable:
        // `WorkspaceSurfaceCoordinator.sessionConfig` has no test seam), and
        // which only resolves on a machine that has one. `.cold(plan)` routes
        // through `ZmxBackend.buildColdRestoreCommand(plan)` instead, which
        // only needs `plan.zmxExecutable`'s path as a string to interpolate,
        // never executes it.
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
        let preRepairSurface = try #require(initialMount.view.ghosttySurface)
        #expect(preRepairSurface.restorePhaseLatch == generation)

        // 2. Replace through the real repair path -- never setting the
        // latch or calling `markRestorePhaseEnded` by hand.
        coordinator.executeRepair(.recreateSurface(paneId: pane.id))
        let repairedSurface = try #require(coordinator.viewRegistry.terminalView(for: pane.id)?.ghosttySurface)
        #expect(repairedSurface !== preRepairSurface, "repair must replace the native surface, not reuse it")
        #expect(
            surfaceManager.createdSurfaceIDsInOrder.count == 2,
            "expected one surface from the initial mount and a second from repair"
        )
        #expect(
            repairedSurface.restorePhaseLatch == generation, "the replacement surface must inherit the open latch")

        // Replay output arriving on the replacement surface while its
        // restore phase is still open (the realistic order: the shell
        // redraws its restored scrollback, then the person's first
        // keystroke lands) -- establishes the pre-end accumulation that
        // `resetPaneActivityBaselineAfterRestorePhaseEnd` must discard.
        let outcomes = ReplacementOutcomeRecorder()
        await projector.configure(outcomeSink: { recorded in outcomes.record(recorded) })
        await projector.ingest(
            surfaceID: repairedSurface.managedSurfaceID,
            paneID: pane.id,
            aggregate: makeReplacementAggregate(firstTotal: 100, latestTotal: 140),
            latestState: ScrollbarState(top: 130, bottom: 140, total: 140),
            context: TerminalActivityProjectionContext(
                isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
        )

        return ReplacementScenario(
            coordinator: coordinator, projector: projector, outcomes: outcomes, facts: recorder, paneID: pane.id,
            generation: generation, preRepairSurface: preRepairSurface, repairedSurface: repairedSurface,
            routing: routing
        )
    }

    /// R2-2 (review round 2, Lead 2026-10-01): the residual
    /// `arrangeArmedAndRepairedPane` cannot cover -- its
    /// `SucceedingRestoreSurfaceManager` never fails, so `executeRepair`'s
    /// own failure branch (`WorkspaceSurfaceCoordinator+ViewHelpers.swift`'s
    /// `.recreateSurface` case, the `guard createViewForRepair(for: pane) !=
    /// nil else { ...; return }` arm) never ran under test before this.
    ///
    /// Same arm-and-mount steps as `arrangeArmedAndRepairedPane`, then two
    /// real repairs instead of one:
    /// 1. a first `executeRepair(.recreateSurface)` against
    ///    `FailingFirstRepairSurfaceManager` (its second
    ///    `createSurface` call, which fails) -- asserts the registered
    ///    view is the "failed to start" placeholder, not the torn-down
    ///    pane's old content, and that the generation survived into
    ///    `pendingRestorePhaseLatchesByPaneID` rather than being silently
    ///    dropped;
    /// 2. a second `executeRepair(.recreateSurface)` (the manager's third
    ///    call, which succeeds) -- asserts the new surface inherits that
    ///    same generation and the pending entry is cleared, proving the
    ///    reinstall-on-success path in the same production method.
    ///
    /// Stops short of delivering input, exactly like
    /// `arrangeArmedAndRepairedPane` -- each `@Test` does that itself.
    private func arrangeArmedPaneSurvivingOneFailedRepairBeforeASuccessfulOne() async throws -> ReplacementScenario {
        let windowLifecycleStore = WindowLifecycleAtom()
        windowLifecycleStore.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 400, height: 300))
        let surfaceManager = FailingFirstRepairSurfaceManager()
        let coordinator = try makeCoordinator(
            surfaceManager: surfaceManager, windowLifecycleStore: windowLifecycleStore)
        let pane = makeTabbedPane(coordinator: coordinator, launchDirectory: URL(fileURLWithPath: "/tmp"))

        let projector = TerminalActivityProjector()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        let routing = await bindProjector(projector, coordinator: coordinator, factSink: source.sink)
        surfaceManager.routing = routing

        // 1. Arm and mount the initial surface -- identical to
        // `arrangeArmedAndRepairedPane`'s own steps 1 and the latch-setting
        // mount that follows; see that function's comments for why each
        // call is shaped this way.
        let generation = coordinator.allocateRestoreGeneration()
        let acknowledgment = await routing.router.armRestorePhase(
            paneID: pane.id, restoreGeneration: generation)
        #expect(acknowledgment == .armed)
        #expect(await projector.restorePhaseGenerationsByPane[pane.id] == generation)

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
        let preRepairSurface = try #require(initialMount.view.ghosttySurface)
        #expect(preRepairSurface.restorePhaseLatch == generation)

        // 2. First repair attempt: the manager's second `createSurface`
        // call, which fails. `executeRepair`'s `.recreateSurface` case tears
        // down the old view before attempting the replacement, then
        // `createTopologyIndependentTerminalView`'s own failure branch
        // (`WorkspaceSurfaceCoordinator+ViewLifecycle.swift:358-369`)
        // registers a "failed to start" placeholder through
        // `registerTerminalPlaceholderIfNeeded` before returning `nil` --
        // confirmed by reading that path directly. So a view IS present
        // afterward (the placeholder, with its own retry/dismiss affordance
        // for the person), just never the real terminal content; this is
        // what actually proves "no view holds the generation on" without
        // claiming the registry entry itself is gone. Asserted the
        // strongest true observable, the same way the sibling
        // `WorkspaceSurfaceCoordinatorHardeningTests+Restoration.swift
        // .repairCreateMissingView_failedPlaceholderRetriesCreation` does:
        // the registered view IS the `.failedToStart` placeholder, not
        // merely "has no surface."
        coordinator.executeRepair(.recreateSurface(paneId: pane.id))
        #expect(
            coordinator.viewRegistry.terminalStatusPlaceholderView(for: pane.id)?.mode == .failedToStart,
            "a failed replacement must register the failed-to-start placeholder, not hold a real surface"
        )
        #expect(
            coordinator.pendingRestorePhaseLatchesByPaneID[pane.id] == generation,
            "the open generation must survive the failed attempt instead of being dropped"
        )
        #expect(surfaceManager.createdSurfaceIDsInOrder.count == 1, "the failing call must not register a surface")

        // 3. Second repair attempt: the manager's third call, which
        // succeeds -- this is the real reinstall path, not a hand-set latch.
        coordinator.executeRepair(.recreateSurface(paneId: pane.id))
        let repairedSurface = try #require(coordinator.viewRegistry.terminalView(for: pane.id)?.ghosttySurface)
        #expect(repairedSurface !== preRepairSurface, "repair must replace the native surface, not reuse it")
        #expect(
            surfaceManager.createdSurfaceIDsInOrder.count == 2,
            "expected one surface from the initial mount and a second from the successful repair"
        )
        #expect(
            repairedSurface.restorePhaseLatch == generation,
            "the surviving generation must reinstall onto the surface that finally succeeded"
        )
        #expect(
            coordinator.pendingRestorePhaseLatchesByPaneID[pane.id] == nil,
            "the pending entry must clear once the generation is reinstalled for real"
        )

        let outcomes = ReplacementOutcomeRecorder()
        await projector.configure(outcomeSink: { recorded in outcomes.record(recorded) })
        await projector.ingest(
            surfaceID: repairedSurface.managedSurfaceID,
            paneID: pane.id,
            aggregate: makeReplacementAggregate(firstTotal: 100, latestTotal: 140),
            latestState: ScrollbarState(top: 130, bottom: 140, total: 140),
            context: TerminalActivityProjectionContext(
                isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
        )

        return ReplacementScenario(
            coordinator: coordinator, projector: projector, outcomes: outcomes, facts: recorder, paneID: pane.id,
            generation: generation, preRepairSurface: preRepairSurface, repairedSurface: repairedSurface,
            routing: routing
        )
    }

    /// Drains and awaits the resulting fact after real input already fired
    /// `endRestorePhaseIfLatched()` on `scenario.repairedSurface`. Asserts
    /// the generation matches and that the projector reflects the phase
    /// ending exactly once, then proves "ordinary activity resumes": a
    /// subsequent `ingest` starts a fresh baseline instead of continuing
    /// pre-restore accumulation (mirroring
    /// `TerminalActivityProjectorRestorePhaseTests.commandCompletionSkipsRestoreAndMatchedEndResetsBaselines`'s
    /// own baseline assertion shape).
    ///
    /// Never tears down the scenario itself -- every exit here is a
    /// `throw`, not a `return`, so the caller's `do`/`catch` around
    /// `scenario.tearDown()` is the only place cleanup runs.
    /// Not private: shared with +OrdinaryRecovery.swift.
    func drainAndAssertRestorePhaseEndedExactlyOnce(
        _ scenario: ReplacementScenario
    ) async throws {
        // The latch itself clears synchronously, inside `keyDown`/`paste`,
        // before any drain -- confirmed by reading `endRestorePhaseIfLatched()`.
        #expect(scenario.repairedSurface.restorePhaseLatch == nil)

        let handler = scenario.routing.handler
        handler.localActionDrainScheduler.cancel(for: scenario.repairedSurface.managedSurfaceID)
        await handler.host.drainLocalActions(
            for: scenario.repairedSurface.managedSurfaceID, lane: .immediate,
            accumulator: handler.localActionAccumulator)

        let endedFact = try await scenario.facts.expectNext(
            in: scenario.paneID,
            where: {
                if case .restorePhaseEnded = $0 { return true }
                return false
            },
            "restorePhaseEnded"
        )
        guard case .restorePhaseEnded(let endedGeneration) = endedFact else {
            Issue.record("expected restorePhaseEnded, got \(endedFact)")
            throw ReplacementTestFailure.setupDidNotSucceed
        }
        #expect(endedGeneration == scenario.generation)
        #expect(await scenario.projector.isRestorePhaseActive(paneID: scenario.paneID) == false)

        // Exactly once, not merely at-least-once: the latch itself (already
        // asserted nil above) can only fire `markRestorePhaseEnded` a single
        // time per arm (`guard let generation = restorePhaseLatch else {
        // return }; restorePhaseLatch = nil` -- confirmed by reading
        // `endRestorePhaseIfLatched()` directly), and the projector's own
        // generation-matching guard
        // (`TerminalActivityProjectorRestorePhaseTests.duplicateEndIsANoOp`,
        // `.staleGenerationIsIgnored`) independently proves a second arrival
        // with the same generation cannot re-trigger it. A real second
        // `keyDown` on this already-cleared surface is a no-op at the latch
        // itself and never reaches the accumulator at all.
        scenario.repairedSurface.keyDown(with: try #require(makeKeyEvent(keyCode: 0)))
        #expect(scenario.repairedSurface.restorePhaseLatch == nil)

        // "The pane's next readable line becomes the baseline": the next
        // ingest after the end must start a fresh accumulating burst whose
        // baseline is the pre-end replay's own latest total (140, from
        // `arrangeArmedAndRepairedPane`'s replay ingest), proving
        // `resetPaneActivityBaselineAfterRestorePhaseEnd` discarded the
        // replay accumulation instead of continuing it -- mirroring
        // `commandCompletionSkipsRestoreAndMatchedEndResetsBaselines`'s own
        // assertion shape.
        await scenario.projector.ingest(
            surfaceID: scenario.repairedSurface.managedSurfaceID,
            paneID: scenario.paneID,
            aggregate: makeReplacementAggregate(firstTotal: 140, latestTotal: 145),
            latestState: ScrollbarState(top: 135, bottom: 145, total: 145),
            context: TerminalActivityProjectionContext(
                isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
        )
        let latestBurst = scenario.outcomes.outcomes.compactMap { outcome -> TerminalOutputBurstState? in
            guard case .compactStateChanged(let update) = outcome, update.paneID == scenario.paneID else {
                return nil
            }
            return update.outputBurst
        }.last
        guard case .accumulating(let burst) = latestBurst else {
            Issue.record(
                "expected post-restore output to start a new accumulating burst, got \(String(describing: latestBurst))"
            )
            throw ReplacementTestFailure.setupDidNotSucceed
        }
        #expect(
            burst.baselineTotal == 140,
            "the restore-end reset point becomes the new baseline, not a continuation of the replay")
    }

    @Test("a real keyDown on the replacement surface ends the restore phase exactly once at the projector")
    func realKeyDownOnReplacementSurfaceEndsRestorePhase() async throws {
        let scenario = try await arrangeArmedAndRepairedPane()
        do {
            // 3. Real first-person input on the NEW surface -- never
            // `markRestorePhaseEnded` or `applyOrderedControl` by hand.
            scenario.repairedSurface.keyDown(
                with: try #require(makeKeyEvent(characters: "a", charactersIgnoringModifiers: "a")))

            try await drainAndAssertRestorePhaseEndedExactlyOnce(scenario)
        } catch {
            await scenario.tearDown()
            throw error
        }
        await scenario.tearDown()
    }

    @Test("a real paste on the replacement surface ends the restore phase exactly once at the projector")
    func realPasteOnReplacementSurfaceEndsRestorePhase() async throws {
        let scenario = try await arrangeArmedAndRepairedPane()
        do {
            // `paste(_:)`'s own `performBindingAction` guards on the native
            // `surface` (`TerminalSurfaceActionPerforming.swift:61`) and
            // no-ops for this lightweight double, but
            // `endRestorePhaseIfLatched()` runs first and unconditionally
            // (`GhosttySurfaceView+Input.swift:510`).
            scenario.repairedSurface.paste(nil)

            try await drainAndAssertRestorePhaseEndedExactlyOnce(scenario)
        } catch {
            await scenario.tearDown()
            throw error
        }
        await scenario.tearDown()
    }

    @Test(
        "the generation survives a failed replacement and reinstalls onto the one that succeeds, then a real keyDown still ends the restore phase exactly once at the projector"
    )
    func realKeyDownAfterFailedThenSucceededReplacementEndsRestorePhase() async throws {
        let scenario = try await arrangeArmedPaneSurvivingOneFailedRepairBeforeASuccessfulOne()
        do {
            // 3. Real first-person input on the surface that finally
            // succeeded -- never `markRestorePhaseEnded` or
            // `applyOrderedControl` by hand, and never a hand-set latch:
            // the arrange helper above proved the latch got there through
            // the real failed-then-succeeded repair chain alone.
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

enum ReplacementTestFailure: Error {
    case setupDidNotSucceed
}

/// Not private: shared with +OrdinaryRecovery.swift.
func makeReplacementAggregate(
    firstTotal: Int,
    latestTotal: Int
) -> TerminalScrollbarActivityAggregate {
    var aggregate = TerminalScrollbarActivityAggregate(
        state: ScrollbarState(
            top: max(0, firstTotal - 10),
            bottom: firstTotal,
            total: firstTotal
        ),
        observedAtMilliseconds: 1000
    )
    aggregate.merge(
        state: ScrollbarState(
            top: max(0, latestTotal - 10),
            bottom: latestTotal,
            total: latestTotal
        ),
        observedAtMilliseconds: 1100
    )
    return aggregate
}
