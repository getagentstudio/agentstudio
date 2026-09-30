import AgentStudioGit
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("GitWorkingDirectoryProjector exact-clean continuity")
struct GitWorkingDirectoryProjectorContinuityTests {
    @Test("verified clean checkpoint renews without facts or detail reads")
    func verifiedCleanCheckpointRenewsWithoutPhysicalReads() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let provider = VerifiedCleanProjectorProvider(initialOutcome: .clean)
        let performanceRecorder = ContinuityPerformanceRecorder()
        let actor = makeProjector(
            bus: bus, clock: clock, provider: provider,
            performanceRecorder: performanceRecorder, factSink: source.sink
        )
        await actor.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/verified-clean-\(worktreeId.uuidString)")
        await actor.setActivePaneWorktree(worktreeId: worktreeId)
        await bus.post(registrationEnvelope(sequence: 1, worktreeId: worktreeId, rootPath: rootPath))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(provider.exactFactsReadCount == 1)
        #expect(await actor.lastAcceptedStatusAtByWorktreeId[worktreeId] != nil)
        #expect(provider.detailReadCount == 0)

        let deadline = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic)
        await clock.waitForPendingSleepCount(exactly: 1)
        let renewalInterval = await facts.mark(deadline)
        clock.advance(by: .seconds(1))
        try await facts.expectNone(
            of: { $0 == .deadlineDisposition(.admitted) }, "physical refresh admitted during clean renewal",
            from: renewalInterval, closedBy: { $0 == .deadlineDisposition(.deferred) }
        )

        #expect(provider.renewalCount == 1)
        #expect(provider.exactFactsReadCount == 1)
        #expect(provider.ordinaryFactsReadCount == 0)
        #expect(provider.detailReadCount == 0)
        #expect(await actor.pendingByWorktreeId[worktreeId] == nil)
        await actor.flushAggregatePerformanceSnapshot()
        let aggregate = performanceRecorder.lastGitAggregateSnapshot
        #expect(aggregate?.exactCleanBaselinePrepared == 1)
        #expect(aggregate?.exactCleanBaselineAccepted == 1)
        #expect(aggregate?.exactCleanContinuityRenewed == 1)
        #expect(aggregate?.avoidedPhysicalFactsRead == 1)
        #expect(aggregate?.avoidedPhysicalDetailRead == 2)
        #expect(aggregate?.exactCleanAuthorityCurrent == 1)
        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
    }

    @Test("raced clean barrier triggers exactly one ordinary full fallback")
    func racedCleanBarrierTriggersOneFallback() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let provider = VerifiedCleanProjectorProvider(initialOutcome: .requiresExact)
        let performanceRecorder = ContinuityPerformanceRecorder()
        let actor = makeProjector(
            bus: bus, clock: clock, provider: provider,
            performanceRecorder: performanceRecorder, factSink: source.sink
        )
        await actor.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/verified-clean-race-\(worktreeId.uuidString)")
        await actor.setActivePaneWorktree(worktreeId: worktreeId)
        await bus.post(registrationEnvelope(sequence: 1, worktreeId: worktreeId, rootPath: rootPath))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(await actor.lastAcceptedStatusAtByWorktreeId[worktreeId] != nil)
        #expect(provider.exactFactsReadCount == 1)
        #expect(provider.ordinaryFactsReadCount == 1)
        #expect(provider.detailReadCount == 1)
        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        let aggregate = performanceRecorder.lastGitAggregateSnapshot
        #expect(aggregate?.exactCleanBaselinePrepared == 1)
        #expect(aggregate?.exactCleanBaselineRejected == 1)
        #expect(aggregate?.continuityUncertaintyEventStreamUncertain == 1)
        #expect(aggregate?.exactFallbackAdmitted == 1)
    }

    @Test("unregistration while renewal is suspended creates no fallback debt")
    func unregistrationDuringRenewalCreatesNoFallbackDebt() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let renewalStep = HeldStep<Void>("clean renewal before unregistration", cancellation: .holdThroughCancellation)
        let provider = VerifiedCleanProjectorProvider(initialOutcome: .clean, renewalStep: renewalStep)
        let actor = makeProjector(bus: bus, clock: clock, provider: provider, factSink: source.sink)
        await actor.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/verified-clean-remove-\(worktreeId.uuidString)")
        await actor.setActivePaneWorktree(worktreeId: worktreeId)
        await bus.post(registrationEnvelope(sequence: 1, worktreeId: worktreeId, rootPath: rootPath))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        let deadline = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic)
        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(await actor.exactCleanAuthorityByWorktreeId[worktreeId] != nil)

        clock.advance(by: .seconds(1))
        _ = try await renewalStep.firstArrival()
        await bus.post(unregistrationEnvelope(sequence: 2, worktreeId: worktreeId))
        #expect(try await facts.expectHandledEnvelope(seq: 2) == .routed)
        renewalStep.release()
        try await facts.expectNext(in: deadline, .deadlineDisposition(.obsolete))

        #expect(await actor.rootPathByWorktreeId[worktreeId] == nil)
        #expect(provider.exactFactsReadCount == 1)
        #expect(provider.ordinaryFactsReadCount == 0)
        #expect(await actor.pendingByWorktreeId[worktreeId] == nil)
        #expect(await actor.automaticRefreshDeadlineByWorktreeId[worktreeId] == nil)
        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
    }

    @Test("renewal uncertainty triggers one exact fallback and restores authority")
    func renewalUncertaintyTriggersOneFallback() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let provider = VerifiedCleanProjectorProvider(initialOutcome: .clean, renewalOutcome: .requiresExact)
        let performanceRecorder = ContinuityPerformanceRecorder()
        let actor = makeProjector(
            bus: bus, clock: clock, provider: provider,
            performanceRecorder: performanceRecorder, factSink: source.sink
        )
        await actor.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/verified-clean-uncertain-\(worktreeId.uuidString)")
        await actor.setActivePaneWorktree(worktreeId: worktreeId)
        await bus.post(registrationEnvelope(sequence: 1, worktreeId: worktreeId, rootPath: rootPath))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        let deadline = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic)
        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(await actor.exactCleanAuthorityByWorktreeId[worktreeId] != nil)

        clock.advance(by: .seconds(1))
        try await facts.expectNext(in: deadline, .deadlineDisposition(.admitted))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)

        #expect(provider.renewalCount == 1)
        #expect(provider.exactFactsReadCount == 2)
        #expect(provider.ordinaryFactsReadCount == 0)
        #expect(provider.detailReadCount == 0)
        #expect(await actor.exactCleanAuthorityByWorktreeId[worktreeId] != nil)
        #expect(await actor.pendingByWorktreeId[worktreeId] == nil)
        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        let aggregate = performanceRecorder.lastGitAggregateSnapshot
        #expect(aggregate?.exactCleanBaselinePrepared == 2)
        #expect(aggregate?.exactCleanBaselineAccepted == 2)
        #expect(aggregate?.continuityUncertaintyEventStreamUncertain == 1)
        #expect(aggregate?.exactFallbackAdmitted == 1)
        #expect(aggregate?.avoidedPhysicalFactsRead == 0)
        #expect(aggregate?.avoidedPhysicalDetailRead == 2)
    }

    @Test("filesystem mutation records one authority invalidation")
    func filesystemMutationRecordsOneAuthorityInvalidation() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let provider = VerifiedCleanProjectorProvider(initialOutcome: .clean)
        let performanceRecorder = ContinuityPerformanceRecorder()
        let actor = makeProjector(
            bus: bus, clock: clock, provider: provider,
            performanceRecorder: performanceRecorder, factSink: source.sink
        )
        await actor.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/verified-clean-mutation-\(worktreeId.uuidString)")
        await actor.setActivePaneWorktree(worktreeId: worktreeId)
        await bus.post(registrationEnvelope(sequence: 1, worktreeId: worktreeId, rootPath: rootPath))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(await actor.exactCleanAuthorityByWorktreeId[worktreeId] != nil)

        await bus.post(filesChangedEnvelope(sequence: 2, worktreeId: worktreeId, rootPath: rootPath))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(provider.ordinaryFactsReadCount == 1)
        #expect(await actor.exactCleanAuthorityByWorktreeId[worktreeId] == nil)
        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        #expect(performanceRecorder.lastGitAggregateSnapshot?.exactCleanMutationInvalidated == 1)
    }

    private func makeProjector(
        bus: EventBus<RuntimeEnvelope>,
        clock: TestPushClock,
        provider: VerifiedCleanProjectorProvider,
        performanceRecorder: ContinuityPerformanceRecorder? = nil,
        factSink: @escaping GitProjectorFactSink
    ) -> GitWorkingDirectoryProjector {
        GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                activePaneCadence: .seconds(1),
                visibleSidebarCadence: .seconds(2),
                openPaneCadence: .seconds(3),
                backgroundCadence: .seconds(4),
                lineDetailFreshnessInterval: .seconds(1)
            ),
            performanceTraceRecorder: performanceRecorder,
            factSink: factSink
        )
    }

    private func registrationEnvelope(
        sequence: UInt64,
        worktreeId: UUID,
        rootPath: URL
    ) -> RuntimeEnvelope {
        .system(
            SystemEnvelope.test(
                event: .topology(
                    .worktreeRegistered(
                        worktreeId: worktreeId,
                        repoId: worktreeId,
                        rootPath: rootPath
                    )
                ),
                source: .builtin(.filesystemWatcher),
                seq: sequence
            )
        )
    }

    private func unregistrationEnvelope(sequence: UInt64, worktreeId: UUID) -> RuntimeEnvelope {
        .system(
            SystemEnvelope.test(
                event: .topology(
                    .worktreeUnregistered(worktreeId: worktreeId, repoId: worktreeId)
                ),
                source: .builtin(.filesystemWatcher),
                seq: sequence
            )
        )
    }

    private func filesChangedEnvelope(
        sequence: UInt64,
        worktreeId: UUID,
        rootPath: URL
    ) -> RuntimeEnvelope {
        .worktree(
            WorktreeEnvelope.test(
                event: .filesystem(
                    .filesChanged(
                        changeset: FileChangeset(
                            worktreeId: worktreeId,
                            repoId: worktreeId,
                            rootPath: rootPath,
                            paths: ["Sources/Changed.swift"],
                            containsGitInternalChanges: false,
                            timestamp: ContinuousClock().now,
                            batchSeq: 1
                        )
                    )
                ),
                repoId: worktreeId,
                worktreeId: worktreeId,
                source: .system(.builtin(.filesystemWatcher)),
                seq: sequence
            )
        )
    }

}

