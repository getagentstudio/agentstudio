import AgentStudioTestHarness
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("WorkspaceSurfaceCoordinator cold start observation", .serialized)
struct ColdStartObservationWiringTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    /// Fails Stage 1 registration immediately (`EACCES`), settling
    /// `.unobservable(.watchRegistrationFailed(errno:))` without touching a
    /// real filesystem or process -- the same double
    /// `ColdStartObserverTests` uses for its registration-failure case.
    private final class ScriptedFailingSyscalls: ColdStartObserverSyscalls, @unchecked Sendable {
        func openDirectoryForWatching(path: String) -> Result<Int32, POSIXErrorNumber> {
            .failure(POSIXErrorNumber(EACCES))
        }

        func readProcessArgumentsBuffer(pid: Int32) -> Result<[UInt8], POSIXErrorNumber> {
            .failure(POSIXErrorNumber(ESRCH))
        }

        // Never reached: openDirectoryForWatching's EACCES settles this
        // window before discovery gets as far as a connect attempt.
        func observeSession(path: String, bootID: String) -> ZmxDiscoveryObservation {
            .failure(.unavailable)
        }

        // Never reached, for the same reason.
        func leaderState(of incarnation: ZmxProcessIncarnation) -> ColdStartLeaderState {
            .unverifiable(POSIXErrorNumber(ESRCH))
        }

        // Never reached: openDirectoryForWatching's EACCES means no
        // directory watch source -- and so no descriptor -- ever exists to
        // close. R1 gate (Lead 2026-10-01, FAIL 1 fix 1): added when
        // `ColdStartObserverSyscalls` gained this requirement.
        func closeWatchedDirectory(_ descriptor: Int32) {}
    }

    private func vocabulary() -> FactVocabulary<UUID, ColdStartOutcome> {
        FactVocabulary(
            describeScope: { $0.uuidString },
            describeFact: { String(describing: $0) },
            // Every outcome is a pane's one and only cold-start fact.
            isClosing: { _, _ in true }
        )
    }

    private func makeCoordinator() throws -> WorkspaceSurfaceCoordinator {
        let store = try makeWorkspaceJournalTestStore()
        return WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: TerminalRestoreCapturingSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }

    private func makePlan(
        zmxDirectoryPath: String = "/tmp/agentstudio-cold-start-observation-test",
        attemptID: ColdRestoreAttemptID = .generate()
    ) -> TerminalColdRestorePlan {
        TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: "/usr/local/bin/zmx"),
            zmxDirectory: URL(fileURLWithPath: zmxDirectoryPath),
            sessionID: ZmxSessionID(restoring: "as-cold-start-observation-test")!,
            loginShell: URL(fileURLWithPath: "/bin/zsh"),
            folderCandidates: [URL(fileURLWithPath: "/tmp")],
            notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
            replayFile: nil,
            resume: nil,
            attemptID: attemptID
        )
    }

    @Test("a cold pane's outcome reaches the fact sink, and its task self-removes from the coordinator")
    func oneColdPaneReachesItsOutcome() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.coldStartObservationFactSink = source.sink
        let paneID = UUID()

        // Act
        coordinator.beginObservingColdStart(
            paneID: paneID,
            plan: makePlan(),
            observer: ColdStartObserver(syscalls: ScriptedFailingSyscalls())
        )

        // Assert
        try await recorder.expectNext(in: paneID, .unobservable(.watchRegistrationFailed(errno: EACCES)))
        #expect(coordinator.coldStartObservationTasksByPaneID[paneID] == nil)
    }

    @Test("20 cold panes each reach their own outcome independently, and the task dictionary drains to empty")
    func manyColdPanesEachReachTheirOwnOutcome() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.coldStartObservationFactSink = source.sink
        let paneIDs = (0..<20).map { _ in UUID() }

        // Act
        for paneID in paneIDs {
            coordinator.beginObservingColdStart(
                paneID: paneID,
                plan: makePlan(),
                observer: ColdStartObserver(syscalls: ScriptedFailingSyscalls())
            )
        }

        // Assert: every one of the 20 panes gets its own outcome fact --
        // order between panes isn't asserted, since each pane is its own
        // scope and this proves independence, not sequencing.
        for paneID in paneIDs {
            try await recorder.expectNext(in: paneID, .unobservable(.watchRegistrationFailed(errno: EACCES)))
        }
        #expect(coordinator.coldStartObservationTasksByPaneID.isEmpty)
    }

    @Test("retirement cancels a still-pending observation, settling its outcome and removing its owned task")
    func retirementCancelsAPendingObservationTask() async throws {
        // Arrange: a real, empty directory whose socket never appears, so
        // discovery genuinely cannot complete on its own -- the same
        // technique `ColdStartObserverTests
        // .attachClientExitSettlesPendingDiscoveryAsFailed` uses to make the
        // race deterministic instead of racing real time.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-cold-start-observation-retirement-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.coldStartObservationFactSink = source.sink
        let paneID = UUID()
        let observer = ColdStartObserver()
        // Mirrors `mountPreparedTerminalContent`'s real registration order:
        // production always registers with the exit-bridge binding before
        // `beginObservingColdStart`, which is what makes
        // `retirePanesPermanently`'s `cancelPendingColdStart` call resolve
        // this observer's continuation instead of no-op'ing.
        coordinator.coldStartAttachExitBinding.register(paneID: paneID, observer: observer)

        // Act
        coordinator.beginObservingColdStart(
            paneID: paneID,
            plan: makePlan(zmxDirectoryPath: temporaryDirectory.path),
            observer: observer
        )
        #expect(coordinator.coldStartObservationTasksByPaneID[paneID] != nil)
        coordinator.retirePanesPermanently([paneID])

        // Assert
        try await recorder.expectNext(in: paneID, .unobservable(.identityUnverifiable))
        #expect(coordinator.coldStartObservationTasksByPaneID[paneID] == nil)
    }
}
