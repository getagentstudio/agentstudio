import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("Workspace cache apply governor", .serialized)
struct WorkspaceCacheCoordinatorApplyGovernorTests {
    @Test("repository projection applies without receipt scope", arguments: [false, true])
    func repositoryProjectionAppliesWithoutReceiptScope(installSink: Bool) throws {
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let repo = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/cache-without-receipt-scope"))
        let lifetime = try #require(workspaceStore.repositoryTopologyAtom.repositoryObservationLifetimes[repo.id])
        let key = try #require(RepoBranchKey(repoId: repo.id, branch: "main"))
        let expected = PullRequestFacts(openCount: 2, exactOpenURL: nil)
        let sink: WorkspaceCacheCoordinatorFactSink?
        if installSink {
            sink = { _, _ in Issue.record("A missing receipt scope must not emit a fact") }
        } else {
            sink = nil
        }
        let coordinator = WorkspaceCacheCoordinator(
            bus: EventBus<RuntimeEnvelope>(), workspaceStore: workspaceStore, repoCache: repoCache,
            scopeSyncHandler: { _ in }, factSink: sink)

        coordinator.handleForgeEnrichment(
            .pullRequestRepositoryProjectionChanged(
                repoId: repo.id, projection: .stable(.ready(confirmedFactsByBranch: ["main": expected])),
                invalidatedBranches: []),
            envelopeSequence: 1, observationLifetime: .repository(lifetime), scope: nil)

        #expect(repoCache.pullRequestFacts(for: key) == expected)
        #expect(repoCache.cacheRevision == 1)
        #expect(!repoCache.isPullRequestLoading(forRepository: repo.id))
    }