private final class ContinuityPerformanceRecorder: GitProjectorPerformanceRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var gitAggregateSnapshots: [GitWorkingDirectoryPerformanceSnapshot] = []

    var isEnabled: Bool { true }

    var lastGitAggregateSnapshot: GitWorkingDirectoryPerformanceSnapshot? {
        lock.withLock { gitAggregateSnapshots.last }
    }

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
        lock.withLock { gitAggregateSnapshots.append(snapshot) }
    }
}

private final class VerifiedCleanProjectorProvider: GitExactCleanStatusProviding, @unchecked Sendable {
    enum InitialOutcome {
        case clean
        case requiresExact
    }

    enum RenewalOutcome {
        case renewed
        case requiresExact
    }

    private let lock = NSLock()
    private let initialOutcome: InitialOutcome
    private let renewalOutcome: RenewalOutcome
    private let renewalStep: HeldStep<Void>?
    private var _exactFactsReadCount = 0
    private var _ordinaryFactsReadCount = 0
    private var _detailReadCount = 0
    private var _renewalCount = 0

    init(
        initialOutcome: InitialOutcome,
        renewalOutcome: RenewalOutcome = .renewed,
        renewalStep: HeldStep<Void>? = nil
    ) {
        self.initialOutcome = initialOutcome
        self.renewalOutcome = renewalOutcome
        self.renewalStep = renewalStep
    }

