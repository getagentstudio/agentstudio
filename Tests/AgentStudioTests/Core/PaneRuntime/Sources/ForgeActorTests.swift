import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("ForgeActor")
struct ForgeActorTests {
    @Test("overlapping refreshes keep at most one provider call in flight per repo")
    func overlappingRefreshesKeepOneProviderCallInFlightPerRepo() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/one")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.actor.refresh(repo: repoId)
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.callCount == 1)
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("equal successful facts publish only once")
    func equalSuccessfulCountMapsPublishOnlyOnce() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let pullRequestURL = URL(string: "https://github.com/acme/studio/pull/1")!
        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/equal")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        let result = ForgePullRequest(headRefName: "feature/equal", url: pullRequestURL)
        await fixture.provider.resolve(callAt: 0, with: .complete([result]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/equal",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: pullRequestURL)
            ))
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .complete([result]))
        await Task.yield()
        #expect(await fixture.events.pullRequestEventCount(for: repoId) == 1)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("automatic provider failures retry only at the three-minute floor")
    func automaticProviderFailuresUseThreeMinuteFloor() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/failure")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailure(repoId: repoId))
        await fixture.clock.waitForPendingSleepCount(atLeast: 1)
        fixture.advance(by: .seconds(179))
        await Task.yield()
        #expect(await fixture.provider.callCount == 1)
        fixture.advance(by: .seconds(1))
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(
            callAt: 1,
            with: .complete([
                ForgePullRequest(
                    headRefName: "feature/failure",
                    url: URL(string: "https://github.com/acme/studio/pull/2")!
                )
            ])
        )
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("changed facts publish after an equal result was suppressed")
    func changedCountMapPublishesAfterEqualSuppression() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/changed")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        let firstURL = URL(string: "https://github.com/acme/studio/pull/3")!
        await fixture.provider.resolve(
            callAt: 0,
            with: .complete([ForgePullRequest(headRefName: "feature/changed", url: firstURL)])
        )
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/changed",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: firstURL)
            ))
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(
            callAt: 1,
            with: .complete([ForgePullRequest(headRefName: "feature/changed", url: firstURL)])
        )
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.waitForCallCount(3))
        let secondURL = URL(string: "https://github.com/acme/studio/pull/4")!
        await fixture.provider.resolve(
            callAt: 2,
            with: .complete([ForgePullRequest(headRefName: "feature/changed", url: secondURL)])
        )
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/changed",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: secondURL)
            ))
        #expect(await fixture.events.pullRequestEventCount(for: repoId) == 2)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("different repos may refresh concurrently")
    func differentReposMayRefreshConcurrently() async {
        let fixture = await ForgeActorFixture.make()
        let firstRepoId = UUIDv7.generate()
        let secondRepoId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        await fixture.register(repoId: firstRepoId, worktrees: [(firstWorktreeId, "feature/first")])
        await fixture.register(repoId: secondRepoId, worktrees: [(secondWorktreeId, "feature/second")])
        await fixture.actor.setDemand(worktreeIds: [firstWorktreeId, secondWorktreeId])
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("process capacity two defers the third repository until exact provider return")
    func processCapacityTwoDefersThirdRepository() async {
        let fixture = await ForgeActorFixture.make()
        let firstRepoId = UUIDv7.generate()
        let secondRepoId = UUIDv7.generate()
        let thirdRepoId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let thirdWorktreeId = UUIDv7.generate()
        await fixture.register(repoId: firstRepoId, worktrees: [(firstWorktreeId, "feature/first")])
        await fixture.register(repoId: secondRepoId, worktrees: [(secondWorktreeId, "feature/second")])
        await fixture.register(repoId: thirdRepoId, worktrees: [(thirdWorktreeId, "feature/third")])

        await fixture.actor.setDemand(
            worktreeIds: [firstWorktreeId, secondWorktreeId, thirdWorktreeId]
        )
        #expect(await fixture.provider.waitForCallCount(2))
        #expect(await fixture.provider.callCount == 2)
        #expect(await fixture.provider.maximumActiveCallCount == 2)

        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(await fixture.provider.waitForCallCount(3))
        #expect(await fixture.provider.maximumActiveCallCount == 2)
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.provider.resolve(callAt: 2, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("repository removal cancels its provider flight")
    func unregisterCancelsRepoProviderFlight() async {
        let bus = EventBus<RuntimeEnvelope>()
        let provider = CancellationObservingForgeStatusProvider()
        let actor = ForgeActor(bus: bus, statusProvider: provider, providerName: "cancellation-observing")
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        await actor.start()
        await actor.register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: URL(fileURLWithPath: "/tmp/acme-cancel"),
            branch: "feature/cancel"
        )
        await actor.setOrigin(repo: repoId, remote: "git@github.com:acme/studio.git")
        await actor.setDemand(worktreeIds: [worktreeId])
        await provider.waitUntilStarted()
        await actor.removeRepository(repo: repoId)
        await provider.waitUntilCancelled()
        #expect(await provider.didObserveCancellation)
        await actor.shutdown()
    }

    @Test("reacts to origin and branch projector events")
    func reactsToGitProjectorEvents() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        await fixture.actor.register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: URL(fileURLWithPath: "/tmp/acme-events"),
            branch: "main"
        )
        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .originChanged(
                            repoId: repoId,
                            from: "",
                            to: "git@github.com:acme/studio.git"
                        )),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )))
        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .branchChanged(
                            worktreeId: worktreeId,
                            repoId: repoId,
                            from: "main",
                            to: "feature/runtime"
                        )),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )))
        #expect(await fixture.events.waitForBranchInvalidation(repoId: repoId, branch: "main"))
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(
            callAt: 0,
            with: .complete([
                ForgePullRequest(
                    headRefName: "feature/runtime",
                    url: URL(string: "https://github.com/acme/studio/pull/5")!
                )
            ])
        )
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/runtime",
                expected: PullRequestFacts(
                    openCount: 1, exactOpenURL: URL(string: "https://github.com/acme/studio/pull/5")!)
            ))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("emits refreshFailed when provider fails")
    func pollingFallbackErrorPath() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/error")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .failed(message: "offline"))
        #expect(await fixture.events.waitForRefreshFailure(repoId: repoId))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("register and unregister command-plane APIs control scope explicitly")
    func commandPlaneRegisterAndUnregister() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/runtime")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        await fixture.actor.unregister(worktreeId: worktreeId)
        await fixture.actor.refresh(repo: repoId)
        #expect(await fixture.provider.callCount == 1)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("shutdown cancels subscriptions so post-shutdown events are ignored")
    func shutdownStopsConsumingBusEvents() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        await fixture.actor.shutdown()
        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .originChanged(
                            repoId: repoId,
                            from: "",
                            to: "git@github.com:acme/studio.git"
                        )),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )))
        #expect(await fixture.events.facts(for: repoId, branch: "feature/runtime") == nil)
        await fixture.stopObserving()
    }
    @Test("missing demanded branch starts an immediate repository refresh")
    func missingDemandStartsImmediateRefresh() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let pullRequestURL = URL(string: "https://github.com/acme/studio/pull/42")!

        await fixture.actor.register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: URL(fileURLWithPath: "/tmp/acme-studio"),
            branch: "feature/toolbar"
        )
        await fixture.actor.setOrigin(repo: repoId, remote: "git@github.com:acme/studio.git")
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))

        await fixture.provider.resolve(
            callAt: 0,
            with: .complete([
                ForgePullRequest(headRefName: "feature/toolbar", url: pullRequestURL)
            ])
        )

        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/toolbar",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: pullRequestURL)
            )
        )
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("one active request admits only one latest-scope follow-up")
    func oneActiveRequestAndOneLatestFollowUp() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let latestWorktreeId = UUIDv7.generate()

        await fixture.register(
            repoId: repoId,
            worktrees: [
                (firstWorktreeId, "feature/first"),
                (secondWorktreeId, "feature/second"),
                (latestWorktreeId, "feature/latest"),
            ]
        )
        await fixture.actor.setDemand(worktreeIds: [firstWorktreeId])
        #expect(await fixture.provider.waitForCallCount(1))

        await fixture.actor.setDemand(worktreeIds: [secondWorktreeId])
        await fixture.actor.setDemand(worktreeIds: [latestWorktreeId])
        #expect(await fixture.provider.callCount == 1)

        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(await fixture.provider.waitForCallCount(2))
        #expect(await fixture.provider.callCount == 2)

        let latestURL = URL(string: "https://github.com/acme/studio/pull/99")!
        await fixture.provider.resolve(
            callAt: 1,
            with: .complete([
                ForgePullRequest(headRefName: "feature/latest", url: latestURL)
            ])
        )
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/latest",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: latestURL)
            )
        )
        #expect(await fixture.events.facts(for: repoId, branch: "feature/second") == nil)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("identical snapshot and branch events do not repeat a completed provider request")
    func identicalSnapshotAndBranchEventsDoNotRepeatCompletedProviderRequest() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/acme-forge-paired-events")
        let branch = "feature/paired-events"
        let origin = "git@github.com:acme/studio.git"
        await fixture.actor.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath, branch: nil)
        await fixture.actor.setOrigin(repo: repoId, remote: origin)
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.callCount == 0)
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
        _ = await fixture.bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .branchChanged(
                            worktreeId: worktreeId,
                            repoId: repoId,
                            from: branch,
                            to: branch
                        )
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector))
                )
            )
        )
        #expect(await fixture.provider.waitForCallCount(1))
        for _ in 0..<100 {
            await Task.yield()
        }
        let pullRequestURL = URL(string: "https://github.com/acme/studio/pull/100")!
        await fixture.provider.resolve(
            callAt: 0,
            with: .complete([
                ForgePullRequest(headRefName: branch, url: pullRequestURL)
            ])
        )
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: branch,
                expected: PullRequestFacts(openCount: 1, exactOpenURL: pullRequestURL)
            )
        )
        #expect(await fixture.provider.origins == [origin])
        #expect(await fixture.provider.callCount == 1)
        await fixture.provider.resolveIfPresent(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("fresh demand waits for the single three-minute deadline")
    func freshDemandWaitsForDeadline() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/fresh")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/fresh",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )
        await fixture.clock.waitForPendingSleepCount(atLeast: 1)

        fixture.advance(by: .seconds(179))
        await Task.yield()
        #expect(await fixture.provider.callCount == 1)

        fixture.advance(by: .seconds(1))
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("empty demand cancels future automatic GitHub work")
    func emptyDemandStopsAutomaticRefresh() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/visible")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/visible",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            )
        )

        await fixture.actor.setDemand(worktreeIds: [])
        let remainingDemand = await fixture.actor.demandedRepoIds()
        #expect(remainingDemand.isEmpty)
        if remainingDemand.isEmpty {
            await fixture.clock.waitForPendingSleepCount(exactly: 0)
        }
        fixture.advance(by: .seconds(600))

        #expect(await fixture.provider.callCount == 1)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("rate-limit retry respects retry-after and the three-minute minimum")
    func rateLimitBackoffControlsDeadline() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/rate-limit")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .rateLimited(retryAfterSeconds: 300))
        #expect(await fixture.events.waitForRateLimit(repoId: repoId, retryAfterSeconds: 300))
        await fixture.clock.waitForPendingSleepCount(atLeast: 1)
        #expect(await fixture.actor.refreshStateByRepoId[repoId]?.backoffUntil == Duration.seconds(300))

        fixture.advance(by: .seconds(299))
        #expect(await fixture.provider.callCount == 1)

        fixture.advance(by: .seconds(1))
        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("origin replacement invalidates prior facts and rejects the obsolete completion")
    func originReplacementRejectsObsoleteCompletion() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await fixture.register(repoId: repoId, worktrees: [(worktreeId, "feature/origin")])
        await fixture.actor.setDemand(worktreeIds: [worktreeId])
        #expect(await fixture.provider.waitForCallCount(1))

        await fixture.actor.setOrigin(repo: repoId, remote: "https://github.com/acme/replacement.git")
        #expect(await fixture.events.waitForRepositoryInvalidation(repoId: repoId))
        #expect(await fixture.provider.callCount == 1)

        let obsoleteURL = URL(string: "https://github.com/acme/studio/pull/1")!
        await fixture.provider.resolve(
            callAt: 0,
            with: .complete([ForgePullRequest(headRefName: "feature/origin", url: obsoleteURL)])
        )
        #expect(await fixture.provider.waitForCallCount(2))
        let currentURL = URL(string: "https://github.com/acme/replacement/pull/2")!
        await fixture.provider.resolve(
            callAt: 1,
            with: .complete([ForgePullRequest(headRefName: "feature/origin", url: currentURL)])
        )

        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/origin",
                expected: PullRequestFacts(openCount: 1, exactOpenURL: currentURL)
            )
        )
        #expect(await fixture.events.containsExactURL(obsoleteURL) == false)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("only final live membership removal invalidates a shared branch")
    func finalMembershipRemovalInvalidatesSharedBranch() async throws {
        let probe = try ForgePublicationProbe()
        let fixture = await ForgeActorFixture.make(beforeEventEmission: { probe.record($0) })
        let repoId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()

        await fixture.register(
            repoId: repoId,
            worktrees: [
                (firstWorktreeId, "feature/shared"),
                (secondWorktreeId, "feature/shared"),
            ]
        )
        _ = await probe.begin()
        await fixture.actor.unregister(worktreeId: firstWorktreeId)
        #expect(
            probe.outputs.allSatisfy { event in
                if case .pullRequestRepositoryProjectionChanged(_, _, let branches) = event {
                    return !branches.contains("feature/shared")
                }
                return true
            })

        await fixture.actor.unregister(worktreeId: secondWorktreeId)

        #expect(await fixture.events.waitForBranchInvalidation(repoId: repoId, branch: "feature/shared"))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
        try await probe.finish()
    }

}

