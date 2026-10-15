import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

@Suite("GitWorkingDirectoryProjector explicit updates")
struct GitWorkingDirectoryProjectorExplicitUpdateTests {
    @Test("one explicit transition flushes owner telemetry without aggregate traffic")
    func explicitTransitionFlushesOwnerTelemetryImmediately() async throws {
        let recorder = ExplicitUpdateGitPerformanceRecorder()
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/explicit-local-telemetry-\(worktreeID)")
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in Self.cleanStatus },
            coalescingWindow: .zero,
            performanceTraceRecorder: recorder,
            pathExistenceProbe: { _ in true }
        )
        await register(actor: actor, repositoryID: repositoryID, worktreeID: worktreeID, rootPath: rootPath)

        let lease = try #require(
            await actor.startExplicitRepositoryUpdate(repoId: repositoryID, attemptId: UUIDv7.generate())
                .acceptedLease
        )
        #expect(recorder.snapshots.contains { $0.explicitAdmitted == 1 })
        #expect(await lease.settlement() == .completed)
        #expect(recorder.snapshots.contains { $0.explicitSettledCompleted == 1 })
        await actor.shutdown()
    }

    @Test("explicit repository update joins sufficient active local work without a follower", arguments: [true, false])
    func explicitRepositoryUpdateJoinsSufficientActiveWork(failStatus: Bool) async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let statusGate = ExplicitUpdateStatusGate()
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/explicit-local-join-\(worktreeID)")
        let actor = makeActor(statusGate: statusGate, returnsStatus: true, factSink: source.sink)
        await register(actor: actor, repositoryID: repositoryID, worktreeID: worktreeID, rootPath: rootPath)
        await actor.enqueueImmediateRefresh(
            FileChangeset(
                worktreeId: worktreeID,
                repoId: repositoryID,
                rootPath: rootPath,
                paths: ["tracked.txt"],
                timestamp: ContinuousClock().now,
                batchSeq: 1
            ),
            triggerSource: .visibilityChange,
            isExplicit: true
        )
        try await facts.expectRefreshStarted(worktreeId: worktreeID, requestSequence: 1)
        #expect(try await statusGate.waitForFirstArrival() == 1)

        let lease = try #require(
            await actor.startExplicitRepositoryUpdate(repoId: repositoryID, attemptId: UUIDv7.generate())
                .acceptedLease
        )
        if failStatus { await statusGate.failFirst() } else { await statusGate.releaseFirst() }

        #expect(await lease.settlement() == (failStatus ? .failed : .completed))
        #expect(await statusGate.callCount == 1)
        await actor.shutdown()
        try await facts.finish()
    }

    @Test("explicit repository update reports a genuine local status failure")
    func explicitRepositoryUpdateReportsStatusFailure() async throws {
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/explicit-local-failure-\(worktreeID)")
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            pathExistenceProbe: { _ in true }
        )
        await register(actor: actor, repositoryID: repositoryID, worktreeID: worktreeID, rootPath: rootPath)

        let lease = try #require(
            await actor.startExplicitRepositoryUpdate(repoId: repositoryID, attemptId: UUIDv7.generate())
                .acceptedLease
        )

        #expect(await lease.settlement() == .failed)
        await actor.shutdown()
    }

    @Test("explicit repository update cancellation settles after local provider return")
    func explicitRepositoryUpdateCancellationWaitsForProviderReturn() async throws {
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let attemptID = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/explicit-local-cancellation-\(worktreeID)")
        let refreshScope = GitProjectorScope.refresh(worktreeId: worktreeID, requestSequence: 1)
        let cancellationProbe = ExplicitUpdateCancellationProbe(attemptID: attemptID, refreshScope: refreshScope)
        let facts = try cancellationProbe.source.attach()
        let providerStep = HeldStep<URL>(
            "explicit update local provider return", cancellation: .holdThroughCancellation
        )
        defer { providerStep.release() }
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { rootPath in
                await withTaskCancellationHandler {
                    try? await providerStep.arrive(rootPath)
                    return Self.cleanStatus
                } onCancel: {
                    cancellationProbe.recordProviderCancellation()
                }
            },
            coalescingWindow: .zero,
            performanceTraceRecorder: cancellationProbe,
            factSink: cancellationProbe.recordProjectorFact,
            pathExistenceProbe: { _ in true }
        )
        // This attempt owns one provider call; registration's automatic refresh
        // must not race its admission or contribute unrelated provider events.
        await actor.setAutomaticEligibleWorktrees([])
        await register(actor: actor, repositoryID: repositoryID, worktreeID: worktreeID, rootPath: rootPath)

        let lease = try #require(
            await actor.startExplicitRepositoryUpdate(repoId: repositoryID, attemptId: attemptID).acceptedLease
        )
        try await facts.expectNext(in: cancellationProbe.refreshWindow, .projector(.refreshAdmitted))
        try await facts.expectNext(in: cancellationProbe.refreshWindow, .projector(.refreshStarted))
        #expect(try await providerStep.firstArrival() == rootPath)
        #expect(lease.attemptId == attemptID)
        #expect(lease.source == .localGit)
        #expect(cancellationProbe.recordedAdmissionCount == 1)
        let cancellationOpening = await facts.mark(cancellationProbe.cancellationWindow)
        let refreshOpening = await facts.mark(cancellationProbe.refreshWindow)
        let shutdownTask = Task { await actor.shutdown() }

        await #expect(throws: Never.self) {
            try await facts.expectNone(
                of: { $0 == .ownerSettlementRecorded }, "settlement before held provider cancellation",
                from: cancellationOpening, closedBy: { $0 == .providerCancellationRequested }
            )
        }
        try await providerStep.cancellationObserved()
        providerStep.release()
        await shutdownTask.value

        await #expect(throws: Never.self) {
            try await facts.expectNone(
                of: { $0 == .ownerSettlementRecorded }, "settlement before provider drain closed",
                from: refreshOpening, closedBy: { $0 == .projector(.refreshClosed(.shutdown)) }
            )
        }
        #expect(await lease.settlement() == .cancelled)
        #expect(cancellationProbe.recordedSettlementCount == 1)
        #expect(cancellationProbe.recordedCancelledSettlementCount == 1)
        #expect(providerStep.recordedArrivals == [rootPath])
        try await facts.finish()
    }

    @Test("explicit repository update remains unsettled across local capacity retry")
    func explicitRepositoryUpdateRemainsUnsettledAcrossCapacityRetry() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let eventRecorder = ExplicitUpdateSettlementEventRecorder()
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/explicit-local-capacity-\(worktreeID)")
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: ExplicitUpdateCapacityProvider(),
            coalescingWindow: .zero,
            factSink: source.sink,
            pathExistenceProbe: { _ in true }
        )
        await register(actor: actor, repositoryID: repositoryID, worktreeID: worktreeID, rootPath: rootPath)

        let lease = try #require(
            await actor.startExplicitRepositoryUpdate(repoId: repositoryID, attemptId: UUIDv7.generate())
                .acceptedLease
        )
        let settlementTask = Task {
            let outcome = await lease.settlement()
            await eventRecorder.record(.settled(outcome))
        }
        try await facts.expectNext(
            in: .capacity(worktreeId: worktreeID, episode: 1), .capacityRetryScheduled
        )
        #expect(await actor.capacityRetryWorktreeIds == Set([worktreeID]))
        #expect(await eventRecorder.events.isEmpty)

        await actor.shutdown()
        await settlementTask.value
        #expect(await eventRecorder.events == [.settled(.cancelled)])
    }

    @Test("explicit repository update without registered worktrees is not applicable")
    func explicitRepositoryUpdateWithoutWorktreesIsNotApplicable() async {
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero
        )

        let admission = await actor.startExplicitRepositoryUpdate(
            repoId: UUIDv7.generate(),
            attemptId: UUIDv7.generate()
        )

        #expect(admission.acceptedLease == nil)
        await actor.shutdown()
    }

    @Test(
        "explicit repository update retains one full follower behind insufficient active local work",
        arguments: [true, false])
    func explicitRepositoryUpdateFollowsInsufficientActiveWork(failStatus: Bool) async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let followerStep = HeldStep<Int>("explicit full follower provider")
        let statusGate = ExplicitUpdateStatusGate(secondCallArrival: followerStep)
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/explicit-local-follower-\(worktreeID)")
        let actor = makeActor(statusGate: statusGate, returnsStatus: true, factSink: source.sink)
        await register(actor: actor, repositoryID: repositoryID, worktreeID: worktreeID, rootPath: rootPath)
        await actor.enqueueImmediateRefresh(
            FileChangeset(
                worktreeId: worktreeID,
                rootPath: rootPath,
                paths: ["tracked.txt"],
                timestamp: ContinuousClock().now,
                batchSeq: 1
            ),
            triggerSource: .filesystemChange
        )
        try await facts.expectRefreshStarted(worktreeId: worktreeID, requestSequence: 1)
        #expect(try await statusGate.waitForFirstArrival() == 1)

        let lease = try #require(
            await actor.startExplicitRepositoryUpdate(repoId: repositoryID, attemptId: UUIDv7.generate())
                .acceptedLease
        )
        await statusGate.releaseFirst()

        try await facts.expectRefreshStarted(worktreeId: worktreeID, requestSequence: 2)
        #expect(try await followerStep.firstArrival() == 2)
        if failStatus { followerStep.fail(ExplicitUpdateStatusFailure.unavailable) } else { followerStep.release() }
        #expect(await lease.settlement() == (failStatus ? .failed : .completed))
        #expect(await statusGate.callCount == 2)
        await actor.shutdown()
        try await facts.finish()
    }

    @Test("cold explicit repository update admits before local physical settlement")
    func coldExplicitRepositoryUpdateAdmitsBeforePhysicalSettlement() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let statusGate = ExplicitUpdateStatusGate()
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/explicit-local-\(worktreeID)")
        let actor = makeActor(statusGate: statusGate, returnsStatus: true, factSink: source.sink)
        await register(actor: actor, repositoryID: repositoryID, worktreeID: worktreeID, rootPath: rootPath)
        await actor.setAutomaticEligibleWorktrees([])

        let lease = try #require(
            await actor.startExplicitRepositoryUpdate(repoId: repositoryID, attemptId: UUIDv7.generate())
                .acceptedLease
        )

        try await facts.expectRefreshStarted(worktreeId: worktreeID, requestSequence: 1)
        #expect(try await statusGate.waitForFirstArrival() == 1)
        await statusGate.releaseFirst()
        #expect(await lease.settlement() == .completed)
        await actor.shutdown()
    }

    private static let cleanStatus = GitWorkingTreeStatus(
        summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
        branch: "main",
        origin: nil
    )

    private func makeActor(
        statusGate: ExplicitUpdateStatusGate,
        returnsStatus: Bool,
        factSink: GitProjectorFactSink? = nil
    ) -> GitWorkingDirectoryProjector {
        GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { rootPath in
                let succeeded = await statusGate.recordAndWaitIfFirst(rootPath)
                return returnsStatus && succeeded ? Self.cleanStatus : nil
            },
            coalescingWindow: .zero,
            sleepClock: TestPushClock(),
            factSink: factSink,
            pathExistenceProbe: { _ in true }
        )
    }

    private func register(
        actor: GitWorkingDirectoryProjector,
        repositoryID: UUID,
        worktreeID: UUID,
        rootPath: URL
    ) async {
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeID: WorktreeFilesystemContext(repoId: repositoryID, rootPath: rootPath)
                ]
            )
        )
    }
}

