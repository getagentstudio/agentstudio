import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane PR composition through real service readers")
struct PanePullRequestCompositionServiceTests {
    @Test("Hidden pane worktree and explicit sources share list, display and detail; person removal retains worktree")
    func hiddenPaneReaderParityAndRemoval() async throws {
        try await withPaneContextService { fixture, service in
            // Arrange: a hidden, associated main pane and the same explicit PR.
            let identity = try ForgePullRequestIdentity(
                host: "github.com", owner: "owner", repository: "repo", number: 7)
            let worktree = UUIDv7.generate()
            let repo = UUIDv7.generate()
            var snapshot = PanePullRequestContextSnapshot()
            snapshot.paneFactsByPaneId[fixture.paneId.uuid] = facts(
                paneId: fixture.paneId, repo: repo, worktree: worktree)
            snapshot.enrichmentBranchByWorktreeId[worktree] = .init(repoId: repo, branch: "feature")
            let key = try #require(RepoBranchKey(repoId: repo, branch: "feature"))
            snapshot.pullRequestURLByBranchKey[key] = URL(string: "https://github.com/owner/repo/pull/7")
            await service.setPullRequestContext(snapshot)
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: identity, author: .person)

            // Act / Assert: all consumers receive the same one mixed row, despite hidden visibility.
            let rows = try await service.listPullRequests(paneId: fixture.paneId)
            #expect(rows.count == 1 && rows.first?.isWorktree == true)
            #expect(rows.first?.authors == [.person])
            let display = try #require(await service.readDisplay(paneId: fixture.paneId))
            guard case .detail(let detail) = await service.readDetail(.init(paneId: fixture.paneId, page: .first))
            else {
                Issue.record("Expected pane detail")
                return
            }
            #expect(display.pullRequests.rows == rows)
            #expect(detail.pullRequests == display.pullRequests)
            _ = try await service.removePullRequestForPerson(paneId: fixture.paneId, identity: identity)
            let worktreeOnly = try await service.listPullRequests(paneId: fixture.paneId)
            #expect(worktreeOnly.count == 1 && worktreeOnly.first?.canRemove == false)
            #expect(worktreeOnly.first?.isWorktree == true)

            // Removing the PR fact in a whole snapshot removes the derived source.
            snapshot.pullRequestURLByBranchKey = [:]
            await service.setPullRequestContext(snapshot)
            #expect(try await service.listPullRequests(paneId: fixture.paneId).isEmpty)
            #expect(await service.readDisplay(paneId: fixture.paneId)?.pullRequests.isEmpty == true)
        }
    }

    @Test("No-worktree added rows remain; empty branch and removed enrichment cannot invent a worktree row")
    func noAssociationAndSnapshotRemoval() async throws {
        try await withPaneContextService { fixture, service in
            let identity = try ForgePullRequestIdentity(
                host: "github.com", owner: "owner", repository: "repo", number: 9)
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: identity, author: .person)
            var snapshot = PanePullRequestContextSnapshot()
            snapshot.paneFactsByPaneId[fixture.paneId.uuid] = facts(paneId: fixture.paneId, repo: nil, worktree: nil)
            await service.setPullRequestContext(snapshot)
            let added = try await service.listPullRequests(paneId: fixture.paneId)
            #expect(added.map(\.identity) == [identity])
            #expect(added.first?.isWorktree == false)
            let worktree = UUIDv7.generate()
            let repo = UUIDv7.generate()
            snapshot.paneFactsByPaneId[fixture.paneId.uuid] = facts(
                paneId: fixture.paneId, repo: repo, worktree: worktree)
            snapshot.enrichmentBranchByWorktreeId[worktree] = .init(repoId: repo, branch: "")
            await service.setPullRequestContext(snapshot)
            #expect(try await service.listPullRequests(paneId: fixture.paneId) == added)
            snapshot.enrichmentBranchByWorktreeId = [:]
            await service.setPullRequestContext(snapshot)
            #expect(try await service.listPullRequests(paneId: fixture.paneId) == added)
        }
    }

    private func facts(paneId: PaneId, repo: UUID?, worktree: UUID?) -> PaneStructuralFacts {
        let pane = Pane(
            id: paneId.uuid,
            content: .terminal(.init(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: .init(title: "Fixture", facets: .init(repoId: repo, worktreeId: worktree)))
        return .init(state: .init(pane: pane))
    }
}
