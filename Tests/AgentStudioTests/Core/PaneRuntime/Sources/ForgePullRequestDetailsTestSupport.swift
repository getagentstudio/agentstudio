import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

actor TestPullRequestDetailsProvider: ForgePullRequestDetailsProviding {
    private let responses: [[ForgePullRequestIdentity: ForgePullRequestDetailsFetchResult]]
    private(set) var calls: [Set<ForgePullRequestIdentity>] = []

    init(responses: [[ForgePullRequestIdentity: ForgePullRequestDetailsFetchResult]]) { self.responses = responses }

    func pullRequestDetails(identities: Set<ForgePullRequestIdentity>) async -> [ForgePullRequestIdentity:
        ForgePullRequestDetailsFetchResult]
    {
        let index = calls.count
        calls.append(identities)
        guard responses.indices.contains(index) else {
            return Dictionary(uniqueKeysWithValues: identities.map { ($0, .failed(.failed)) })
        }
        return responses[index]
    }
}

struct ForgePullRequestDetailsFixture: Sendable {
    let actor: ForgePullRequestDetailsActor
    let provider: TestPullRequestDetailsProvider
    let clock: TestPushClock
    let time: PaneContextTestTime
    let facts: FactRecorder<ForgePullRequestIdentity, ForgePullRequestDetailsEntry>
    let observer: Task<Void, Never>

    init(responses: [[ForgePullRequestIdentity: ForgePullRequestDetailsFetchResult]]) {
        let clock = TestPushClock()
        self.clock = clock
        let time = PaneContextTestTime(clock: clock)
        self.time = time
        let provider = TestPullRequestDetailsProvider(responses: responses)
        self.provider = provider
        let actor = ForgePullRequestDetailsActor(provider: provider, clock: clock, wallNow: { time.now })
        self.actor = actor
        let facts = FactRecorder<ForgePullRequestIdentity, ForgePullRequestDetailsEntry>(
            vocabulary: .init(
                describeScope: { "\($0.owner)/\($0.repository)#\($0.number)" },
                describeFact: { String(describing: $0.health) }, isClosing: { _, _ in false }))
        self.facts = facts
        observer = Task {
            for await update in actor.updates { facts.append(scope: update.identity, fact: update.entry) }
            facts.receive(.ended)
        }
    }

    func close() async throws {
        await actor.shutdown()
        await observer.value
        try await facts.finish()
    }
}

func withForgePullRequestDetails(
    responses: [[ForgePullRequestIdentity: ForgePullRequestDetailsFetchResult]],
    operation: @Sendable (ForgePullRequestDetailsFixture) async throws -> Void
) async throws {
    let fixture = ForgePullRequestDetailsFixture(responses: responses)
    do {
        try await operation(fixture)
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}

func testPullRequestDetails(number: Int = 7, title: String = "A pull request") throws -> ForgePullRequestDetails {
    ForgePullRequestDetails(
        title: title, state: .open,
        readiness: .init(
            isDraft: false, checkStatus: .passed, reviewStatus: .approved, mergeability: .mergeable, mergeState: .clean),
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        url: try #require(URL(string: "https://github.com/owner/repo/pull/\(number)")))
}