private final class ExplicitUpdateGitPerformanceRecorder: GitProjectorPerformanceRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSnapshots: [GitWorkingDirectoryPerformanceSnapshot] = []

    var isEnabled: Bool { true }
    var snapshots: [GitWorkingDirectoryPerformanceSnapshot] { lock.withLock { recordedSnapshots } }

    func record(
        _: AgentStudioPerformanceTraceRecorder.Event,
        attributes _: @autoclosure () -> [String: AgentStudioTraceValue]
    ) {}

    func recordDuration(
        _: AgentStudioPerformanceTraceRecorder.Event,
        duration _: Duration,
        attributes _: @autoclosure () -> [String: AgentStudioTraceValue]
    ) {}

    func recordGitWorkingDirectoryPerformanceSnapshot(
        _ snapshot: GitWorkingDirectoryPerformanceSnapshot
    ) {
        lock.withLock { recordedSnapshots.append(snapshot) }
    }
}

private enum ExplicitUpdateCancellationScope: Hashable, Sendable {
    case cancellation(attemptID: UUID)
    case refresh(attemptID: UUID, scope: GitProjectorScope)
}

private enum ExplicitUpdateCancellationFact: Equatable, Sendable {
    case projector(GitProjectorFact)
    case providerCancellationRequested
    case ownerSettlementRecorded
}

