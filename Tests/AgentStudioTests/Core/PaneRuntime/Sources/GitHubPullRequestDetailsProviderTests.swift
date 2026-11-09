import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

private actor PullRequestDetailsProcessFixture: ProcessExecutor {
    struct Call: Equatable, Sendable {
        let command: String
        let arguments: [String]
    }
    private let responses: [ProcessResult]
    private(set) var calls: [Call] = []
    init(_ responses: [ProcessResult]) { self.responses = responses }
    func execute(command: String, args: [String], cwd: URL?, environment: [String: String]?) async throws
        -> ProcessResult
    {
        let index = calls.count
        calls.append(.init(command: command, arguments: args))
        guard responses.indices.contains(index) else { throw MissingResponse.queuedResponseRequired }
        return responses[index]
    }
    private enum MissingResponse: Error { case queuedResponseRequired }
}

@Suite("GitHub details by PR identity")
struct GitHubPullRequestDetailsProviderTests {
    private func identity(_ number: Int) throws -> ForgePullRequestIdentity {
        try .init(host: "github.com", owner: "owner", repository: "repo", number: number)
    }

    private func expectedDate() throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return try #require(calendar.date(from: .init(year: 2026, month: 11, day: 9, hour: 0, minute: 0, second: 0)))
    }

    @Test("The identity query uses typed alias variables and maps title, draft, checks, review and blockers")
    func mapsDetailsByNumber() async throws {
        let process = PullRequestDetailsProcessFixture([
            .init(
                exitCode: 0,
                stdout: """
                    {"data":{"pr0":{"pullRequest":{"title":"Draft change","state":"OPEN","isDraft":true,
                    "reviewDecision":"CHANGES_REQUESTED","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY",
                    "statusCheckRollup":{"state":"FAILURE"},"updatedAt":"2026-11-09T00:00:00Z",
                    "url":"https://github.com/owner/repo/pull/7"}}}}
                    """, stderr: "")
        ])
        let provider = GitHubCLIForgeStatusProvider(processExecutor: process)
        let key = try identity(7)
        let result = await provider.pullRequestDetails(identities: [key])
        let expected = ForgePullRequestDetails(
            title: "Draft change", state: .draft,
            readiness: .init(
                isDraft: true, checkStatus: .failed, reviewStatus: .changesRequested, mergeability: .conflicting,
                mergeState: .dirty),
            updatedAt: try expectedDate(), url: try #require(URL(string: "https://github.com/owner/repo/pull/7")))
        #expect(result == [key: .loaded(expected)])
        let calls = await process.calls
        try #require(calls.count == 1)
        #expect(calls[0].command == "gh")
        #expect(calls[0].arguments.prefix(2) == ["api", "graphql"])
        #expect(calls[0].arguments.contains("owner0=owner"))
        #expect(calls[0].arguments.contains("repository0=repo"))
        #expect(calls[0].arguments.contains("number0=7"))
        let query = try #require(calls[0].arguments.first(where: { $0.hasPrefix("query=") }))
        #expect(query.contains("pr0: repository"))
        #expect(query.contains("pullRequest(number: $number0)"))
        #expect(!query.contains("headRefName"))
    }

    @Test("A partial GraphQL error with nonzero gh exit preserves the other PR's details")
    func partialFailureKeepsOtherRows() async throws {
        let process = PullRequestDetailsProcessFixture([
            .init(
                exitCode: 1,
                stdout: """
                    {"data":{"pr0":{"pullRequest":null},"pr1":{"pullRequest":{"title":"Merged change","state":"MERGED","isDraft":false,
                    "reviewDecision":"APPROVED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":null,
                    "updatedAt":"2026-11-09T00:00:00Z","url":"https://github.com/owner/repo/pull/8"}}},
                    "errors":[{"type":"NOT_FOUND","path":["pr0","pullRequest"],"message":"Not found"}]}
                    """, stderr: "gh: Could not resolve to a PullRequest")
        ])
        let first = try identity(7)
        let second = try identity(8)
        let provider = GitHubCLIForgeStatusProvider(processExecutor: process)
        let result = await provider.pullRequestDetails(identities: [first, second])
        let expected = ForgePullRequestDetails(
            title: "Merged change", state: .merged,
            readiness: .init(
                isDraft: false, checkStatus: .unknown, reviewStatus: .approved, mergeability: .mergeable,
                mergeState: .clean),
            updatedAt: try expectedDate(), url: try #require(URL(string: "https://github.com/owner/repo/pull/8")))
        #expect(result == [first: .failed(.notFound), second: .loaded(expected)])
    }

    @Test(arguments: [
        ("HTTP 401: Bad credentials", ForgePullRequestDetailsFailure.noAccess),
        ("To get started with GitHub CLI, please run:  gh auth login", .noAccess),
        ("HTTP 403: secondary rate limit. retry-after: 75", .rateLimited(retryAfterSeconds: 75)),
        ("Could not resolve to a PullRequest", .notFound),
        ("error connecting to api.github.com", .offline),
        ("Unexpected provider failure", .failed),
    ])
    func failuresHaveClosedReasons(stderr: String, expected: ForgePullRequestDetailsFailure) async throws {
        let process = PullRequestDetailsProcessFixture([.init(exitCode: 1, stdout: "", stderr: stderr)])
        let provider = GitHubCLIForgeStatusProvider(processExecutor: process)
        let key = try identity(7)
        #expect(await provider.pullRequestDetails(identities: [key]) == [key: .failed(expected)])
    }

    @Test("No identities launches no process")
    func emptyInputMakesNoCall() async {
        let process = PullRequestDetailsProcessFixture([])
        let provider = GitHubCLIForgeStatusProvider(processExecutor: process)
        #expect(await provider.pullRequestDetails(identities: []).isEmpty)
        #expect(await process.calls.isEmpty)
    }

    @Test("Numeric and Boolean-looking owner/repository variables remain strings at the gh boundary")
    func repositoryVariablesRemainStrings() async throws {
        let process = PullRequestDetailsProcessFixture([
            .init(
                exitCode: 0,
                stdout: """
                    {"data":{"pr0":{"pullRequest":null}}}
                    """, stderr: "")
        ])
        let provider = GitHubCLIForgeStatusProvider(processExecutor: process)
        let key = try ForgePullRequestIdentity(host: "github.com", owner: "123", repository: "true", number: 7)
        _ = await provider.pullRequestDetails(identities: [key])
        let calls = await process.calls
        try #require(calls.count == 1)
        let rawFields = zip(calls[0].arguments, calls[0].arguments.dropFirst()).filter {
            ["-f", "--raw-field"].contains($0.0)
        }.map(\.1)
        #expect(rawFields.contains("owner0=123"))
        #expect(rawFields.contains("repository0=true"))
    }
}
