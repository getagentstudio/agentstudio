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

    @Test("explicit repository update joins sufficient active local work without a follower")
    func explicitRepositoryUpdateJoinsSufficientActiveWork() async throws {
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
        await statusGate.releaseFirst()

        #expect(await lease.settlement() == .completed)
        #expect(await statusGate.callCount == 1)
        await actor.shutdown()
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
        let settlementContinuation = try #require(
            await actor.explicitRepositoryUpdateAttemptsById[lease.attemptId]?.settlement.continuation
        )
        // Observe the owner's actual finish synchronously, without a task that
        // may record lease delivery only after the provider has been released.
        #expect(settlementContinuation.onTermination == nil)
        settlementContinuation.onTermination = cancellationProbe.recordSettlementTermination
        let cancellationOpening = await facts.mark(cancellationProbe.cancellationWindow)
        let refreshOpening = await facts.mark(cancellationProbe.refreshWindow)
        let shutdownTask = Task { await actor.shutdown() }

        await #expect(throws: Never.self) {
            try await facts.expectNone(
                of: { $0 == .settlementStreamTerminated }, "settlement before held provider cancellation",
                from: cancellationOpening, closedBy: { $0 == .providerCancellationRequested }
            )
        }
        try await providerStep.cancellationObserved()
        providerStep.release()
        await shutdownTask.value

        await #expect(throws: Never.self) {
            try await facts.expectNone(
                of: { $0 == .settlementStreamTerminated }, "settlement before provider drain closed",
                from: refreshOpening, closedBy: { $0 == .projector(.refreshClosed(.shutdown)) }
            )
        }
        #expect(await lease.settlement() == .cancelled)
        #expect(cancellationProbe.finishedSettlementCount == 1)
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

    @Test("explicit repository update retains one full follower behind insufficient active local work")
    func explicitRepositoryUpdateFollowsInsufficientActiveWork() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let statusGate = ExplicitUpdateStatusGate()
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
        #expect(await lease.settlement() == .completed)
        #expect(await statusGate.callCount == 2)
        await actor.shutdown()
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
                await statusGate.recordAndWaitIfFirst(rootPath)
                return returnsStatus ? Self.cleanStatus : nil
            },
            coalescingWindow: .zero,
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
    case settlementStreamTerminated
}

/// Adapts synchronous owner callbacks into correlated negative windows. Normal
/// settlement follows the refresh close, so it is recorded only in open windows.
private final class ExplicitUpdateCancellationProbe: Sendable {
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

    var finishedSettlementCount: Int { state.withLock { $0.finishedSettlementCount } }

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

    func recordSettlementTermination(
        _ termination: AsyncStream<RepositoryFactSourceUpdateOutcome>.Continuation.Termination
    ) {
        state.withLock { state in
            if case .finished = termination { state.finishedSettlementCount += 1 }
            if !state.cancellationObserved { source.sink(cancellationWindow, .settlementStreamTerminated) }
            if !state.refreshClosed { source.sink(refreshWindow, .settlementStreamTerminated) }
        }
    }

    private struct ObservationState {
        var cancellationObserved = false
        var refreshClosed = false
        var finishedSettlementCount = 0
    }
}

private actor ExplicitUpdateStatusGate {
    private var rootPaths: [URL] = []
    private let firstCallArrival = HeldStep<Int>("explicit update first status provider call")

    var callCount: Int { rootPaths.count }

    func recordAndWaitIfFirst(_ rootPath: URL) async {
        rootPaths.append(rootPath)
        let callNumber = rootPaths.count
        if callNumber == 1 {
            try? await firstCallArrival.arrive(callNumber)
        }
    }

    func waitForFirstArrival() async throws -> Int {
        try await firstCallArrival.firstArrival()
    }

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