struct ForgeActorFixture {
    let bus: EventBus<RuntimeEnvelope>
    let actor: ForgeActor
    let provider: GatedForgeStatusProvider
    let events: ObservedForgeEvents
    let clock: TestPushClock
    let monotonicNow: ManualForgeMonotonicNow
    let observationTask: Task<Void, Never>
    static func make(
        performanceTraceRecorder: (any ForgePerformanceRecording)? = nil,
        maximumConcurrentProviderRequests: Int =
            AppPolicies.ForgeRefresh.maximumConcurrentProviderRequests,
        beforeEventEmission: (@Sendable (ForgeEvent) async -> Void)? = nil,
        providerRequestDidReturn: (@Sendable (UInt64) -> Void)? = nil
    ) async -> Self {
        let bus = EventBus<RuntimeEnvelope>()
        let provider = GatedForgeStatusProvider()
        let events = ObservedForgeEvents()
        let clock = TestPushClock()
        let monotonicNow = ManualForgeMonotonicNow()
        let actor = ForgeActor(
            bus: bus,
            statusProvider: provider,
            providerName: "stub",
            monotonicNow: { monotonicNow.value },
            sleepClock: clock,
            maximumConcurrentProviderRequests: maximumConcurrentProviderRequests,
            performanceTraceRecorder: performanceTraceRecorder,
            beforeEventEmission: beforeEventEmission,
            providerRequestDidReturn: providerRequestDidReturn
        )
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let observationTask = Task {
            for await envelope in stream {
                await events.record(envelope)
            }
        }
        await actor.start()
        return Self(
            bus: bus,
            actor: actor,
            provider: provider,
            events: events,
            clock: clock,
            monotonicNow: monotonicNow,
            observationTask: observationTask
        )
    }

