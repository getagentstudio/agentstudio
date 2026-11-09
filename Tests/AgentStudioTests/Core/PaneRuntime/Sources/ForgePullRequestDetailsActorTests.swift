import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Demanded PR details")
struct ForgePullRequestDetailsActorTests {
    private func identity(_ number: Int = 7) throws -> ForgePullRequestIdentity {
        try .init(host: "github.com", owner: "owner", repository: "repo", number: number)
    }

    @Test("Missing details load; reopening before 180s stays fresh; stale refresh keeps the prior details")
    func freshnessAndRetainedDetails() async throws {
        let key = try identity()
        let first = try testPullRequestDetails(title: "First")
        let second = try testPullRequestDetails(title: "Second")
        try await withForgePullRequestDetails(responses: [[key: .loaded(first)], [key: .loaded(second)]]) { fixture in
            let initial = ForgePullRequestLastGoodRead(details: first, readAt: fixture.time.now)
            await fixture.actor.setDemand(identities: [key])
            try await fixture.facts.expectNext(in: key, .refreshing(previous: nil))
            try await fixture.facts.expectNext(in: key, .fresh(initial))
            fixture.clock.advance(by: .seconds(179))
            await fixture.actor.setDemand(identities: [key])
            #expect(await fixture.actor.snapshot()[key] == .fresh(initial))
            #expect(await fixture.provider.calls.count == 1)
            fixture.clock.advance(by: .seconds(1))
            try await fixture.facts.expectNext(in: key, .refreshing(previous: initial))
            try await fixture.facts.expectNext(in: key, .fresh(.init(details: second, readAt: fixture.time.now)))
            #expect(await fixture.provider.calls.count == 2)
        }
    }

    @Test("No demand makes no calls; worktree and added identities are identical inputs; hiding cancels future work")
    func noDemandAndWorktreeIdentity() async throws {
        let added = try identity()
        let worktree = try identity(8)
        let addedDetails = try testPullRequestDetails()
        let worktreeDetails = try testPullRequestDetails(number: 8)
        try await withForgePullRequestDetails(responses: [
            [added: .loaded(addedDetails), worktree: .loaded(worktreeDetails)]
        ]) { fixture in
            await fixture.actor.setDemand(identities: [])
            fixture.clock.advance(by: .seconds(3600))
            await fixture.actor.setDemand(identities: [])
            #expect(await fixture.provider.calls.isEmpty)
            #expect(await fixture.actor.snapshot().isEmpty)
            await fixture.actor.setDemand(identities: [added, worktree])
            for (key, details) in [(added, addedDetails), (worktree, worktreeDetails)] {
                try await fixture.facts.expectNext(in: key, .refreshing(previous: nil))
                try await fixture.facts.expectNext(in: key, .fresh(.init(details: details, readAt: fixture.time.now)))
            }
            #expect(await fixture.provider.calls == [[added, worktree]])
            await fixture.actor.setDemand(identities: [])
            #expect(fixture.clock.pendingSleepCount == 0)
            fixture.clock.advance(by: .seconds(3600))
            await fixture.actor.setDemand(identities: [])
            #expect(await fixture.provider.calls.count == 1)
        }
    }

    @Test("Refresh failure retains last good details and time, then the next success clears the failure")
    func failedRefreshRecovers() async throws {
        let key = try identity()
        let first = try testPullRequestDetails(title: "Kept")
        let recovered = try testPullRequestDetails(title: "Recovered")
        try await withForgePullRequestDetails(responses: [
            [key: .loaded(first)], [key: .failed(.offline)], [key: .loaded(recovered)],
        ]) { fixture in
            let good = ForgePullRequestLastGoodRead(details: first, readAt: fixture.time.now)
            await fixture.actor.setDemand(identities: [key])
            try await fixture.facts.expectNext(in: key, .refreshing(previous: nil))
            try await fixture.facts.expectNext(in: key, .fresh(good))
            fixture.clock.advance(by: .seconds(180))
            try await fixture.facts.expectNext(in: key, .refreshing(previous: good))
            try await fixture.facts.expectNext(in: key, .failed(reason: .offline, previous: good))
            #expect(await fixture.actor.snapshot()[key]?.last == first)
            #expect(await fixture.actor.snapshot()[key]?.lastGoodReadAt == good.readAt)
            await fixture.actor.setDemand(identities: [key])
            #expect(await fixture.provider.calls.count == 2)
            fixture.clock.advance(by: .seconds(180))
            try await fixture.facts.expectNext(in: key, .refreshing(previous: good))
            try await fixture.facts.expectNext(in: key, .fresh(.init(details: recovered, readAt: fixture.time.now)))
            #expect(await fixture.actor.snapshot()[key]?.health == .fresh)
        }
    }

    @Test("A first read failure has no invented details")
    func firstFailureIsUnavailable() async throws {
        let key = try identity()
        try await withForgePullRequestDetails(responses: [[key: .failed(.noAccess)]]) { fixture in
            await fixture.actor.setDemand(identities: [key])
            try await fixture.facts.expectNext(in: key, .refreshing(previous: nil))
            try await fixture.facts.expectNext(in: key, .failed(reason: .noAccess, previous: nil))
            #expect(await fixture.actor.snapshot()[key]?.last == nil)
        }
    }

    @Test("Rate-limit retry-after can extend the 180-second automatic retry floor")
    func rateLimitExtendsRetryFloor() async throws {
        let key = try identity()
        let details = try testPullRequestDetails()
        try await withForgePullRequestDetails(responses: [
            [key: .failed(.rateLimited(retryAfterSeconds: 240))], [key: .loaded(details)],
        ]) { fixture in
            await fixture.actor.setDemand(identities: [key])
            try await fixture.facts.expectNext(in: key, .refreshing(previous: nil))
            try await fixture.facts.expectNext(in: key, .failed(reason: .rateLimited, previous: nil))
            fixture.clock.advance(by: .seconds(180))
            await fixture.actor.setDemand(identities: [key])
            #expect(await fixture.actor.snapshot()[key]?.health == .failed(.rateLimited))
            #expect(await fixture.provider.calls.count == 1)
            fixture.clock.advance(by: .seconds(60))
            try await fixture.facts.expectNext(in: key, .refreshing(previous: nil))
            try await fixture.facts.expectNext(in: key, .fresh(.init(details: details, readAt: fixture.time.now)))
            #expect(await fixture.provider.calls.count == 2)
        }
    }
}
