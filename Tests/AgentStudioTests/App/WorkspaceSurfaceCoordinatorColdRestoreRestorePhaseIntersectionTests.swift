import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

extension E2ESerializedTests {
    @MainActor
    @Suite("Cold restore and restore-phase-end intersection", .serialized)
    struct ColdRestoreRestorePhaseIntersectionTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        /// One fact stream, scoped by paneID, carrying both halves this
        /// test proves ordering between -- calling `expectNext` for
        /// `.restorePhaseEnded` and then `.coldStartOutcome` in sequence is
        /// itself the ordering proof: it fails if they arrived reversed.
        private enum IntersectionFact: Sendable, Equatable {
            case restorePhaseEnded(generation: RestoreGeneration)
            case coldStartOutcome(ColdStartOutcome)
        }

        private func vocabulary() -> FactVocabulary<UUID, IntersectionFact> {
            FactVocabulary(
                describeScope: { $0.uuidString },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .coldStartOutcome = fact { return true }
                    return false
                }
            )
        }

        /// Succeeds at `createSurface`, unlike `TerminalRestoreCapturingSurfaceManager`.
        /// Records `reportColdRestoreFailure` calls for the failure-path
        /// assertion.
        @MainActor
        private final class SucceedingRestoreSurfaceManager: WorkspaceSurfaceManaging {
            var routing: RestorePhaseCallbackTestFixture?
            private(set) var reportedFailures: [(paneID: UUID, failure: ColdStartFailure)] = []
            /// `attachTopologyIndependentSurface` requires this to return
            /// the exact surface `createSurface` just made, non-nil, or the
            /// mount fails with `.surfaceAttachmentFailed` -- confirmed by
            /// reading that method directly.
            private var surfacesByID: [UUID: Ghostty.SurfaceView] = [:]

            func syncFocus(activeSurfaceId: UUID?) {}
            func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
            func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}
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
                return .success(ManagedSurface(id: surfaceID, surface: surface, metadata: metadata))
            }

            @discardableResult
            func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? { surfacesByID[surfaceId] }
            func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}
            func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }
            func destroy(_ surfaceId: UUID) {}

            func reportColdRestoreFailure(paneID: UUID, failure: ColdStartFailure) {
                reportedFailures.append((paneID: paneID, failure: failure))
            }
        }

        private func makeCoordinator(surfaceManager: SucceedingRestoreSurfaceManager) throws
            -> WorkspaceSurfaceCoordinator
        {
            let store = try makeWorkspaceJournalTestStore()
            return WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: ViewRegistry(),
                runtime: SessionRuntime(store: store),
                surfaceManager: surfaceManager,
                terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
                terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
                runtimeRegistry: RuntimeRegistry(),
                windowLifecycleStore: WindowLifecycleAtom(),
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
        }

        /// `isCurrentTerminalPane` (guarding `createTopologyIndependentTerminalView`,
        /// the first thing `mountPreparedTerminalContent` calls on a
        /// successful mount) requires the pane to already exist in the
        /// coordinator's own store -- confirmed by reading it directly. A
        /// bare `Pane(...)` literal, never admitted, fails that guard.
        private func makeZmxPane(
            coordinator: WorkspaceSurfaceCoordinator, sessionID: ZmxSessionID, launchDirectory: URL
        ) -> Pane {
            coordinator.store.paneAtom.createPane(
                launchDirectory: launchDirectory,
                title: "Intersection test pane",
                provider: .zmx,
                lifetime: .persistent,
                zmxSessionID: sessionID
            )
        }

        private func makeFIFOPath() throws -> String {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("intersection-fifo-\(UUIDv7.generate().uuidString)").path
            guard mkfifo(path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return path
        }

        /// Blocks until the matching read end (`cat <fifo>`) has genuinely
        /// opened -- real POSIX rendezvous, not a timing guess. Offloaded
        /// off the cooperative pool since it's a real blocking syscall.
        private func openFIFOForWriting(atPath path: String) async throws -> Int32 {
            try await withoutBlockingCooperativePool {
                let descriptor = open(path, O_WRONLY)
                guard descriptor >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return descriptor
            }
        }

        private func closeFIFOWriteDescriptor(_ descriptor: Int32) async throws {
            try await withoutBlockingCooperativePool {
                guard close(descriptor) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }

        private func bindProjector(
            _ projector: TerminalActivityProjector,
            coordinator: WorkspaceSurfaceCoordinator,
            factSink: @escaping @Sendable (UUID, IntersectionFact) -> Void
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

        /// `runIntersectionScenario`'s result: the harness is returned, not
        /// cleaned up there -- the cold-start observer's watch task keeps
        /// running in the background past that function's own return (its
        /// outcome is awaited later, by the caller). Killing the session
        /// before that settles would race the observer instead of proving
        /// it. The caller cleans up only after consuming both the
        /// restorePhaseEnded and coldStartOutcome facts.
        private struct IntersectionScenario {
            let harness: ZmxTestHarness
            let facts: FactRecorder<UUID, IntersectionFact>
            let surfaceManager: SucceedingRestoreSurfaceManager
            let paneID: UUID
            let surfaceID: UUID
        }

        /// Shared arrange-act-cleanup for both cases: builds a real
        /// coordinator, a real zmx cold-restore session held at a FIFO, a
        /// real bound projector, mounts the pane, delivers early input
        /// exactly as `GhosttySurfaceView+Input.swift` would, and releases
        /// the hold into either a failing or a real final shell.
        private func runIntersectionScenario(
            loginShell: URL
        ) async throws -> IntersectionScenario {
            let harness = await ZmxTestHarness()
            let zmxPath = try #require(harness.zmxPath)
            try FileManager.default.createDirectory(atPath: harness.zmxDir, withIntermediateDirectories: true)

            let holdFIFOPath = try makeFIFOPath()
            let sessionID = ZmxSessionID.generateUUIDv7()
            let attemptID = ColdRestoreAttemptID.generate()
            let plan = TerminalColdRestorePlan(
                zmxExecutable: URL(fileURLWithPath: zmxPath),
                zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                sessionID: sessionID,
                loginShell: loginShell,
                folderCandidates: [URL(fileURLWithPath: "/tmp")],
                notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
                replayFile: URL(fileURLWithPath: holdFIFOPath),
                resume: nil,
                attemptID: attemptID
            )

            let surfaceManager = SucceedingRestoreSurfaceManager()
            let coordinator = try makeCoordinator(surfaceManager: surfaceManager)
            let source = LocalFactSource(vocabulary: vocabulary())
            let recorder = try source.attach()
            coordinator.coldStartObservationFactSink = { paneID, outcome in
                source.sink(paneID, .coldStartOutcome(outcome))
            }

            let projector = TerminalActivityProjector()
            let routing = await bindProjector(projector, coordinator: coordinator, factSink: source.sink)
            surfaceManager.routing = routing

            let pane = makeZmxPane(
                coordinator: coordinator, sessionID: sessionID, launchDirectory: URL(fileURLWithPath: "/tmp"))
            let paneID = pane.id

            // Spawn the real session independently: the surface manager
            // double never runs a real command. Held at `cat holdFIFOPath`
            // until this test releases it below.
            _ = try harness.spawnColdRestoreSessionWithoutWaitingForSettlement(plan: plan)

            let generation = WorkspaceContentMountGeneration()
            let admission = TerminalActivationAdmission(
                generation: generation,
                descriptor: TerminalActivationDescriptor(
                    pane: pane, visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: UUIDv7.generate())),
                attempt: 1,
                restoreKind: .cold(plan)
            )
            let authority: TerminalSurfaceCreationAuthority = .released(PaneId(existingUUID: paneID))

            let mountResult = await coordinator.mountPreparedTerminalContent(
                admission: admission,
                initialFrame: NSRect(x: 0, y: 0, width: 400, height: 300),
                authority: authority
            )
            guard case .ready(let surfaceID) = mountResult else {
                Issue.record("expected a ready mount, got \(mountResult)")
                throw ColdRestoreIntersectionTestFailure.mountDidNotSucceed
            }

            // armRestorePhase is awaited synchronously inside
            // mountPreparedTerminalContent before it ever creates the
            // surface, so the armed fact is already recorded by the time
            // the mount call above returns.
            let armedGeneration = try #require(await projector.restorePhaseGenerationsByPane[paneID])
            let surface = try #require(coordinator.viewRegistry.terminalView(for: paneID)?.ghosttySurface)
            #expect(surface.restorePhaseLatch == armedGeneration)
            // This is the synchronous latch used by real keys, paste and committed text.
            surface.endRestorePhaseIfLatched()
            routing.handler.localActionDrainScheduler.cancel(for: surfaceID)
            await routing.handler.host.drainLocalActions(
                for: surfaceID, lane: .immediate, accumulator: routing.handler.localActionAccumulator)
            #expect(await projector.isRestorePhaseActive(paneID: paneID) == false)

            // Release: the script's only in-process exec follows.
            let writeDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
            try await closeFIFOWriteDescriptor(writeDescriptor)
            try? FileManager.default.removeItem(atPath: holdFIFOPath)

            return IntersectionScenario(
                harness: harness, facts: recorder, surfaceManager: surfaceManager, paneID: paneID,
                surfaceID: surfaceID
            )
        }

        @Test("early input ends the restore phase without cancelling a still-held, later-failing startup window")
        func earlyInputDoesNotCancelAFailingStartupWindow() async throws {
            let nonExecutablePath = FileManager.default.temporaryDirectory
                .appending(path: "intersection-non-executable-shell-\(UUIDv7.generate().uuidString)")
            try "not a script".write(to: nonExecutablePath, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: nonExecutablePath) }

            let scenario = try await runIntersectionScenario(loginShell: nonExecutablePath)

            var bodyError: (any Error)?
            do {
                // Order proof: the phase end must be recorded before the
                // startup window's own outcome -- failing if reversed.
                let endedFact = try await scenario.facts.expectNext(
                    in: scenario.paneID,
                    where: {
                        if case .restorePhaseEnded = $0 { return true }
                        return false
                    },
                    "restorePhaseEnded"
                )
                guard case .restorePhaseEnded = endedFact else {
                    Issue.record("expected restorePhaseEnded, got \(endedFact)")
                    throw ColdRestoreIntersectionTestFailure.mountDidNotSucceed
                }
                try await scenario.facts.expectNext(
                    in: scenario.paneID, .coldStartOutcome(.failed(.exitedBeforeHandoff(exitStatus: nil))))

                #expect(scenario.surfaceManager.reportedFailures.count == 1)
                #expect(scenario.surfaceManager.reportedFailures.first?.paneID == scenario.paneID)
            } catch {
                bodyError = error
            }
            await scenario.surfaceManager.routing?.closeAndJoin()
            _ = await scenario.harness.cleanup()
            if let bodyError { throw bodyError }
        }

        @Test("early input ends the restore phase; a normal handoff still settles after it")
        func earlyInputDoesNotPreventANormalHandoff() async throws {
            let scenario = try await runIntersectionScenario(loginShell: URL(fileURLWithPath: "/bin/bash"))

            var bodyError: (any Error)?
            do {
                let endedFact = try await scenario.facts.expectNext(
                    in: scenario.paneID,
                    where: {
                        if case .restorePhaseEnded = $0 { return true }
                        return false
                    },
                    "restorePhaseEnded"
                )
                guard case .restorePhaseEnded = endedFact else {
                    Issue.record("expected restorePhaseEnded, got \(endedFact)")
                    throw ColdRestoreIntersectionTestFailure.mountDidNotSucceed
                }
                try await scenario.facts.expectNext(in: scenario.paneID, .coldStartOutcome(.handedOff))

                #expect(scenario.surfaceManager.reportedFailures.isEmpty)
            } catch {
                bodyError = error
            }
            await scenario.surfaceManager.routing?.closeAndJoin()
            _ = await scenario.harness.cleanup()
            if let bodyError { throw bodyError }
        }
    }
}

private enum ColdRestoreIntersectionTestFailure: Error {
    case mountDidNotSucceed
}
