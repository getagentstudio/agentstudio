import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("ForgeActor admission edges", .serialized)
struct ForgeActorAdmissionEdgeTests {
    @Test("provider request publishes bounded loading edges around a successful query")
    func providerRequestPublishesLoadingEdgesAroundSuccess() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/loading")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])

        #expect(await fixture.provider.waitForCallCount(1))
        #expect(await fixture.events.waitForLoadingStates(repoId: repoId, expected: [true]))

        await fixture.provider.resolve(callAt: 0, with: .complete([]))

        #expect(await fixture.events.waitForLoadingStates(repoId: repoId, expected: [true, false]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/loading",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("failed provider request clears loading before entering backoff")
    func failedProviderRequestClearsLoadingBeforeBackoff() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/failure")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])

        #expect(await fixture.provider.waitForCallCount(1))
        #expect(await fixture.events.waitForLoadingStates(repoId: repoId, expected: [true]))
        await fixture.provider.resolve(callAt: 0, with: .failed(message: "offline"))

        #expect(await fixture.events.waitForLoadingStates(repoId: repoId, expected: [true, false]))
        #expect(await fixture.events.waitForRefreshFailure(repoId: repoId))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("truncated repository result preserves facts and waits for the minimum retry deadline")
    func truncatedResultPreservesFactsAndBacksOff() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let pullRequestURL = URL(string: "https://github.com/acme/studio/pull/42")!

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/truncated")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(
            callAt: 0,
            with: .complete([ForgePullRequest(headRefName: "feature/truncated", url: pullRequestURL)])
        )
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/truncated",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: pullRequestURL)
            )
        )

        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .truncated)
        #expect(await fixture.events.waitForRefreshFailure(repoId: repoId))
        #expect(
            await fixture.events.facts(for: repoId, branch: "feature/truncated")
                == PullRequestFacts(openCount: 1, exactOpenURL: pullRequestURL)
        )
        await fixture.clock.waitForPendingSleepCount(atLeast: 1)
        #expect(await fixture.actor.refreshStateByRepoId[repoId]?.backoffUntil == Duration.seconds(180))

        fixture.advance(by: .seconds(179))
        #expect(await fixture.provider.callCount == 2)
        fixture.advance(by: .seconds(1))
        #expect(await fixture.provider.waitForCallCount(3))
        await fixture.provider.resolve(callAt: 2, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("ordinary failure preserves facts and manual refresh cannot bypass backoff")
    func ordinaryFailurePreservesFactsAndManualRefreshRespectsBackoff() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/failure")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailure(repoId: repoId))

        await fixture.actor.refresh(repo: repoId)
        await Task.yield()
        #expect(await fixture.provider.callCount == 1)

        await fixture.clock.waitForPendingSleepCount(atLeast: 1)
        fixture.advance(by: .seconds(180))
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/failure",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("a detached-HEAD worktree never issues a forge query even with an origin and demand")
    func detachedHeadWorktreeNeverIssuesForgeQuery() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let detachedWorktreeId = UUIDv7.generate()

        // Detached HEAD reaches ForgeActor as a nil branch (WorkspaceCacheCoordinator's
        // `snapshot.branch ?? ""` coercion is a separate downstream consumer of the
        // same bus event, not something ForgeActor itself performs).
        await fixture.actor.register(
            worktreeId: detachedWorktreeId,
            repoId: repoId,
            rootPath: URL(fileURLWithPath: "/tmp/acme-detached"),
            branch: nil
        )
        await fixture.actor.setOrigin(repo: repoId, remote: "git@github.com:acme/studio.git")
        await fixture.actor.setDemand(worktreeIds: [detachedWorktreeId])

        // No branch means no demanded branch to query, regardless of origin
        // or demand; advancing well past every backoff/freshness window must
        // not eventually admit a query either.
        fixture.advance(by: .seconds(600))
        await Task.yield()
        #expect(await fixture.provider.callCount == 0)

        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("losing the final demanded branch consumes the existing freshness deadline")
    func losingFinalDemandedBranchConsumesFreshnessDeadline() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/acme-detached-after-success")

        await fixture.actor.register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootPath,
            branch: "main"
        )
        await fixture.actor.setOrigin(repo: repoId, remote: "git@github.com:acme/studio.git")
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        await fixture.clock.waitForPendingSleepCount(exactly: 1)

        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .snapshotChanged(
                            snapshot: GitWorkingTreeSnapshot(
                                worktreeId: worktreeId,
                                repoId: repoId,
                                rootPath: rootPath,
                                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                                branch: nil
                            )
                        )
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        #expect(await fixture.events.waitForBranchInvalidation(repoId: repoId, branch: "main"))
        await fixture.clock.waitForPendingSleepCount(exactly: 0)
        let hasNoDeadlineCandidates = await fixture.actor.deadlineCandidates().isEmpty
        #expect(hasNoDeadlineCandidates)
        guard hasNoDeadlineCandidates else {
            await fixture.actor.shutdown()
            await fixture.stopObserving()
            return
        }
        let scheduledSleepGeneration = fixture.clock.scheduledSleepGeneration

        fixture.advance(by: AppPolicies.Forge.automaticRefreshMinimumInterval)

        #expect(fixture.clock.scheduledSleepGeneration == scheduledSleepGeneration)
        #expect(fixture.clock.pendingSleepCount == 0)
        #expect(await fixture.provider.callCount == 1)

        await fixture.provider.resolveIfPresent(callAt: 1, with: .failed(message: "test cleanup"))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("registration schedules the freshness deadline when demand arrived before membership")
    func registrationSchedulesDeadlineForPreexistingDemand() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let laterWorktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(firstWorktreeId, "feature/first")])
        await fixture.actor.setDemand(worktreeIds: [firstWorktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/first",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )

        await fixture.actor.setDemand(worktreeIds: [laterWorktreeId])
        await fixture.actor.register(
            worktreeId: laterWorktreeId,
            repoId: repoId,
            rootPath: URL(fileURLWithPath: "/tmp/acme-later"),
            branch: "feature/later"
        )

        await fixture.clock.waitForPendingSleepCount(atLeast: 1)

        fixture.advance(by: .seconds(180))
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("shutdown cannot admit a pending follow-up after provider cancellation")
    func shutdownRejectsPendingFollowUp() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/shutdown")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.callCount == 1)

        let shutdownTask = Task {
            await fixture.actor.shutdown()
        }
        await Task.yield()
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        await shutdownTask.value

        #expect(await fixture.provider.callCount == 1)
        await fixture.stopObserving()
    }

    @Test("multiple pull requests on one branch do not produce an arbitrary exact URL")
    func multiplePullRequestsDoNotProduceExactURL() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/ambiguous")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(
            callAt: 0,
            with: .complete([
                ForgePullRequest(
                    headRefName: "feature/ambiguous",
                    url: URL(string: "https://github.com/acme/studio/pull/41")!
                ),
                ForgePullRequest(
                    headRefName: "feature/ambiguous",
                    url: URL(string: "https://github.com/acme/studio/pull/42")!
                ),
            ])
        )

        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/ambiguous",
                expected: PullRequestFacts(openCount: 2, exactOpenURL: nil)
            )
        )
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("manual refresh bypasses freshness when no rate backoff is open")
    func manualRefreshBypassesFreshness() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/manual")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/manual",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )

        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("same-scope follow-up remains pending until success freshness expires")
    func sameScopeFollowUpRespectsSuccessFreshness() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/acme-forge-pending-intent")
        let branch = "feature/pending-intent"

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, branch)])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))

        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .snapshotChanged(
                            snapshot: GitWorkingTreeSnapshot(
                                worktreeId: worktreeId,
                                repoId: repoId,
                                rootPath: rootPath,
                                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                                branch: branch
                            )
                        )
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        var followUpWasRecorded = false
        for _ in 0..<1000 {
            if await fixture.actor.refreshStateByRepoId[repoId]?.pendingFollowUp == true {
                followUpWasRecorded = true
                break
            }
            await Task.yield()
        }
        #expect(followUpWasRecorded)

        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: branch,
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )
        await fixture.clock.waitForPendingSleepCount(exactly: 1)
        let freshnessDeadline =
            fixture.clock.now.advanced(by: AppPolicies.Forge.automaticRefreshMinimumInterval)
        #expect(fixture.clock.pendingSleepDeadlines == [freshnessDeadline])
        #expect(await fixture.provider.callCount == 1)

        fixture.advance(by: AppPolicies.Forge.automaticRefreshMinimumInterval - .seconds(1))
        #expect(await fixture.provider.callCount == 1)

        fixture.advance(by: .seconds(1))
        #expect(await fixture.provider.waitForCallCount(2))

        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("path-only discovery updates only matching known membership and removal is inert")
    func pathOnlyDiscoveryMatchesKnownMembership() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/acme-path-match")

        await fixture.actor.register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootPath,
            branch: "feature/old"
        )
        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .worktreeDiscovered(
                            repoId: repoId,
                            worktreePath: URL(fileURLWithPath: "/tmp/unrelated"),
                            branch: "feature/unrelated",
                            isMain: false
                        )
                    ),
                    repoId: repoId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .worktreeDiscovered(
                            repoId: repoId,
                            worktreePath: rootPath,
                            branch: "feature/matched",
                            isMain: false
                        )
                    ),
                    repoId: repoId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        #expect(await fixture.events.waitForBranchInvalidation(repoId: repoId, branch: "feature/old"))

        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(.worktreeRemoved(repoId: repoId, worktreePath: rootPath)),
                    repoId: repoId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        await fixture.actor.setOrigin(repo: repoId, remote: "git@github.com:acme/studio.git")
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/matched",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )
        #expect(await fixture.events.invalidatedBranches(for: repoId).contains("feature/unrelated") == false)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("a blocked provider cannot restore facts after the final branch membership switches")
    func blockedProviderCannotRestoreDepartedBranchFacts() async throws {
        let probe = try ForgePublicationProbe(closingRequest: 2)
        let fixture = await ForgeActorFixture.make(
            beforeEventEmission: { probe.record($0) }, providerRequestDidReturn: { probe.returned($0) })
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let departedBranchURL = URL(string: "https://github.com/acme/studio/pull/41")!

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/old")])
        let opening = await probe.begin()
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))

        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .branchChanged(
                            worktreeId: worktreeId,
                            repoId: repoId,
                            from: "feature/old",
                            to: "feature/new"
                        )
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        #expect(await fixture.events.waitForBranchInvalidation(repoId: repoId, branch: "feature/old"))

        await fixture.provider.resolve(
            callAt: 0,
            with: .complete([
                ForgePullRequest(headRefName: "feature/old", url: departedBranchURL)
            ])
        )
        #expect(await fixture.provider.waitForCallCount(2))
        try await probe.expectReturn(1)
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        try await probe.expectReturn(2)
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/new",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )
        #expect(await fixture.events.facts(for: repoId, branch: "feature/old") == nil)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
        try await probe.facts.expectNone(
            of: { fact in
                guard case .output(.pullRequestRepositoryProjectionChanged(_, .stable(.ready(let facts)), _)) = fact
                else { return false }
                return facts["feature/old"]?.exactOpenURL == departedBranchURL
            },
            "departed branch publication through joined current request",
            from: opening,
            closedBy: {
                if case .requestReturned(2) = $0 { return true }
                return false
            })
        try await probe.finish()
    }

    @Test("origin loss resolves to terminal unavailable; repository removal separately invalidates facts")
    func originLossResolvesUnavailableAndRepositoryRemovalInvalidatesFacts() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/origin")])
        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(.originUnavailable(repoId: repoId)),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        // Losing a previously known origin is a terminal "no data is coming"
        // outcome, not a mid-flight invalidation: no automatic query can ever
        // fire again with no origin, so the repo must resolve unavailable
        // rather than fall back to an eternal pending state.
        #expect(await fixture.events.waitForPullRequestsUnavailable(repoId: repoId))
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 1)
        #expect(await fixture.events.repositoryInvalidationCount(repoId: repoId) == 0)

        await fixture.actor.removeRepository(repo: repoId)
        #expect(await fixture.events.waitForRepositoryInvalidationCount(repoId: repoId, expectedCount: 1))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("a worktree that never resolves an origin terminates as unavailable without ever querying")
    func repositoryWithoutOriginNeverQueriesAndResolvesUnavailable() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.actor.register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: URL(fileURLWithPath: "/tmp/acme-no-remote"),
            branch: "main"
        )
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(.originUnavailable(repoId: repoId)),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        // This is the reported bug: a repo that NEVER had an origin (first
        // encounter, no prior ForgeActor state) must still resolve to
        // unavailable exactly once, not silently stay pending forever.
        #expect(await fixture.events.waitForPullRequestsUnavailable(repoId: repoId))
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 1)

        fixture.advance(by: .seconds(600))
        await Task.yield()
        #expect(await fixture.provider.callCount == 0)
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 1)

        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("repeated provider failures resolve to unavailable only after crossing the honesty threshold")
    func repeatedFailuresResolveUnavailableAfterHonestyThreshold() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/unstable")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailureCount(repoId: repoId, expectedCount: 1))
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 0)

        await fixture.clock.waitForPendingSleepCount(atLeast: 1)
        fixture.advance(by: AppPolicies.ForgeRefresh.automaticFailureRetryFloor)
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailureCount(repoId: repoId, expectedCount: 2))
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 0)

        await fixture.clock.waitForPendingSleepCount(atLeast: 1)
        fixture.advance(by: AppPolicies.ForgeRefresh.automaticFailureRetryFloor)
        #expect(await fixture.provider.waitForCallCount(3))
        await fixture.provider.resolve(callAt: 2, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailureCount(repoId: repoId, expectedCount: 3))
        // Crossing AppPolicies.Forge.consecutiveFailureHonestyThreshold (3) on
        // the 3rd consecutive failure resolves the row to unavailable.
        #expect(await fixture.events.waitForPullRequestsUnavailable(repoId: repoId))
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 1)

        // Automatic recovery remains bounded by the three-minute source floor.
        await fixture.clock.waitForPendingSleepCount(atLeast: 1)
        fixture.advance(by: AppPolicies.ForgeRefresh.automaticFailureRetryFloor)
        #expect(await fixture.provider.waitForCallCount(4))
        let recoveryURL = URL(string: "https://github.com/acme/studio/pull/9")!
        await fixture.provider.resolve(
            callAt: 3,
            with: .complete([
                ForgePullRequest(headRefName: "feature/unstable", url: recoveryURL)
            ])
        )
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/unstable",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: recoveryURL)
            )
        )
        // Exactly one unavailable emission across the whole failure→recovery cycle.
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 1)

        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("recovery to the same facts after a terminal-unavailable crossing still republishes")
    func equalFactsRecoveryAfterUnavailableStillRepublishesFacts() async {
        // F2: success(N) -> three failures crossing the honesty threshold (which discards the
        // cached facts on RepoCacheAtom's side) -> a retry that resolves to the SAME facts N must
        // still emit .pullRequestsChanged. ForgeActor's own equal-facts suppression compares
        // against its last internally *published* value, which is untouched by the unavailable
        // transition; without resetting that internal baseline when unavailable is emitted, the
        // repeated identical success is wrongly treated as a no-op and the positive PR chip never
        // returns.
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let pullRequestURL = URL(string: "https://github.com/acme/studio/pull/9")!
        let pullRequest = ForgePullRequest(headRefName: "feature/recover-equal", url: pullRequestURL)

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/recover-equal")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([pullRequest]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/recover-equal",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: pullRequestURL)
            )
        )
        #expect(await fixture.events.pullRequestsChangedCount(for: repoId) == 1)

        // From here every retry is driven by an explicit manual refresh() after advancing past its
        // backoff deadline, rather than the clock-driven automatic follow-up: the automatic path
        // additionally gates on AppPolicies.Forge.automaticRefreshMinimumInterval (180s) measured
        // from the ORIGINAL success above, which would swallow these short failure-backoff
        // advances. Manual refresh bypasses that freshness gate and only waits on backoffUntil.
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailureCount(repoId: repoId, expectedCount: 1))

        fixture.advance(by: AppPolicies.ForgeRefresh.failureBackoffBaseDelay)
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(3))
        await fixture.provider.resolve(callAt: 2, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailureCount(repoId: repoId, expectedCount: 2))

        fixture.advance(by: AppPolicies.ForgeRefresh.failureBackoffDelay(forConsecutiveFailureCount: 2))
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(4))
        await fixture.provider.resolve(callAt: 3, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailureCount(repoId: repoId, expectedCount: 3))
        #expect(await fixture.events.waitForPullRequestsUnavailable(repoId: repoId))
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 1)

        fixture.advance(by: AppPolicies.ForgeRefresh.failureBackoffDelay(forConsecutiveFailureCount: 3))
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(5))
        // Same repository, same facts as the original success(N).
        await fixture.provider.resolve(callAt: 4, with: .complete([pullRequest]))

        #expect(
            await fixture.events.waitForPullRequestsChangedCount(repoId: repoId, expectedCount: 2)
        )
        #expect(
            await fixture.events.facts(for: repoId, branch: "feature/recover-equal")
                == PullRequestFacts(openCount: 1, exactOpenURL: pullRequestURL)
        )
        #expect(await fixture.events.pullRequestsUnavailableCount(for: repoId) == 1)

        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("rejected A-to-B completion cannot suppress identical valid A after emission reentry")
    func rejectedCompletionCannotPoisonLaterIdenticalFacts() async throws {
        let emissionGate = HeldStep<ForgeEvent>("rejected stable emission", cancellation: .holdThroughCancellation)
        let holdFirstStable = Mutex(true)
        let probe = try ForgePublicationProbe(closingRequest: 1)
        let fixture = await ForgeActorFixture.make(
            beforeEventEmission: { event in
                if case .pullRequestRepositoryProjectionChanged(_, .stable, _) = event {
                    let shouldHold = holdFirstStable.withLock { remaining in
                        let result = remaining
                        remaining = false
                        return result
                    }
                    if shouldHold { try? await emissionGate.arrive(event) }
                }
                probe.record(event)
            },
            providerRequestDidReturn: { requestID in
                probe.returned(requestID)
            }
        )
        let repoId = UUIDv7.generate()
        let worktreeAId = UUIDv7.generate()
        let worktreeBId = UUIDv7.generate()
        let pullRequestURL = URL(string: "https://github.com/acme/studio/pull/aba")!
        let pullRequest = ForgePullRequest(
            headRefName: "feature/a",
            url: pullRequestURL
        )

        await fixture.register(
            repoId: repoId,
            worktrees: [
                (worktreeAId, "feature/a"),
                (worktreeBId, "feature/b"),
            ]
        )
        let opening = await probe.begin()
        await fixture.actor.setDemand(worktreeIds: [worktreeAId])
        #expect(await fixture.provider.waitForCallCount(1))

        await fixture.actor.setDemand(worktreeIds: [worktreeBId])
        await fixture.provider.resolve(callAt: 0, with: .complete([pullRequest]))
        _ = try await emissionGate.firstArrival()

        await fixture.actor.setDemand(worktreeIds: [worktreeAId])
        #expect(await fixture.provider.waitForCallCount(2))
        #expect(await fixture.provider.callCount == 2)

        emissionGate.release()
        try await probe.expectReturn(1)
        #expect(await fixture.provider.callCount == 2)

        await fixture.provider.resolve(callAt: 1, with: .complete([pullRequest]))
        try await probe.expectReturn(2)
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/a",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: pullRequestURL)
            )
        )
        #expect(await fixture.events.pullRequestsChangedCount(for: repoId) == 1)
        #expect(await fixture.provider.callCount == 2)

        await fixture.actor.shutdown()
        await fixture.stopObserving()
        try await probe.facts.expectNone(
            of: { fact in
                guard case .output(.pullRequestRepositoryProjectionChanged(_, .stable(.ready(let facts)), _)) = fact
                else { return false }
                return facts["feature/a"]?.exactOpenURL == pullRequestURL
            },
            "rejected request A publication through its actual owner return",
            from: opening,
            closedBy: {
                if case .requestReturned(1) = $0 { return true }
                return false
            })
        try await probe.finish()
    }
}

