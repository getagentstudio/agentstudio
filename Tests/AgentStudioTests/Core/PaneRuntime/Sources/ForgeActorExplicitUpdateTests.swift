import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("ForgeActor explicit updates", .serialized)
struct ForgeActorExplicitUpdateTests {
    @Test("explicit repository update reports a genuine provider failure")
    func reportsProviderFailure() async throws {
        let fixture = await ForgeActorFixture.make()
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        await fixture.register(repoId: repoID, worktrees: [(worktreeID, "feature/failure")])
        let lease = try #require(
            await fixture.actor.startExplicitRepositoryUpdate(
                repoId: repoID,
                attemptId: UUIDv7.generate()
            ).acceptedLease
        )
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.provider.resolve(callAt: 0, with: .failed(message: "offline"))
        #expect(await lease.settlement() == .failed)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("explicit repository update follows a current represented branch supersession")
    func followsBranchSupersession() async throws {
        let fixture = await ForgeActorFixture.make()
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        await fixture.register(repoId: repoID, worktrees: [(worktreeID, "feature/one")])
        let lease = try #require(
            await fixture.actor.startExplicitRepositoryUpdate(
                repoId: repoID,
                attemptId: UUIDv7.generate()
            ).acceptedLease
        )
        #expect(await fixture.provider.waitForCallCount(1))
        await fixture.actor.register(
            worktreeId: worktreeID,
            repoId: repoID,
            rootPath: URL(fileURLWithPath: "/tmp/forge-explicit-supersession"),
            branch: "feature/two"
        )
        await fixture.provider.resolve(callAt: 0, with: .complete([]))
        #expect(await fixture.provider.waitForCallCount(2))
        #expect(await fixture.provider.demandedBranchSets.last == ["feature/two"])
        await fixture.provider.resolve(callAt: 1, with: .complete([]))
        #expect(await lease.settlement() == .completed)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test("explicit repository update remains unsettled through rate-limit backoff", arguments: [true, false])
    func remainsUnsettledThroughRateLimit(failProvider: Bool) async throws {
        try await proveForgeSettlementFollowsHeldRead(failProvider: failProvider, afterRateLimit: true)
    }

    @Test("explicit repository update without origin or represented branch is not applicable")
    func withoutScopeIsNotApplicable() async {
        let fixture = await ForgeActorFixture.make()
        let admission = await fixture.actor.startExplicitRepositoryUpdate(
            repoId: UUIDv7.generate(),
            attemptId: UUIDv7.generate()
        )
        #expect(admission.acceptedLease == nil)
        await fixture.actor.shutdown()
        await fixture.stopObserving()
    }

    @Test(
        "cold explicit repository update uses represented branches and waits for provider settlement",
        arguments: [true, false])
    func coldUpdateUsesRepresentedBranches(failProvider: Bool) async throws {
        try await proveForgeSettlementFollowsHeldRead(failProvider: failProvider, afterRateLimit: false)
    }

}

@MainActor
private func proveForgeSettlementFollowsHeldRead(failProvider: Bool, afterRateLimit: Bool) async throws {
    let terminalRead = HeldStep<Set<String>>("forge terminal provider read", cancellation: .holdThroughCancellation)
    let rateRead =
        afterRateLimit
        ? HeldStep<Set<String>>("forge rate-limited provider read", cancellation: .holdThroughCancellation) : nil
    let provider = ForgeHeldReadProvider(terminalRead: terminalRead, rateRead: rateRead)
    let probe = try ForgePublicationProbe()
    let clock = TestPushClock()
    let monotonic = ManualForgeMonotonicNow()
    let actor = ForgeActor(
        bus: EventBus<RuntimeEnvelope>(), statusProvider: provider, providerName: "causal-test",
        monotonicNow: { monotonic.value }, sleepClock: clock, providerRequestDidReturn: { probe.returned($0) })
    let repoID = UUIDv7.generate()
    await actor.register(
        worktreeId: UUIDv7.generate(), repoId: repoID,
        rootPath: URL(fileURLWithPath: "/tmp/forge-causal"), branch: "feature/causal")
    await actor.setOrigin(repo: repoID, remote: "git@github.com:acme/studio.git")
    let lease = try #require(
        await actor.startExplicitRepositoryUpdate(repoId: repoID, attemptId: UUIDv7.generate()).acceptedLease)
    if let rateRead {
        #expect(try await rateRead.firstArrival() == ["feature/causal"])
        rateRead.release()
        try await probe.expectReturn(1)
        #expect(await actor.refreshStateByRepoId[repoID]?.backoffUntil == Duration.seconds(300))
        monotonic.advance(by: .seconds(300))
        clock.advance(by: .seconds(300))
    }
    #expect(try await terminalRead.firstArrival() == ["feature/causal"])
    if failProvider { terminalRead.fail(ForgeHeldReadFailure.unavailable) } else { terminalRead.release() }
    let outcome = await lease.settlement()
    try await probe.expectReturn(afterRateLimit ? 2 : 1)
    await actor.shutdown()
    try await probe.finish()
    #expect(outcome == (failProvider ? .failed : .completed))
}

private enum ForgeHeldReadFailure: Error { case unavailable }

private actor ForgeHeldReadProvider: ForgeStatusProvider {
    let terminalRead: HeldStep<Set<String>>
    let rateRead: HeldStep<Set<String>>?
    private var readCount = 0

    init(terminalRead: HeldStep<Set<String>>, rateRead: HeldStep<Set<String>>?) {
        self.terminalRead = terminalRead
        self.rateRead = rateRead
    }

    func pullRequests(origin _: String, demandedBranches: Set<String>) async -> ForgePullRequestQueryOutcome {
        readCount += 1
        if readCount == 1, let rateRead {
            try? await rateRead.arrive(demandedBranches)
            return .rateLimited(retryAfterSeconds: 300)
        }
        do {
            try await terminalRead.arrive(demandedBranches)
            return .complete([])
        } catch {
            return .failed(message: "held provider unavailable")
        }
    }
}