/// Adapts synchronous owner callbacks into correlated negative windows.
/// Cancellation settlement follows the refresh close in this sole-attempt fixture.
private final class ExplicitUpdateCancellationProbe: GitProjectorPerformanceRecording {
    let cancellationWindow: ExplicitUpdateCancellationScope
    let refreshWindow: ExplicitUpdateCancellationScope
    let source = LocalFactSource(
        vocabulary: FactVocabulary<ExplicitUpdateCancellationScope, ExplicitUpdateCancellationFact>(
            describeScope: { String(describing: $0) },
            describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                switch fact {
                case .providerCancellationRequested, .projector(.refreshClosed): true
                default: false
                }
            }
        )
    )
    private let refreshScope: GitProjectorScope
    private let state = Mutex(ObservationState())

    init(attemptID: UUID, refreshScope: GitProjectorScope) {
        self.refreshScope = refreshScope
        cancellationWindow = .cancellation(attemptID: attemptID)
        refreshWindow = .refresh(attemptID: attemptID, scope: refreshScope)
    }

    var isEnabled: Bool { true }
    var recordedAdmissionCount: UInt64 { state.withLock { $0.recordedAdmissionCount } }
    var recordedSettlementCount: UInt64 { state.withLock { $0.recordedSettlementCount } }
    var recordedCancelledSettlementCount: UInt64 { state.withLock { $0.recordedCancelledSettlementCount } }

    func record(
        _: AgentStudioPerformanceTraceRecorder.Event,
        attributes _: @autoclosure () -> [String: AgentStudioTraceValue]
    ) {}

    func recordDuration(
        _: AgentStudioPerformanceTraceRecorder.Event,
        duration _: Duration,
        attributes _: @autoclosure () -> [String: AgentStudioTraceValue]
    ) {}

    func recordProjectorFact(scope: GitProjectorScope, fact: GitProjectorFact) {
        guard scope == refreshScope else { return }
        state.withLock { state in
            source.sink(refreshWindow, .projector(fact))
            if case .refreshClosed = fact { state.refreshClosed = true }
        }
    }

    func recordProviderCancellation() {
        state.withLock { state in
            source.sink(cancellationWindow, .providerCancellationRequested)
            state.cancellationObserved = true
        }
    }

    func recordGitWorkingDirectoryPerformanceSnapshot(
        _ snapshot: GitWorkingDirectoryPerformanceSnapshot
    ) {
        // Both explicit settlement paths synchronously flush these counters
        // before resolve() yields. The lease reader cannot own this callback.
        let settlementCount =
            snapshot.explicitSettledCompleted + snapshot.explicitSettledFailed
            + snapshot.explicitSettledObsolete + snapshot.explicitSettledCancelled
        state.withLock { state in
            state.recordedAdmissionCount += snapshot.explicitAdmitted
            state.recordedSettlementCount += settlementCount
            state.recordedCancelledSettlementCount += snapshot.explicitSettledCancelled
            guard settlementCount > 0 else { return }
            if !state.cancellationObserved { source.sink(cancellationWindow, .ownerSettlementRecorded) }
            if !state.refreshClosed { source.sink(refreshWindow, .ownerSettlementRecorded) }
        }
    }

    private struct ObservationState {
        var cancellationObserved = false
        var refreshClosed = false
        var recordedAdmissionCount: UInt64 = 0
        var recordedSettlementCount: UInt64 = 0
        var recordedCancelledSettlementCount: UInt64 = 0
    }
}