    @Test("source delivery does not prove held cache application")
    func sourceDeliveryDoesNotProveCacheApplication() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let repo = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/cache-application-order"))
        let lifetime = try #require(workspaceStore.repositoryTopologyAtom.repositoryObservationLifetimes[repo.id])
        let branchKey = try #require(RepoBranchKey(repoId: repo.id, branch: "main"))
        let expected = PullRequestFacts(openCount: 1, exactOpenURL: nil)
        let tick = HeldStep<TestPushClock.Instant>("coordinator application tick")
        let clock = HeldCacheApplyClock(tick: tick)
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus, workspaceStore: workspaceStore, repoCache: repoCache,
            scopeSyncHandler: { _ in }, enrichmentApplyTickCadence: .milliseconds(25),
            enrichmentApplyClock: clock, factSink: applications.sink
        )
        try await withCacheApplicationWorld(
            coordinator: coordinator, applications: applications, heldTicks: [tick]
        ) {
            await bus.post(
                .worktree(
                    WorktreeEnvelope.test(
                        event: .forge(
                            .pullRequestRepositoryProjectionChanged(
                                repoId: repo.id,
                                projection: .stable(.ready(confirmedFactsByBranch: ["main": expected])),
                                invalidatedBranches: [])),
                        repoId: repo.id, worktreeId: nil,
                        source: .system(.service(.gitForge(provider: "stub"))), seq: 1,
                        eventId: UUIDv7.generate(), observationLifetime: .repository(lifetime))))
            let deadline = try await tick.firstArrival()
            #expect(repoCache.pullRequestFacts(for: branchKey) == nil)
            clock.backing.advance(to: deadline)
            tick.release()
            try await applications.expectApplied(repositoryID: repo.id, kind: .repositoryProjection)
            #expect(repoCache.pullRequestFacts(for: branchKey) == expected)
        }
    }

    @Test("descending sequences preserve the winning payload and settle each enqueue once")
    func descendingSequencesPreserveWinningPayload() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let repo = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/cache-descending-sequence"))
        let lifetime = try #require(workspaceStore.repositoryTopologyAtom.repositoryObservationLifetimes[repo.id])
        let key = try #require(RepoBranchKey(repoId: repo.id, branch: "main"))
        let winner = PullRequestFacts(openCount: 4, exactOpenURL: nil)
        let olderValue = PullRequestFacts(openCount: 3, exactOpenURL: nil)
        let tick = HeldStep<TestPushClock.Instant>("descending projection apply tick")
        let clock = HeldCacheApplyClock(tick: tick)
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus, workspaceStore: workspaceStore, repoCache: repoCache,
            scopeSyncHandler: { _ in }, enrichmentApplyTickCadence: .milliseconds(25),
            enrichmentApplyClock: clock, factSink: applications.sink)
        try await withCacheApplicationWorld(coordinator: coordinator, applications: applications, heldTicks: [tick]) {
            for (sequence, facts) in [(UInt64(4), winner), (UInt64(3), olderValue)] {
                await bus.post(
                    .worktree(
                        WorktreeEnvelope.test(
                            event: .forge(
                                .pullRequestRepositoryProjectionChanged(
                                    repoId: repo.id,
                                    projection: .stable(.ready(confirmedFactsByBranch: ["main": facts])),
                                    invalidatedBranches: [])),
                            repoId: repo.id, worktreeId: nil,
                            source: .system(.service(.gitForge(provider: "stub"))), seq: sequence,
                            eventId: UUIDv7.generate(), observationLifetime: .repository(lifetime))))
            }
            try await applications.expectDisposition(
                repositoryID: repo.id, sequence: 4, kind: .repositoryProjection, .superseded)
            let deadline = try await tick.firstArrival()
            clock.backing.advance(to: deadline)
            tick.release()
            try await applications.expectDisposition(
                repositoryID: repo.id, sequence: 3, kind: .repositoryProjection, .applied)
            #expect(repoCache.pullRequestFacts(for: key) == winner)
            #expect(repoCache.cacheRevision == 1)
        }
    }

    @Test("shutdown joins pending acknowledgements and reports ignored stale observations")
    func shutdownJoinsPendingAcknowledgements() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let repo = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/cache-shutdown-acknowledgement"))
        let tick = HeldStep<TestPushClock.Instant>("stale projection apply tick")
        let clock = HeldCacheApplyClock(tick: tick)
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus, workspaceStore: workspaceStore, repoCache: repoCache,
            scopeSyncHandler: { _ in }, enrichmentApplyTickCadence: .milliseconds(25),
            enrichmentApplyClock: clock, factSink: applications.sink)
        try await withCacheApplicationWorld(coordinator: coordinator, applications: applications, heldTicks: [tick]) {
            await bus.post(
                .worktree(
                    WorktreeEnvelope.test(
                        event: .forge(
                            .pullRequestRepositoryProjectionChanged(
                                repoId: repo.id, projection: .loading(baseline: .unknown, requestIdentity: 7),
                                invalidatedBranches: [])),
                        repoId: repo.id, worktreeId: nil,
                        source: .system(.service(.gitForge(provider: "stub"))), seq: 7,
                        eventId: UUIDv7.generate(), observationLifetime: .unscoped)))
            _ = try await tick.firstArrival()
            await coordinator.shutdown()
            try await applications.expectDisposition(
                repositoryID: repo.id, sequence: 7, kind: .repositoryProjection, .ignored)
            #expect(repoCache.cacheRevision == 0)
            #expect(!repoCache.isPullRequestLoading(forRepository: repo.id))
        }
    }

    @Test("repository projections coalesce by repository and apply latest sequence atomically")
    func repositoryProjectionsCoalesceAndApplyAtomically() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let tick = HeldStep<TestPushClock.Instant>("repository projection tick")
        let clock = HeldCacheApplyClock(tick: tick)
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let repo = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/apply-governor-projection-repo"))
        let repoId = repo.id
        let observationLifetime = try #require(
            workspaceStore.repositoryTopologyAtom.repositoryObservationLifetimes[repoId]
        )
        let branch = "feature/coalesced"
        let branchKey = RepoBranchKey(repoId: repoId, branch: branch)!
        let facts = PullRequestFacts(openCount: 1, exactOpenURL: nil)
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { _ in },
            enrichmentApplyTickCadence: .milliseconds(25),
            enrichmentApplyClock: clock,
            factSink: applications.sink
        )
        try await withCacheApplicationWorld(
            coordinator: coordinator, applications: applications, heldTicks: [tick]
        ) {

            await bus.post(
                .worktree(
                    WorktreeEnvelope.test(
                        event: .forge(
                            .pullRequestRepositoryProjectionChanged(
                                repoId: repoId,
                                projection: .loading(
                                    baseline: .unknown,
                                    requestIdentity: 1
                                ),
                                invalidatedBranches: []
                            )
                        ),
                        repoId: repoId,
                        worktreeId: nil,
                        source: .system(.service(.gitForge(provider: "github"))),
                        seq: 1,
                        observationLifetime: .repository(observationLifetime)
                    )
                )
            )
            await bus.post(
                .worktree(
                    WorktreeEnvelope.test(
                        event: .forge(
                            .pullRequestRepositoryProjectionChanged(
                                repoId: repoId,
                                projection: .stable(
                                    .ready(confirmedFactsByBranch: [branch: facts])
                                ),
                                invalidatedBranches: []
                            )
                        ),
                        repoId: repoId,
                        worktreeId: nil,
                        source: .system(.service(.gitForge(provider: "github"))),
                        seq: 2,
                        observationLifetime: .repository(observationLifetime)
                    )
                )
            )
            try await applications.expectDisposition(
                repositoryID: repoId, sequence: 1, kind: .repositoryProjection, .superseded)
            let deadline = try await tick.firstArrival()
            #expect(repoCache.cacheRevision == 0)

            clock.backing.advance(to: deadline)
            tick.release()
            try await applications.expectApplied(repositoryID: repoId, kind: .repositoryProjection) {
                $0.pullRequests[branchKey] == facts && !$0.isLoading
            }
        }

        #expect(repoCache.cacheRevision == 1)
        #expect(!repoCache.isPullRequestLoading(forRepository: repoId))
        #expect(repoCache.pullRequestFacts(for: branchKey) == facts)
    }

    @Test("rapid enrichment facts coalesce to one apply per worktree in one drain turn")
    func rapidEnrichmentFactsCoalesceByWorktree() async throws {
        let traceDirectory = FileManager.default.temporaryDirectory.appending(
            path: "apply-governor-trace-\(UUIDv7.generate().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: traceDirectory) }
        let traceRuntime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "workspace-cache-apply-governor",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 937,
            timeUnixNano: { 937 }
        )
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: traceRuntime)
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let clock = TestPushClock()
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let fixture = try makeThreeWorktreeFixture(in: workspaceStore)
        let repo = fixture.repository
        let registeredWorktrees = fixture.worktrees
        let worktreeIds = registeredWorktrees.map(\.id)
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { _ in },
            enrichmentApplyTickCadence: .milliseconds(25),
            enrichmentApplyClock: clock,
            performanceTraceRecorder: recorder,
            factSink: applications.sink
        )
        try await withCacheApplicationWorld(
            coordinator: coordinator, applications: applications, heldTicks: []
        ) {

            for sequence in 0..<12 {
                let worktree = registeredWorktrees[sequence % registeredWorktrees.count]
                let worktreeLifetime = try #require(fixture.worktreeLifetimes[worktree.id])
                await bus.post(
                    .worktree(
                        WorktreeEnvelope.test(
                            event: .gitWorkingDirectory(
                                .snapshotChanged(
                                    snapshot: GitWorkingTreeSnapshot(
                                        worktreeId: worktree.id,
                                        repoId: repo.id,
                                        rootPath: worktree.path,
                                        summary: GitWorkingTreeSummary(
                                            changed: sequence,
                                            staged: 0,
                                            untracked: 0
                                        ),
                                        branch: "branch-\(sequence)"
                                    )
                                )
                            ),
                            repoId: repo.id,
                            worktreeId: worktree.id,
                            source: .system(.builtin(.gitWorkingDirectoryProjector)),
                            seq: UInt64(sequence),
                            observationLifetime: .worktree(worktreeLifetime)
                        )
                    )
                )
            }
            await bus.post(
                .worktree(
                    WorktreeEnvelope.test(
                        event: .gitWorkingDirectory(
                            .originChanged(
                                repoId: repo.id,
                                from: "",
                                to: "git@github.com:askluna/agent-studio.git"
                            )
                        ),
                        repoId: repo.id,
                        worktreeId: registeredWorktrees[0].id,
                        source: .system(.builtin(.gitWorkingDirectoryProjector)),
                        observationLifetime: .worktree(
                            try #require(fixture.worktreeLifetimes[registeredWorktrees[0].id]))
                    )
                )
            )
            try await applications.expectApplied(repositoryID: repo.id, kind: .repositoryIdentity)
            #expect(repoCache.repoEnrichmentByRepoId[repo.id] != nil)
        }
        try await recorder.drain()

        #expect(repoCache.worktreeEnrichmentByWorktreeId.count == worktreeIds.count)
        let outputFileURL = try #require(traceRuntime.outputFileURL)
        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(contents.contains("\"body\":\"performance.apply_governor.drain\""))
        #expect(contents.contains("\"agentstudio.performance.apply_governor.batch.count\":3"))
        #expect(contents.contains("\"agentstudio.performance.apply_governor.superseded.count\":9"))
        #expect(contents.contains("\"agentstudio.performance.apply_governor.carried_over.count\":0"))
        #expect(contents.contains("\"agentstudio.performance.apply_governor.awaited_ms\":"))
        #expect(contents.contains("\"agentstudio.performance.apply_governor.mainactor_held_ms\":"))
        #expect(contents.contains("\"agentstudio.performance.apply_governor.max_single_fact_ms\":"))
    }

    @Test
    func branchChangedAfterCachedSnapshotPreservesSnapshot() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let snapshotTick = HeldStep<TestPushClock.Instant>("snapshot apply tick")
        let branchTick = HeldStep<TestPushClock.Instant>("branch apply tick")
        let clock = HeldCacheApplyClock(ticks: [snapshotTick, branchTick])
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { _ in },
            enrichmentApplyTickCadence: .milliseconds(25),
            enrichmentApplyClock: clock,
            factSink: applications.sink
        )
        let repo = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/apply-governor-branch-repo"))
        let worktree = try #require(repo.worktrees.first { $0.isMainWorktree })
        let repoId = repo.id
        let worktreeId = worktree.id
        let observationLifetime = try #require(
            workspaceStore.repositoryTopologyAtom.worktreeObservationLifetimes[worktreeId]
        )
        let snapshot = GitWorkingTreeSnapshot(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: worktree.path,
            summary: GitWorkingTreeSummary(changed: 2, staged: 1, untracked: 3),
            branch: "main"
        )

        try await withCacheApplicationWorld(
            coordinator: coordinator, applications: applications, heldTicks: [snapshotTick, branchTick]
        ) {
            await bus.post(
                .worktree(
                    WorktreeEnvelope.test(
                        event: .gitWorkingDirectory(.snapshotChanged(snapshot: snapshot)),
                        repoId: repoId,
                        worktreeId: worktreeId,
                        source: .system(.builtin(.gitWorkingDirectoryProjector)),
                        observationLifetime: .worktree(observationLifetime)
                    )))
            let snapshotDeadline = try await snapshotTick.firstArrival()
            #expect(snapshotDeadline > clock.now)
            clock.backing.advance(to: snapshotDeadline)
            snapshotTick.release()
            try await applications.expectApplied(
                repositoryID: repoId, kind: .worktreeEnrichment, worktreeID: worktreeId
            ) {
                $0.worktree?.snapshot == snapshot
            }
            #expect(repoCache.worktreeEnrichment(for: worktreeId)?.snapshot == snapshot)

            await bus.post(
                .worktree(
                    WorktreeEnvelope.test(
                        event: .gitWorkingDirectory(
                            .branchChanged(
                                worktreeId: worktreeId,
                                repoId: repoId,
                                from: "main",
                                to: "feature/new"
                            )
                        ),
                        repoId: repoId,
                        worktreeId: worktreeId,
                        source: .system(.builtin(.gitWorkingDirectoryProjector)),
                        observationLifetime: .worktree(observationLifetime)
                    )))
            let branchDeadline = try await branchTick.firstArrival()
            #expect(branchDeadline > clock.now)
            clock.backing.advance(to: branchDeadline)
            branchTick.release()
            try await applications.expectApplied(
                repositoryID: repoId, kind: .worktreeEnrichment, worktreeID: worktreeId
            ) {
                $0.worktree?.branch == "feature/new"
            }
        }

        #expect(repoCache.worktreeEnrichment(for: worktreeId)?.branch == "feature/new")
        #expect(repoCache.worktreeEnrichment(for: worktreeId)?.snapshot == snapshot)
    }

    private func makeThreeWorktreeFixture(in workspaceStore: WorkspaceStore) throws -> ThreeWorktreeFixture {
        let repository = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/apply-governor-repo"))
        let mainWorktree = try #require(repository.worktrees.first { $0.isMainWorktree })
        let linkedWorktrees = (0..<2).map { index in
            Worktree(
                repoId: repository.id,
                name: "linked-\(index)",
                path: URL(fileURLWithPath: "/tmp/apply-governor-linked-\(index)")
            )
        }
        workspaceStore.reconcileDiscoveredWorktrees(
            repository.id,
            worktrees: [mainWorktree] + linkedWorktrees
        )

        let registeredRepository = try #require(
            workspaceStore.repositoryTopologyAtom.repo(repository.id)
        )
        let registeredWorktrees = try #require(
            registeredRepository.worktrees.count == 3 ? registeredRepository.worktrees : nil
        )
        return ThreeWorktreeFixture(
            repository: registeredRepository,
            worktrees: registeredWorktrees,
            worktreeLifetimes: workspaceStore.repositoryTopologyAtom.worktreeObservationLifetimes
        )
    }

    private struct ThreeWorktreeFixture {
        let repository: Repo
        let worktrees: [Worktree]
        let worktreeLifetimes: [UUID: WorktreeObservationLifetime]
    }
}
