import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane PR list composition")
struct PanePullRequestListTests {
    private func identity(_ number: Int) throws -> ForgePullRequestIdentity {
        try .init(host: "github.com", owner: "owner", repository: "repo", number: number)
    }

    @Test("Worktree first, added newest first, and mixed sources merge without losing removal")
    func orderingAndMixedSources() throws {
        // Arrange: numeric order deliberately differs from creation order.
        let worktree = try identity(7)
        let records: [PanePullRequestRecord] = try [(99, 1), (7, 2), (2, 3)].map { number, time in
            .init(
                identity: try identity(number), createdAt: Date(timeIntervalSince1970: Double(time)),
                contributions: [.init(author: .person, createdAt: Date(timeIntervalSince1970: Double(time)))])
        }
        // Act
        let list = PanePullRequestList.compose(records: records, worktree: worktree, entries: [:])
        // Assert: the independent R11/R12 order and source contract.
        #expect(list.rows.map(\.identity.number) == [7, 2, 99])
        #expect(list.rows.first?.isWorktree == true)
        #expect(list.rows.first?.authors == [.person])
        #expect(list.rows.first?.canRemove == true)
        let removed = PanePullRequestList.compose(records: [], worktree: worktree, entries: [:])
        #expect(removed.rows.map(\.identity.number) == [7])
        #expect(removed.rows.first?.canRemove == false)
    }

    @Test(
        "Summary chooses failed then running then passed",
        arguments: [
            [PullRequestCheckStatus.failed, .running, .passed], [.running, .passed], [.passed], [.unknown],
        ])
    func summary(checks: [PullRequestCheckStatus]) throws {
        let url: URL = try #require(URL(string: "https://github.com/owner/repo/pull/1"))
        let entries = try Dictionary(
            uniqueKeysWithValues: checks.enumerated().map { index, check in
                let read = ForgePullRequestLastGoodRead(
                    details: .init(
                        title: "Title", state: .open,
                        readiness: .init(
                            isDraft: false, checkStatus: check, reviewStatus: .unknown,
                            mergeability: .unknown, mergeState: .unknown),
                        updatedAt: .distantPast, url: url),
                    readAt: .distantPast)
                return (try identity(index + 1), ForgePullRequestDetailsEntry.fresh(read))
            })
        let records = entries.keys.map {
            PanePullRequestRecord(
                identity: $0, createdAt: .distantPast,
                contributions: [.init(author: .person, createdAt: .distantPast)])
        }
        let list = PanePullRequestList.compose(records: records, worktree: nil, entries: entries)
        #expect(list.count == checks.count)
        #expect(list.worstChecks == (checks.first == .unknown ? nil : checks.first))
    }
}