    func register(repoId: UUID, worktrees: [(UUID, String)]) async {
        for (index, worktree) in worktrees.enumerated() {
            await actor.register(
                worktreeId: worktree.0,
                repoId: repoId,
                rootPath: URL(fileURLWithPath: "/tmp/acme-studio-\(index)"),
                branch: worktree.1
            )
        }
        await actor.setOrigin(repo: repoId, remote: "git@github.com:acme/studio.git")
    }

    func advance(by duration: Duration) {
        monotonicNow.advance(by: duration)
        clock.advance(by: duration)
    }

    func stopObserving() async {
        observationTask.cancel()
        await observationTask.value
    }
}

final class ManualForgeMonotonicNow: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed = Duration.zero

    var value: Duration { lock.withLock { elapsed } }

    func advance(by duration: Duration) {
        lock.withLock { elapsed += duration }
    }
}

actor ObservedForgeEvents {
    // Internal so focused Forge test files can add scoped read helpers.
    var recordedEvents: [ForgeEvent] = []
    private var eventChangeWaiters: [CheckedContinuation<Void, Never>] = []

    func record(_ envelope: RuntimeEnvelope) {
        guard case .worktree(let worktreeEnvelope) = envelope,
            case .forge(let forgeEvent) = worktreeEnvelope.event
        else { return }
        recordedEvents.append(forgeEvent)
        let waiters = eventChangeWaiters
        eventChangeWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForRecordedEvent(matching predicate: () -> Bool) async -> Bool {
        while !predicate() {
            await withCheckedContinuation { continuation in
                eventChangeWaiters.append(continuation)
            }
        }
        return true
    }

    func facts(for repoId: UUID, branch: String) -> PullRequestFacts? {
        for event in recordedEvents.reversed() {
            guard
                case .pullRequestRepositoryProjectionChanged(
                    let eventRepoId,
                    let projection,
                    _
                ) = event,
                eventRepoId == repoId
            else { continue }
            return projection.confirmedFactsByBranch?[branch]
        }
        return nil
    }

    func waitForFacts(
        repoId: UUID,
        branch: String,
        expected: PullRequestFacts
    ) async -> Bool {
        await waitForRecordedEvent {
            facts(for: repoId, branch: branch) == expected
        }
    }

    func invalidatedBranches(for repoId: UUID) -> Set<String> {
        recordedEvents.reduce(into: []) { result, event in
            guard
                case .pullRequestRepositoryProjectionChanged(
                    let eventRepoId,
                    _,
                    let branches
                ) = event,
                eventRepoId == repoId
            else { return }
            result.formUnion(branches)
        }
    }

    func waitForBranchInvalidation(repoId: UUID, branch: String) async -> Bool {
        await waitForRecordedEvent {
            invalidatedBranches(for: repoId).contains(branch)
        }
    }

    func waitForRepositoryInvalidation(repoId: UUID) async -> Bool {
        await waitForRecordedEvent {
            recordedEvents.contains(where: { event in
                guard
                    case .pullRequestRepositoryProjectionChanged(
                        let eventRepoId,
                        .stable(.unknown),
                        _
                    ) = event
                else { return false }
                return eventRepoId == repoId
            })
        }
    }

    func repositoryInvalidationCount(repoId: UUID) -> Int {
        recordedEvents.count { event in
            guard
                case .pullRequestRepositoryProjectionChanged(
                    let eventRepoId,
                    .stable(.unknown),
                    _
                ) = event
            else { return false }
            return eventRepoId == repoId
        }
    }

    func waitForRepositoryInvalidationCount(
        repoId: UUID,
        expectedCount: Int
    ) async -> Bool {
        await waitForRecordedEvent {
            repositoryInvalidationCount(repoId: repoId) == expectedCount
        }
    }

    func waitForRefreshFailure(repoId: UUID) async -> Bool {
        await waitForRecordedEvent {
            recordedEvents.contains(where: { event in
                guard case .refreshFailed(let eventRepoId, _) = event else { return false }
                return eventRepoId == repoId
            })
        }
    }

    func waitForRateLimit(repoId: UUID, retryAfterSeconds: Int) async -> Bool {
        await waitForRecordedEvent {
            recordedEvents.contains(where: { event in
                guard case .rateLimited(let eventRepoId, let eventRetryAfter) = event else { return false }
                return eventRepoId == repoId && eventRetryAfter == retryAfterSeconds
            })
        }
    }

    func containsExactURL(_ url: URL) -> Bool {
        recordedEvents.contains { event in
            guard
                case .pullRequestRepositoryProjectionChanged(
                    _,
                    .stable(.ready(let factsByBranch)),
                    _
                ) = event
            else { return false }
            return factsByBranch.values.contains { $0.exactOpenURL == url }
        }
    }

    func pullRequestEventCount(for repoId: UUID) -> Int {
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

    func refreshFailureCount(for repoId: UUID) -> Int {
        recordedEvents.count { event in
            guard case .refreshFailed(let eventRepoId, _) = event else { return false }
            return eventRepoId == repoId
        }
    }

    func refreshFailedCount(for repoId: UUID) -> Int {
        refreshFailureCount(for: repoId)
    }

    func waitForRefreshFailureCount(
        repoId: UUID,
        expectedCount: Int
    ) async -> Bool {
        await waitForRecordedEvent {
            refreshFailureCount(for: repoId) >= expectedCount
        }
    }
}