extension ObservedForgeEvents {
    func loadingStates(for repoId: UUID) -> [Bool] {
        recordedEvents.compactMap { event in
            guard
                case .pullRequestRepositoryProjectionChanged(
                    let eventRepoId,
                    let projection,
                    _
                ) = event,
                eventRepoId == repoId
            else { return nil }
            if case .loading = projection {
                return true
            }
            return false
        }
    }

    func waitForLoadingStates(
        repoId: UUID,
        expected: [Bool]
    ) async -> Bool {
        await waitForRecordedEvent {
            loadingStates(for: repoId) == expected
        }
    }

    func pullRequestsUnavailableCount(for repoId: UUID) -> Int {
        var wasUnavailable = false
        var unavailableTransitionCount = 0
        for event in recordedEvents {
            guard
                case .pullRequestRepositoryProjectionChanged(
                    let eventRepoId,
                    let projection,
                    _
                ) = event,
                eventRepoId == repoId
            else { continue }
            switch projection {
            case .stable(.unavailable):
                if !wasUnavailable {
                    unavailableTransitionCount += 1
                }
                wasUnavailable = true
            case .stable(.unknown), .stable(.ready):
                wasUnavailable = false
            case .loading:
                continue
            }
        }
        return unavailableTransitionCount
    }

    func waitForPullRequestsUnavailable(repoId: UUID) async -> Bool {
        await waitForRecordedEvent {
            pullRequestsUnavailableCount(for: repoId) > 0
        }
    }

    func pullRequestsChangedCount(for repoId: UUID) -> Int {
        var previousReadyFacts: [String: PullRequestFacts]?
        var changedReadyFactsCount = 0
        for event in recordedEvents {
            guard
                case .pullRequestRepositoryProjectionChanged(
                    let eventRepoId,
                    let projection,
                    _
                ) = event,
                eventRepoId == repoId
            else { continue }
            switch projection {
            case .stable(.ready(let factsByBranch)):
                if previousReadyFacts != factsByBranch {
                    changedReadyFactsCount += 1
                }
                previousReadyFacts = factsByBranch
            case .stable(.unknown), .stable(.unavailable):
                previousReadyFacts = nil
            case .loading:
                continue
            }
        }
        return changedReadyFactsCount
    }

    func waitForPullRequestsChangedCount(
        repoId: UUID,
        expectedCount: Int
    ) async -> Bool {
        await waitForRecordedEvent {
            pullRequestsChangedCount(for: repoId) == expectedCount
        }
    }
}
