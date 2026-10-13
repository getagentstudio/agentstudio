import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("ForgeActor demanded-scope admission", .serialized)
struct ForgeActorDemandScopeAdmissionTests {
    private struct ConfirmedAndUnconfirmedBranchFixture {
        let fixture: ForgeActorFixture
        let repoId: UUID
        let confirmedWorktreeId: UUID
        let unconfirmedWorktreeId: UUID
    }

    @Test("newly demanded unconfirmed branch bypasses successful-result freshness")
    func newlyDemandedUnconfirmedBranchRefreshesImmediately() async {
        let fixture = await makeFixtureWithConfirmedAndUnconfirmedBranches()

        await fixture.fixture.actor.setDemand(
            worktreeIds: [fixture.confirmedWorktreeId, fixture.unconfirmedWorktreeId]
        )

        #expect(await fixture.fixture.provider.waitForCallCount(2))
        #expect(await fixture.fixture.provider.callCount == 2)
        #expect(
            await fixture.fixture.provider.demandedBranchSets.last
                == ["feature/confirmed", "feature/unconfirmed"]
        )
        await fixture.fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.fixture.actor.shutdown()
        await fixture.fixture.stopObserving()
    }

    @Test("newly demanded unconfirmed branch retains scope-change admission while capacity is full")
    func newlyDemandedUnconfirmedBranchSurvivesCapacityDeferral() async {
        let target = await makeFixtureWithConfirmedAndUnconfirmedBranches()
        let firstBlockingRepoId = UUIDv7.generate()
        let secondBlockingRepoId = UUIDv7.generate()
        let firstBlockingWorktreeId = UUIDv7.generate()
        let secondBlockingWorktreeId = UUIDv7.generate()
        await target.fixture.register(
            repoId: firstBlockingRepoId,
            worktrees: [(firstBlockingWorktreeId, "feature/blocking-one")]
        )
        await target.fixture.register(
            repoId: secondBlockingRepoId,
            worktrees: [(secondBlockingWorktreeId, "feature/blocking-two")]
        )
        await target.fixture.actor.setDemand(
            worktreeIds: [
                target.confirmedWorktreeId,
                firstBlockingWorktreeId,
                secondBlockingWorktreeId,
            ]
        )
        #expect(await target.fixture.provider.waitForCallCount(3))
        let blockingTasks = await Array(target.fixture.actor.providerTasksByRequestId.values)

        await target.fixture.actor.setDemand(
            worktreeIds: [
                target.confirmedWorktreeId,
                target.unconfirmedWorktreeId,
                firstBlockingWorktreeId,
                secondBlockingWorktreeId,
            ]
        )
        // setDemand has returned; both existing provider requests are still held and
        // both scheduling clocks are frozen. Admission itself is observable here,
        // even when the new provider task has not entered its call counter yet.
        #expect(await !target.fixture.actor.providerRepoIdByRequestId.values.contains(target.repoId))
        #expect(await target.fixture.actor.refreshStateByRepoId[target.repoId]?.activeRequestId == nil)
        #expect(await target.fixture.actor.refreshStateByRepoId[target.repoId]?.pendingFollowUp == true)
        #expect(
            await target.fixture.actor.refreshStateByRepoId[target.repoId]?.pendingFollowUpHasUnconfirmedScopeChange
                == true)
        #expect(await target.fixture.provider.callCount == 3)
        await target.fixture.provider.resolve(callAt: 1, with: .complete([]))

        #expect(await target.fixture.provider.waitForCallCount(4))
        #expect(
            await target.fixture.provider.demandedBranchSets[3]
                == ["feature/confirmed", "feature/unconfirmed"]
        )
        let remainingTasks = await Array(target.fixture.actor.providerTasksByRequestId.values)
        await target.fixture.provider.resolve(callAt: 2, with: .complete([]))
        await target.fixture.provider.resolve(callAt: 3, with: .complete([]))
        for task in blockingTasks + remainingTasks { await task.value }
        await target.fixture.actor.shutdown()
        await target.fixture.stopObserving()
    }

    @Test("same demanded branch scope remains suppressed until successful-result freshness expires")
    func sameDemandedBranchScopeRespectsSuccessfulResultFreshness() async {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let branch = "feature/shared"
        await fixture.register(
            repoId: repoId,
            worktrees: [(firstWorktreeId, branch), (secondWorktreeId, branch)]
        )
        await fixture.actor.setDemand(worktreeIds: [firstWorktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: branch,
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            ))

        let nextFreshnessSleepGeneration = fixture.clock.scheduledSleepGeneration
        await fixture.actor.setDemand(worktreeIds: [secondWorktreeId])
        await fixture.clock.waitForPendingSleepCount(
            atLeast: 1,
            fromGeneration: nextFreshnessSleepGeneration
        )
        #expect(await fixture.provider.callCount == 1)
        fixture.advance(by: AppPolicies.Forge.automaticRefreshMinimumInterval)

        #expect(await fixture.provider.waitForCallCount(2))
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("scope-change refresh respects backoff and then bypasses older successful freshness")
    func newlyDemandedUnconfirmedBranchPreservesBackoff() async {
        let fixture = await makeFixtureWithConfirmedAndUnconfirmedBranches()
        await fixture.fixture.actor.refresh(repo: fixture.repoId)
        #expect(await fixture.fixture.provider.waitForCallCount(2))
        await fixture.fixture.provider.resolve(callAt: 1, with: .failed(message: "offline"))
        #expect(await fixture.fixture.events.waitForRefreshFailure(repoId: fixture.repoId))

        let nextBackoffSleepGeneration = fixture.fixture.clock.scheduledSleepGeneration
        await fixture.fixture.actor.setDemand(
            worktreeIds: [fixture.confirmedWorktreeId, fixture.unconfirmedWorktreeId]
        )
        await fixture.fixture.clock.waitForPendingSleepCount(
            atLeast: 1,
            fromGeneration: nextBackoffSleepGeneration
        )
        #expect(await fixture.fixture.provider.callCount == 2)
        fixture.fixture.advance(by: AppPolicies.ForgeRefresh.failureBackoffBaseDelay)

        #expect(await fixture.fixture.provider.waitForCallCount(3))
        #expect(
            await fixture.fixture.provider.demandedBranchSets[2]
                == ["feature/confirmed", "feature/unconfirmed"]
        )
        await fixture.fixture.provider.resolve(callAt: 2, with: .complete([]))
        await fixture.fixture.actor.shutdown()
        await fixture.fixture.stopObserving()
    }

    private func makeFixtureWithConfirmedAndUnconfirmedBranches() async
        -> ConfirmedAndUnconfirmedBranchFixture
    {
        let fixture = await ForgeActorFixture.make()
        let repoId = UUIDv7.generate()
        let confirmedWorktreeId = UUIDv7.generate()
        let unconfirmedWorktreeId = UUIDv7.generate()
        await fixture.register(
            repoId: repoId,
            worktrees: [
                (confirmedWorktreeId, "feature/confirmed"),
                (unconfirmedWorktreeId, "feature/unconfirmed"),
            ]
        )
        await fixture.actor.setDemand(worktreeIds: [confirmedWorktreeId])
        #expect(await fixture.provider.waitForCallCount(1))
        let confirmationTasks = await Array(fixture.actor.providerTasksByRequestId.values)
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(
            await fixture.events.waitForFacts(
                repoId: repoId,
                branch: "feature/confirmed",
                expected: PullRequestFacts(openCount: 0, exactOpenURL: nil)
            ))
        for task in confirmationTasks { await task.value }
        return ConfirmedAndUnconfirmedBranchFixture(
            fixture: fixture,
            repoId: repoId,
            confirmedWorktreeId: confirmedWorktreeId,
            unconfirmedWorktreeId: unconfirmedWorktreeId
        )
    }
}