    var exactFactsReadCount: Int { lock.withLock { _exactFactsReadCount } }
    var ordinaryFactsReadCount: Int { lock.withLock { _ordinaryFactsReadCount } }
    var detailReadCount: Int { lock.withLock { _detailReadCount } }
    var renewalCount: Int { lock.withLock { _renewalCount } }

    func statusResult(for rootPath: URL, pathspecs: [String]?) async -> GitWorkingTreeStatusResult {
        switch await statusFactsResult(for: rootPath, pathspecs: pathspecs) {
        case .available(let facts):
            .available(facts.composing(GitWorkingTreeLineDetail(linesAdded: 0, linesDeleted: 0)))
        case .unavailable(let unavailable):
            .unavailable(unavailable)
        }
    }

    func statusFactsResult(
        for _: URL,
        pathspecs _: [String]?
    ) async -> GitWorkingTreeStatusFactsResult {
        lock.withLock { _ordinaryFactsReadCount += 1 }
        return .available(Self.cleanFacts())
    }

    func lineDetailResult(for _: URL) async -> GitWorkingTreeLineDetailResult {
        lock.withLock { _detailReadCount += 1 }
        return .available(GitWorkingTreeLineDetail(linesAdded: 0, linesDeleted: 0))
    }

    func exactCleanStatusFactsResult(
        for worktreeId: UUID,
        rootPath _: URL
    ) async -> GitExactCleanStatusFactsResult {
        lock.withLock { _exactFactsReadCount += 1 }
        switch initialOutcome {
        case .clean:
            let identity = AgentStudioGit.GitStatusObservationIdentity(rawValue: "projector-test")
            let authority = GitCleanContinuityAuthority(
                registrationId: worktreeId,
                observationIdentity: identity,
                registrationGeneration: 1,
                mutationEpoch: 0,
                uncertaintyEpoch: 0
            )
            return .available(Self.cleanFacts(authority: authority))
        case .requiresExact:
            return .requiresExact(.eventStreamUncertain)
        }
    }

    func renewExactCleanAuthority(
        _ authority: GitCleanContinuityAuthority
    ) async -> GitExactCleanRenewalResult {
        lock.withLock { _renewalCount += 1 }
        if let renewalStep { try? await renewalStep.arrive(()) }
        switch renewalOutcome {
        case .renewed:
            return .renewed(authority)
        case .requiresExact:
            return .requiresExact(.eventStreamUncertain)
        }
    }

    func retireExactCleanAuthority(worktreeId _: UUID, rootPath _: URL) {}

    private static func cleanFacts(
        authority: GitCleanContinuityAuthority? = nil
    ) -> GitWorkingTreeStatusFacts {
        GitWorkingTreeStatusFacts(
            status: GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            ),
            exactCleanAuthority: authority
        )
    }
}
