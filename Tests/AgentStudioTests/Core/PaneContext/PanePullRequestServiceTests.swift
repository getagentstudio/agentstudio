import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane pull requests: real SQLite service")
struct PanePullRequestServiceTests {
    private func identity(_ number: Int) throws -> ForgePullRequestIdentity {
        try ForgePullRequestIdentity(host: "github.com", owner: "owner", repository: "repo", number: number)
    }

    @Test("Twenty distinct PRs cap rows, not contributions; repeated authors are idempotent")
    func capAndIdempotency() async throws {
        try await withPaneContextService { fixture, service in
            // Arrange / Act
            for number in 1...20 {
                #expect(
                    try await service.addPullRequest(
                        paneId: fixture.paneId, identity: identity(number), author: .person)
                        == .added)
            }
            #expect(
                try await service.addPullRequest(paneId: fixture.paneId, identity: identity(21), author: .person)
                    == .paneFull)
            let client = PanePullRequestAuthor.client(credentialKey: "credential-a")
            #expect(
                try await service.addPullRequest(paneId: fixture.paneId, identity: identity(1), author: client)
                    == .added)
            #expect(
                try await service.addPullRequest(paneId: fixture.paneId, identity: identity(1), author: client)
                    == .alreadyPresent)

            // Assert: row count and full authors read from real storage.
            let rows = try await service.listPullRequests(paneId: fixture.paneId)
            #expect(rows.count == 20)
            let authors = rows.first(where: { $0.identity.number == 1 })?.contributions.map(\.author) ?? []
            #expect(Set(authors) == Set([.person, client]))
        }
    }

    @Test("Remove withdraws only the caller; the last author deletes the PR; person removes every author")
    func contributionRemoval() async throws {
        try await withPaneContextService { fixture, service in
            // Arrange
            let pullRequest = try identity(7)
            let first = PanePullRequestAuthor.client(credentialKey: "first")
            let second = PanePullRequestAuthor.client(credentialKey: "second")
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: pullRequest, author: first)

            // Act / Assert
            #expect(
                try await service.removePullRequest(paneId: fixture.paneId, identity: pullRequest, author: second)
                    == .addedBySomeoneElse)
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: pullRequest, author: second)
            #expect(
                try await service.removePullRequest(paneId: fixture.paneId, identity: pullRequest, author: first)
                    == .removed)
            #expect(
                try await service.listPullRequests(paneId: fixture.paneId).first?.contributions.map(\.author) == [
                    second
                ])
            #expect(
                try await service.removePullRequest(paneId: fixture.paneId, identity: pullRequest, author: second)
                    == .removed)
            #expect(try await service.listPullRequests(paneId: fixture.paneId).isEmpty)
            #expect(
                try await service.removePullRequest(paneId: fixture.paneId, identity: pullRequest, author: first)
                    == .notOnPane)
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: pullRequest, author: first)
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: pullRequest, author: second)
            #expect(
                try await service.removePullRequestForPerson(paneId: fixture.paneId, identity: pullRequest) == .removed)
            #expect(try await service.listPullRequests(paneId: fixture.paneId).isEmpty)
        }
    }

    @Test("Temporary pane absence hides records and Undo restores them without altering authors")
    func membershipUndo() async throws {
        try await withPaneContextService { fixture, service in
            _ = try await service.addPullRequest(paneId: fixture.paneId, identity: identity(7), author: .person)
            let before = try await service.listPullRequests(paneId: fixture.paneId)
            fixture.membership.removePane(fixture.paneId)
            await #expect(throws: PanePullRequestServiceError.paneGone) {
                _ = try await service.listPullRequests(paneId: fixture.paneId)
            }
            fixture.membership.addPane(fixture.paneId)
            #expect(try await service.listPullRequests(paneId: fixture.paneId) == before)
        }
    }
}
