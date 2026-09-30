import AgentStudioGit
import AgentStudioTestHarness
import Foundation
import Observation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct FilesystemGitPipelineDemandIntegrationTests {
    @Test("unknown attended repository publishes its first complete sidebar baseline")
    func unknownAttendedRepositoryPublishesCompleteSidebarBaseline() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let expectedStatus = demandIntegrationExpectedSidebarStatus()
        let gitProvider = DemandIntegrationGitStatusProvider(status: expectedStatus)
        let remoteReferenceProvider = DemandIntegrationRemoteReferenceProvider()
        let forgeProvider = DemandIntegrationForgeProvider(
            expectedBranch: "feature/sidebar-admission"
        )
        let performanceRecorder = DemandIntegrationPerformanceRecorder()
        let gitClock = TestPushClock()
        let refreshPolicy = demandIntegrationUnknownRefreshPolicy()
        let pipeline = FilesystemGitPipeline(
            bus: bus,
            registrationDiscoveryProvider: DemandIntegrationRegistrationDiscoveryProvider(),
            gitWorkingTreeProvider: gitProvider,
            remoteReferenceRefreshProvider: remoteReferenceProvider,
            forgeStatusProvider: forgeProvider,
            fseventStreamClient: DemandIntegrationSilentFSEventStreamClient(),
            filesystemDebounceWindow: .zero,
            filesystemMaxFlushLatency: .zero,
            gitCoalescingWindow: .zero,
            gitRefreshPolicy: refreshPolicy,
            gitSleepClock: gitClock,
            repositoryFactDemandPerformanceRecorder: performanceRecorder
        )
        let rootPath = demandIntegrationFixtureRootPath()
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }

        let workspaceStore = WorkspaceStore()
        let repository = workspaceStore.addRepo(at: rootPath)
        let worktree = try #require(repository.worktrees.first)
        let repoCache = RepoCacheAtom()
        let cacheCoordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { _ in }
        )
        let demandCoordinator = RepositoryFactDemandCoordinator { snapshot in
            await pipeline.setRepositoryFactDemand(snapshot)
        }
        let activityTopology = try demandIntegrationActivityTopology(
            repository: repository,
            worktreeId: worktree.id
        )

        await cacheCoordinator.startConsuming()
        await pipeline.start()
        demandCoordinator.accept(
            RepositoryFactDemandInput(
                activePaneWorktreeId: nil,
                sidebarAttendedWorktreeIds: [worktree.id],
                visibleActiveTabWorktreeIds: [],
                openWorktreeIds: [],
                repositoryIdByWorktreeId: [worktree.id: repository.id],
                activityTopology: [activityTopology],
                localActivityHydrationDisposition: .unavailable,
                repositoryLocalActivityByStableKey: [:]
            )
        )
        await demandCoordinator.waitUntilIdle()
        try expectUnknownAppliedPerformance(performanceRecorder)
        await gitClock.waitForPendingSleepCount(atLeast: 1)
        gitClock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)
        await pipeline.waitForRepositoryFactDemandAdmission()
        await registerAndAssertCanonicalTopology(workspaceStore: workspaceStore, pipeline: pipeline)
        await gitClock.waitForPendingSleepCount(atLeast: 1)
        gitClock.advance(by: refreshPolicy.backgroundCadence)

        let enrichment = try #require(
            await waitForCacheOutcome(
                observe: { repoCache.worktreeEnrichment(for: worktree.id) },
                matching: { $0?.snapshot?.summary == expectedStatus.summary }
            )
        )
        #expect(enrichment.snapshot?.summary == expectedStatus.summary)
        #expect(enrichment.branch == "feature/sidebar-admission")
        #expect(await remoteReferenceProvider.currentStageFetchCallCount() == 0)
        #expect(await forgeProvider.currentCallCount() == 0)

        try expectCompleteSidebarBaseline(
            repoCache: repoCache,
            repository: repository,
            worktree: worktree
        )

        await shutdown(
            demandCoordinator: demandCoordinator,
            pipeline: pipeline,
            cacheCoordinator: cacheCoordinator
        )
    }

    @Test("applied demand performance exposes a misrouted unknown key")
    func appliedDemandPerformanceExposesMisroutedUnknownKey() {
        let repositoryId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let snapshot = RepositoryFactDemandSnapshot(
            activePaneWorktreeId: nil,
            sidebarAttendedWorktreeIds: [worktreeId],
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: [],
            repositoryIdByWorktreeId: [worktreeId: repositoryId],
            warmRepositoryIds: [],
            unknownRepositoryIds: [repositoryId],
            locallyInactiveRepositoryIds: [],
            warmAutomaticWorktreeIds: [],
            unknownWorktreeIds: [worktreeId],
            backgroundOnlyAutomaticWorktreeIds: [worktreeId],
            locallyInactiveWorktreeIds: []
        )

        let performance = FilesystemGitPipeline.appliedDemandPerformanceSnapshot(
            snapshot: snapshot,
            backgroundOnlyAutomaticWorktreeIds: [worktreeId],
            remoteDemandRepositoryIds: [repositoryId],
            forgeDemandWorktreeIds: [worktreeId]
        )

        #expect(performance.appliedUnknownWorktreeCurrent == 1)
        #expect(performance.appliedUnknownBackgroundOnlyCurrent == 1)
        #expect(performance.appliedUnknownRemoteDemandCurrent == 1)
        #expect(performance.appliedUnknownForgeDemandCurrent == 1)
    }

    @Test("changed attention reuses fresh local remote and Forge facts")
    func changedAttentionReusesFreshRepositoryFacts() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gitProvider = DemandIntegrationGitStatusProvider()
        let promotionStep = HeldStep<Void>("promote remote references after the initial baseline closes")
        defer { promotionStep.retire() }
        let remoteReferenceProvider = DemandIntegrationRemoteReferenceProvider(promotionStep: promotionStep)
        let forgeProvider = DemandIntegrationForgeProvider()
        let fseventStreamClient = DemandIntegrationSilentFSEventStreamClient()
        let gitClock = TestPushClock()
        let projectorFactSource = GitProjectorFactSource()
        let projectorFacts = try projectorFactSource.attach()
        let pipeline = FilesystemGitPipeline(
            bus: bus,
            registrationDiscoveryProvider: DemandIntegrationRegistrationDiscoveryProvider(),
            gitWorkingTreeProvider: gitProvider,
            remoteReferenceRefreshProvider: remoteReferenceProvider,
            forgeStatusProvider: forgeProvider,
            fseventStreamClient: fseventStreamClient,
            filesystemDebounceWindow: .zero,
            filesystemMaxFlushLatency: .zero,
            gitCoalescingWindow: .zero,
            gitSleepClock: gitClock,
            projectorFactSink: projectorFactSource.sink
        )
        let rootPath = demandIntegrationFixtureRootPath()
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }

        let workspaceStore = WorkspaceStore()
        let repository = workspaceStore.addRepo(at: rootPath)
        let worktreeId = try #require(repository.worktrees.first?.id)
        let repoCache = RepoCacheAtom()
        let cacheCoordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { _ in }
        )
        let demandCoordinator = RepositoryFactDemandCoordinator { snapshot in
            await pipeline.setRepositoryFactDemand(snapshot)
        }
        let activityTopology = try demandIntegrationActivityTopology(
            repository: repository,
            worktreeId: worktreeId
        )
        let initialDemand = RepositoryFactDemandInput(
            activePaneWorktreeId: worktreeId,
            sidebarAttendedWorktreeIds: [worktreeId],
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: [worktreeId],
            repositoryIdByWorktreeId: [worktreeId: repository.id],
            activityTopology: [activityTopology]
        )

        await cacheCoordinator.startConsuming()
        await pipeline.start()
        await registerAndAssertCanonicalTopology(workspaceStore: workspaceStore, pipeline: pipeline)
        demandCoordinator.accept(initialDemand)
        try await proveInitialBaselineAndPromotionReuse(
            InitialRefreshProofContext(
                promotionStep: promotionStep,
                projectorFactSource: projectorFactSource,
                projectorFacts: projectorFacts,
                worktreeId: worktreeId,
                repoCache: repoCache,
                gitProvider: gitProvider,
                remoteReferenceProvider: remoteReferenceProvider,
                forgeProvider: forgeProvider
            )
        )
        await settleControlledVisibilityAdmission(pipeline: pipeline, gitClock: gitClock, pendingSleepCount: 2)

        let sourceCallsAfterAttentionChange = try await proveChangedAttentionReusesFacts(
            WarmAttentionProofContext(
                pipeline: pipeline,
                gitClock: gitClock,
                demandCoordinator: demandCoordinator,
                gitProvider: gitProvider,
                remoteReferenceProvider: remoteReferenceProvider,
                forgeProvider: forgeProvider,
                repoCache: repoCache,
                repositoryId: repository.id,
                worktreeId: worktreeId,
                activityTopology: activityTopology
            )
        )

        try await proveInactiveDemandAndColdMutation(
            ColdDemandProofContext(
                pipeline: pipeline,
                gitClock: gitClock,
                demandCoordinator: demandCoordinator,
                fseventStreamClient: fseventStreamClient,
                gitProvider: gitProvider,
                remoteReferenceProvider: remoteReferenceProvider,
                forgeProvider: forgeProvider,
                repoCache: repoCache,
                repositoryId: repository.id,
                worktreeId: worktreeId,
                activityTopology: activityTopology,
                sourceCallsBeforeInactivity: sourceCallsAfterAttentionChange
            )
        )

        await shutdown(demandCoordinator: demandCoordinator, pipeline: pipeline, cacheCoordinator: cacheCoordinator)
        try await projectorFacts.finish()
    }

    private func proveInitialBaselineAndPromotionReuse(
        _ context: InitialRefreshProofContext
    ) async throws {
        _ = try await context.promotionStep.firstArrival()
        let initialRefresh = try await context.projectorFactSource.expectNextRefreshClosed(
            facts: context.projectorFacts,
            worktreeId: context.worktreeId
        )
        #expect(initialRefresh == .completed(snapshotChanged: true, branchChanged: false))
        let observedCacheFacts = await waitForCacheOutcome(
            observe: {
                (
                    worktree: context.repoCache.worktreeEnrichment(for: context.worktreeId),
                    pullRequests: context.repoCache.pullRequestFactsForTest(worktreeId: context.worktreeId)
                )
            },
            matching: { $0.worktree?.branch == "main" && $0.pullRequests?.openCount == 1 }
        )
        #expect(observedCacheFacts.worktree?.branch == "main")
        #expect(observedCacheFacts.pullRequests?.openCount == 1)
        await expectSourceCallCounts(
            gitProvider: context.gitProvider,
            remoteReferenceProvider: context.remoteReferenceProvider,
            forgeProvider: context.forgeProvider,
            expectedCounts: DemandIntegrationSourceCallCounts(
                gitStatus: 1, gitLineDetail: 1,
                remoteCapture: 2, remoteFetch: 1, remotePromote: 0, remoteCleanup: 0, forge: 1
            )
        )

        context.promotionStep.release()
        let promotionRefresh = try await context.projectorFactSource.expectNextRefreshClosed(
            facts: context.projectorFacts,
            worktreeId: context.worktreeId
        )
        #expect(promotionRefresh == .equal)
        await expectSourceCallCounts(
            gitProvider: context.gitProvider,
            remoteReferenceProvider: context.remoteReferenceProvider,
            forgeProvider: context.forgeProvider,
            expectedCounts: DemandIntegrationSourceCallCounts(
                gitStatus: 2, gitLineDetail: 1,
                remoteCapture: 2, remoteFetch: 1, remotePromote: 1, remoteCleanup: 1, forge: 1
            )
        )
    }

    private func proveChangedAttentionReusesFacts(
        _ context: WarmAttentionProofContext
    ) async throws -> DemandIntegrationSourceCallCounts {
        let sourceCallsBeforeAttentionChange = await sourceCallCounts(
            gitProvider: context.gitProvider,
            remoteReferenceProvider: context.remoteReferenceProvider,
            forgeProvider: context.forgeProvider
        )
        let cacheRevisionBeforeAttentionChange = context.repoCache.cacheRevision
        let worktreeInvalidationCounter = DemandIntegrationInvalidationCounter()
        let pullRequestInvalidationCounter = DemandIntegrationInvalidationCounter()
        let branchKey = try #require(RepoBranchKey(repoId: context.repositoryId, branch: "main"))
        withObservationTracking {
            _ = context.repoCache.worktreeEnrichment(for: context.worktreeId)
        } onChange: {
            worktreeInvalidationCounter.record()
        }
        withObservationTracking {
            _ = context.repoCache.pullRequestFacts(for: branchKey)
        } onChange: {
            pullRequestInvalidationCounter.record()
        }
        context.demandCoordinator.accept(
            RepositoryFactDemandInput(
                activePaneWorktreeId: context.worktreeId,
                sidebarAttendedWorktreeIds: [],
                visibleActiveTabWorktreeIds: [context.worktreeId],
                openWorktreeIds: [context.worktreeId],
                repositoryIdByWorktreeId: [context.worktreeId: context.repositoryId],
                activityTopology: [context.activityTopology]
            )
        )
        await context.demandCoordinator.waitUntilIdle()
        await settleControlledVisibilityAdmission(
            pipeline: context.pipeline, gitClock: context.gitClock, pendingSleepCount: 2
        )

        let sourceCallsAfterAttentionChange = await sourceCallCounts(
            gitProvider: context.gitProvider,
            remoteReferenceProvider: context.remoteReferenceProvider,
            forgeProvider: context.forgeProvider
        )
        #expect(sourceCallsAfterAttentionChange == sourceCallsBeforeAttentionChange)
        #expect(context.repoCache.cacheRevision == cacheRevisionBeforeAttentionChange)
        #expect(!worktreeInvalidationCounter.didFire)
        #expect(!pullRequestInvalidationCounter.didFire)
        #expect(context.repoCache.worktreeEnrichment(for: context.worktreeId)?.branch == "main")
        #expect(context.repoCache.pullRequestFactsForTest(worktreeId: context.worktreeId)?.openCount == 1)
        return sourceCallsAfterAttentionChange
    }

    private func registerAndAssertCanonicalTopology(
        workspaceStore: WorkspaceStore,
        pipeline: FilesystemGitPipeline
    ) async {
        let topology = workspaceStore.repositoryTopologyAtom
        let canonicalRepositories = topology.repos
        for repository in canonicalRepositories {
            for worktree in repository.worktrees {
                await pipeline.register(
                    worktreeId: worktree.id,
                    repoId: repository.id,
                    rootPath: worktree.path
                )
            }
        }
        await pipeline.assertTopology(
            FilesystemTopologyAssertion(
                generation: topology.worktreePathIndexGeneration,
                contextsByWorktreeId: Dictionary(
                    uniqueKeysWithValues: canonicalRepositories.flatMap { repository in
                        repository.worktrees.map { worktree in
                            (
                                worktree.id,
                                WorktreeFilesystemContext(repoId: repository.id, rootPath: worktree.path)
                            )
                        }
                    }
                ),
                repositoryStableKeysByWorktreeId: Dictionary(
                    uniqueKeysWithValues: canonicalRepositories.flatMap { repository in
                        repository.worktrees.map { worktree in
                            (worktree.id, repository.stableKey)
                        }
                    }
                ),
                repositoryLifetimes: topology.repositoryObservationLifetimes,
                worktreeLifetimes: topology.worktreeObservationLifetimes
            )
        )
    }

    private func expectCompleteSidebarBaseline(
        repoCache: RepoCacheAtom,
        repository: Repo,
        worktree: Worktree
    ) throws {
        let presentationRepo = RepoPresentationItem(
            repo: repository,
            stableKey: repository.stableKey,
            worktreeStableKeysByID: [worktree.id: worktree.stableKey]
        )
        let projection = try RepoExplorerProjectionWorker.project(
            RepoExplorerProjectionRequest(
                generation: 1,
                snapshot: RepoExplorerSnapshot(
                    repos: [presentationRepo],
                    repoEnrichmentByRepoId: repoCache.repoEnrichmentByRepoId,
                    groupingMode: .repo,
                    query: ""
                ),
                collapsedGroupIds: [],
                isFiltering: false,
                trigger: .dataRefresh,
                worktreeEnrichmentSnapshot: repoCache.worktreeEnrichmentByWorktreeId,
                pullRequestFactsSnapshot: repoCache.pullRequestFactsByBranch,
                localActivityHydrationDisposition: .pending
            )
        )
        let worktreePresentations: [RepoExplorerMaterializedWorktreePresentation] =
            projection.materializationSnapshot.rows.compactMap { row in
                guard case .worktree(let presentation) = row.presentation else { return nil }
                return presentation
            }
        let worktreePresentation = try #require(worktreePresentations.first)
        #expect(worktreePresentation.branchName == "feature/sidebar-admission")
        #expect(worktreePresentation.branchStatus.isDirty)
        #expect(
            worktreePresentation.branchStatus.syncState
                == GitBranchStatus.SyncState.diverged(ahead: 2, behind: 1)
        )
        #expect(worktreePresentation.branchStatus.linesAdded == 69)
        #expect(worktreePresentation.branchStatus.linesDeleted == 19)
        #expect(worktreePresentation.branchStatus.untrackedFileCount == 3)
    }

    private func proveInactiveDemandAndColdMutation(_ context: ColdDemandProofContext) async throws {
        let referenceDate = Date()
        let inactiveActivity = try RepositoryLocalActivity(
            repositoryStableKey: context.activityTopology.repositoryStableKey,
            lastQualifyingActivityAt: nil,
            continuousCoverageStartedAt: referenceDate.addingTimeInterval(
                -AppPolicies.EntityRecency.applicationActivityHorizon - 1
            ),
            updatedAt: referenceDate,
            ownedPromotionAttemptID: nil,
            ownedPromotionStartedAt: nil,
            ownedPromotionUnsettled: false
        )
        let inactiveDemand = RepositoryFactDemandInput(
            activePaneWorktreeId: nil,
            sidebarAttendedWorktreeIds: [context.worktreeId],
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: [],
            repositoryIdByWorktreeId: [context.worktreeId: context.repositoryId],
            activityTopology: [context.activityTopology],
            localActivityHydrationDisposition: .authoritative,
            repositoryLocalActivityByStableKey: [
                inactiveActivity.repositoryStableKey: inactiveActivity
            ]
        )
        context.demandCoordinator.accept(inactiveDemand)
        await context.demandCoordinator.waitUntilIdle()
        await settleControlledVisibilityAdmission(
            pipeline: context.pipeline, gitClock: context.gitClock, pendingSleepCount: 1
        )

        let sourceCallsAfterInactivity = await sourceCallCounts(
            gitProvider: context.gitProvider,
            remoteReferenceProvider: context.remoteReferenceProvider,
            forgeProvider: context.forgeProvider
        )
        #expect(sourceCallsAfterInactivity == context.sourceCallsBeforeInactivity)
        #expect(context.repoCache.worktreeEnrichment(for: context.worktreeId)?.branch == "main")
        #expect(context.repoCache.pullRequestFactsForTest(worktreeId: context.worktreeId)?.openCount == 1)
        #expect(await context.pipeline.gitLogicalDebtSnapshot().futureAutomaticCount == 0)

        context.fseventStreamClient.send(
            FSEventBatch(worktreeId: context.worktreeId, paths: ["Sources/ColdMutation.swift"])
        )
        let observedGitStatusCallCount = await context.gitProvider.waitForStatusCallCount(
            atLeast: sourceCallsAfterInactivity.gitStatus + 1
        )
        let observedRemoteCalls = await context.remoteReferenceProvider.currentCallCounts()
        let observedForgeCallCount = await context.forgeProvider.currentCallCount()
        #expect(observedGitStatusCallCount == sourceCallsAfterInactivity.gitStatus + 1)
        #expect(observedRemoteCalls.fetch == sourceCallsAfterInactivity.remoteFetch)
        #expect(observedForgeCallCount == sourceCallsAfterInactivity.forge)
        #expect(await context.pipeline.gitLogicalDebtSnapshot().futureAutomaticCount == 0)
    }

    private func waitForCacheOutcome<TObservation>(
        observe: @escaping @MainActor () -> TObservation,
        matching matches: (TObservation) -> Bool
    ) async -> TObservation {
        while true {
            let observation = observe()
            if matches(observation) {
                return observation
            }
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = observe()
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    private func sourceCallCounts(
        gitProvider: DemandIntegrationGitStatusProvider,
        remoteReferenceProvider: DemandIntegrationRemoteReferenceProvider,
        forgeProvider: DemandIntegrationForgeProvider
    ) async -> DemandIntegrationSourceCallCounts {
        let gitStatus = await gitProvider.currentStatusCallCount()
        let gitLineDetail = await gitProvider.currentLineDetailCallCount()
        let remote = await remoteReferenceProvider.currentCallCounts()
        let forge = await forgeProvider.currentCallCount()
        return DemandIntegrationSourceCallCounts(
            gitStatus: gitStatus,
            gitLineDetail: gitLineDetail,
            remoteCapture: remote.capture,
            remoteFetch: remote.fetch,
            remotePromote: remote.promote,
            remoteCleanup: remote.cleanup,
            forge: forge
        )
    }

    private func expectSourceCallCounts(
        gitProvider: DemandIntegrationGitStatusProvider,
        remoteReferenceProvider: DemandIntegrationRemoteReferenceProvider,
        forgeProvider: DemandIntegrationForgeProvider,
        expectedCounts: DemandIntegrationSourceCallCounts
    ) async {
        let actualCounts = await sourceCallCounts(
            gitProvider: gitProvider,
            remoteReferenceProvider: remoteReferenceProvider,
            forgeProvider: forgeProvider
        )
        #expect(actualCounts == expectedCounts, Comment(rawValue: "closed refresh source call counts: \(actualCounts)"))
    }

    private func settleControlledVisibilityAdmission(
        pipeline: FilesystemGitPipeline,
        gitClock: TestPushClock,
        pendingSleepCount: Int
    ) async {
        await gitClock.waitForPendingSleepCount(exactly: pendingSleepCount)
        gitClock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)
        await pipeline.waitForRepositoryFactDemandAdmission()
    }

    private func shutdown(
        demandCoordinator: RepositoryFactDemandCoordinator,
        pipeline: FilesystemGitPipeline,
        cacheCoordinator: WorkspaceCacheCoordinator
    ) async {
        await demandCoordinator.shutdown()
        await pipeline.shutdown()
        await cacheCoordinator.shutdown()
    }
}