private actor ExplicitUpdateStatusGate {
    private var rootPaths: [URL] = []
    private let firstCallArrival = HeldStep<Int>("explicit update first status provider call")

    var callCount: Int { rootPaths.count }

    private let secondCallArrival: HeldStep<Int>?

    init(secondCallArrival: HeldStep<Int>? = nil) { self.secondCallArrival = secondCallArrival }

    func recordAndWaitIfFirst(_ rootPath: URL) async -> Bool {
        rootPaths.append(rootPath)
        let callNumber = rootPaths.count
        do {
            if callNumber == 1 {
                try await firstCallArrival.arrive(callNumber)
            } else if callNumber == 2, let secondCallArrival {
                try await secondCallArrival.arrive(callNumber)
            }
            return true
        } catch { return false }
    }

    func waitForFirstArrival() async throws -> Int {
        try await firstCallArrival.firstArrival()
    }

    func failFirst() { firstCallArrival.fail(ExplicitUpdateStatusFailure.unavailable) }

    func releaseFirst() {
        firstCallArrival.release()
    }
}

private actor ExplicitUpdateSettlementEventRecorder {
    enum Event: Equatable {
        case providerReturned
        case settled(RepositoryFactSourceUpdateOutcome)
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}

private struct ExplicitUpdateCapacityProvider: GitWorkingTreeStatusProvider {
    func statusResult(
        for _: URL,
        pathspecs _: [String]?
    ) async -> GitWorkingTreeStatusResult {
        .unavailable(GitWorkingTreeStatusUnavailable(reason: .readCapacityExceeded))
    }
}

private enum ExplicitUpdateStatusFailure: Error { case unavailable }
