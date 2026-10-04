import AgentStudioTestHarness
import Foundation
import Synchronization

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Captures the cache image synchronously at the owner's receipt, before another commit.
@MainActor
final class WorkspaceCacheApplicationRecorder {
    struct Observation: Sendable {
        let outcome: WorkspaceCacheCoordinatorFact
        let repository: RepoEnrichment?
        let worktree: WorktreeEnrichment?
        let pullRequests: [RepoBranchKey: PullRequestFacts]
        let isLoading: Bool
    }

    private let source = LocalFactSource<WorkspaceCacheApplicationScope, Observation>(
        vocabulary: FactVocabulary(
            describeScope: { String(describing: $0) },
            describeFact: { String(describing: $0) },
            isClosing: { _, _ in true }))
    let facts: FactRecorder<WorkspaceCacheApplicationScope, Observation>
    private let cache: RepoCacheAtom

    init(cache: RepoCacheAtom) throws {
        self.cache = cache
        facts = try source.attach()
    }

    var sink: WorkspaceCacheCoordinatorFactSink {
        { [source, cache] scope, outcome in
            source.sink(
                scope,
                Observation(
                    outcome: outcome, repository: cache.repoEnrichment(for: scope.repositoryID),
                    worktree: scope.worktreeID.flatMap { cache.worktreeEnrichment(for: $0) },
                    pullRequests: cache.pullRequestFactsSnapshot(),
                    isLoading: cache.isPullRequestLoading(forRepository: scope.repositoryID)))
        }
    }

    @discardableResult
    func expectApplied(
        repositoryID: UUID? = nil, kind: WorkspaceCacheApplicationScope.Kind,
        worktreeID: UUID? = nil,
        matching matches: @escaping @Sendable (Observation) -> Bool = { _ in true },
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> Observation {
        // Loading, superseded and ignored operations are real terminal facts. Consume
        // each in order instead of pretending discovery skips an unmatched opening.
        while true {
            let description = "cache operation \(kind) for \(String(describing: repositoryID))"
            let matchesScope: @Sendable (WorkspaceCacheApplicationScope) -> Bool = {
                (repositoryID == nil || $0.repositoryID == repositoryID) && $0.kind == kind
                    && (worktreeID == nil || $0.worktreeID == worktreeID)
            }
            let scope = try await facts.expectNextOperation(
                matching: matchesScope, opening: { _ in true }, description,
                fileID: fileID, line: line, function: function)
            let observation = try await facts.expectNext(
                in: scope, where: { _ in true }, "post-application cache disposition",
                fileID: fileID, line: line, function: function)
            if observation.outcome == .applied, matches(observation) { return observation }
        }
    }

    func expectDisposition(
        repositoryID: UUID, sequence: UInt64, kind: WorkspaceCacheApplicationScope.Kind,
        _ outcome: WorkspaceCacheCoordinatorFact
    ) async throws {
        let scope = try await facts.expectNextOperation(
            matching: { $0.repositoryID == repositoryID && $0.envelopeSequence == sequence && $0.kind == kind },
            opening: { _ in true }, "cache operation \(sequence) \(outcome)")
        _ = try await facts.expectNext(in: scope, where: { $0.outcome == outcome }, "cache disposition \(outcome)")
    }

    func finish() async throws { try await facts.finish() }
}

/// Holds this governor's exact tick before backing-clock registration; no sleeper counting.
final class HeldCacheApplyClock: Clock, Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = TestPushClock.Instant
    let backing = TestPushClock()
    private let ticks: Mutex<[HeldStep<Instant>]>
    init(tick: HeldStep<Instant>) { ticks = Mutex([tick]) }
    init(ticks: [HeldStep<Instant>]) { self.ticks = Mutex(ticks) }
    var now: Instant { backing.now }
    var minimumResolution: Duration { backing.minimumResolution }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let tick = ticks.withLock { pending -> HeldStep<Instant>? in
            pending.isEmpty ? nil : pending.removeFirst()
        }
        guard let tick else { throw CancellationError() }
        try await tick.arrive(deadline)
        try await backing.sleep(until: deadline, tolerance: tolerance)
    }
}

/// Every receipt observer and held clock is closed before the case returns, including failures.
@MainActor
func withCacheApplicationWorld(
    coordinator: WorkspaceCacheCoordinator,
    applications: WorkspaceCacheApplicationRecorder,
    heldTicks: [HeldStep<TestPushClock.Instant>] = [],
    operation: @MainActor () async throws -> Void
) async throws {
    await coordinator.startConsuming()
    do {
        try await operation()
        for tick in heldTicks { tick.retire() }
        await coordinator.shutdown()
        try await applications.finish()
    } catch {
        for tick in heldTicks { tick.retire() }
        await coordinator.shutdown()
        try? await applications.finish()
        throw error
    }
}