private struct InitialRefreshProofContext {
    let promotionStep: HeldStep<Void>
    let projectorFactSource: GitProjectorFactSource
    let projectorFacts: FactRecorder<GitProjectorScope, GitProjectorFact>
    let worktreeId: UUID
    let repoCache: RepoCacheAtom
    let gitProvider: DemandIntegrationGitStatusProvider
    let remoteReferenceProvider: DemandIntegrationRemoteReferenceProvider
    let forgeProvider: DemandIntegrationForgeProvider
}

private struct ColdDemandProofContext {
    let pipeline: FilesystemGitPipeline
    let gitClock: TestPushClock
    let demandCoordinator: RepositoryFactDemandCoordinator
    let fseventStreamClient: DemandIntegrationSilentFSEventStreamClient
    let gitProvider: DemandIntegrationGitStatusProvider
    let remoteReferenceProvider: DemandIntegrationRemoteReferenceProvider
    let forgeProvider: DemandIntegrationForgeProvider
    let repoCache: RepoCacheAtom
    let repositoryId: UUID
    let worktreeId: UUID
    let activityTopology: RepositoryActivityTopology
    let sourceCallsBeforeInactivity: DemandIntegrationSourceCallCounts
}

private struct WarmAttentionProofContext {
    let pipeline: FilesystemGitPipeline
    let gitClock: TestPushClock
    let demandCoordinator: RepositoryFactDemandCoordinator
    let gitProvider: DemandIntegrationGitStatusProvider
    let remoteReferenceProvider: DemandIntegrationRemoteReferenceProvider
    let forgeProvider: DemandIntegrationForgeProvider
    let repoCache: RepoCacheAtom
    let repositoryId: UUID
    let worktreeId: UUID
    let activityTopology: RepositoryActivityTopology
}

private func demandIntegrationFixtureRootPath() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "pipeline-demand-cache-\(UUIDv7.generate().uuidString)")
}

private func demandIntegrationExpectedSidebarStatus() -> GitWorkingTreeStatus {
    GitWorkingTreeStatus(
        summary: GitWorkingTreeSummary(
            changed: 2,
            staged: 1,
            untracked: 3,
            linesAdded: 69,
            linesDeleted: 19,
            aheadCount: 2,
            behindCount: 1,
            hasUpstream: true
        ),
        branch: "feature/sidebar-admission",
        origin: "git@github.com:askluna/agent-studio.git"
    )
}

private func demandIntegrationUnknownRefreshPolicy() -> AppPolicies.GitRefresh.Policy {
    AppPolicies.GitRefresh.Policy(
        activePaneCadence: .milliseconds(50),
        visibleSidebarCadence: .milliseconds(100),
        openPaneCadence: .milliseconds(200),
        backgroundCadence: .milliseconds(400),
        backgroundStripeCount: 1
    )
}

private func expectUnknownAppliedPerformance(
    _ recorder: DemandIntegrationPerformanceRecorder
) throws {
    let performance = try #require(recorder.snapshots.last)
    #expect(performance.appliedUnknownWorktreeCurrent == 1)
    #expect(performance.appliedUnknownBackgroundOnlyCurrent == 1)
    #expect(performance.appliedUnknownRemoteDemandCurrent == 0)
    #expect(performance.appliedUnknownForgeDemandCurrent == 0)
}

private func demandIntegrationActivityTopology(
    repository: Repo,
    worktreeId: UUID
) throws -> RepositoryActivityTopology {
    RepositoryActivityTopology(
        repositoryID: repository.id,
        repositoryStableKey: repository.stableKey,
        worktreeStableKeysByID: [worktreeId: try #require(repository.worktrees.first?.stableKey)]
    )
}

private final class DemandIntegrationInvalidationCounter: @unchecked Sendable {
    private(set) var didFire = false

    func record() {
        didFire = true
    }
}

private struct DemandIntegrationSourceCallCounts: Equatable {
    let gitStatus: Int
    let gitLineDetail: Int
    let remoteCapture: Int
    let remoteFetch: Int
    let remotePromote: Int
    let remoteCleanup: Int
    let forge: Int
}

private final class DemandIntegrationPerformanceRecorder:
    RepositoryFactDemandPerformanceRecording, @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedSnapshots: [RepositoryFactDemandPerformanceSnapshot] = []

    var snapshots: [RepositoryFactDemandPerformanceSnapshot] {
        lock.withLock { recordedSnapshots }
    }

    func recordRepositoryFactDemandPerformanceSnapshot(
        _ snapshot: RepositoryFactDemandPerformanceSnapshot
    ) {
        lock.withLock { recordedSnapshots.append(snapshot) }
    }
}
