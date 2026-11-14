import AgentStudioProgrammaticControl
import Testing

@Suite
struct GitHubPullRequestReferenceTests {
    @Test(arguments: ["o/r#2147483647", "https://github.com/o/r/pull/2147483647"])
    func acceptsGraphQLMaximum(input: String) throws {
        #expect(try GitHubPullRequestReference.parse(input).number == Int(Int32.max))
    }

    @Test(arguments: [
        "O/R#7",
        "https://github.com/O/R/pull/7",
        "https://github.com/o/r/pull/7/files",
        "https://GITHUB.COM/O/R/pull/7/commits?diff=split#discussion",
        "https://github.com/o/r/pull/7?tab=checks#details",
    ])
    func canonicalIdentity(input: String) throws {
        // Arrange: Specification R2 forms and E1's case-insensitive identity.
        let expected = IPCPanePullRequestIdentity(host: "github.com", owner: "o", repository: "r", number: 7)

        // Act
        let parsed = try GitHubPullRequestReference.parse(input)

        // Assert
        #expect(parsed == expected)
    }

    @Test(arguments: [
        "https://gitlab.com/o/r/pull/7", "https://github.example/o/r/pull/7",
        "https://github.com/o/r/issues/7", "https://github.com/o/r/commit/abc",
        "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/-7",
        "https://github.com/o/r/pull/seven", "https://github.com/o/r/pull/7x",
        "https://github.com/o/r/pull/999999999999999999999999999999",
        "https://github.com/o/r/pull/2147483648", "o/r#2147483648",
        "o/r#0", "o/r#-7", "o/r#7x", "o/r#", "/r#7", "o/#7", "o/r/extra#7",
        "", "not a PR", "o/r#7#8",
    ])
    func refusesNonPullRequests(input: String) {
        // Act
        var refusal: GitHubPullRequestReference.Refusal?
        do { _ = try GitHubPullRequestReference.parse(input) } catch { refusal = error }

        // Assert: the original input survives in the CLI's contractual refusal.
        #expect(refusal == .notPullRequest(input))
        #expect(refusal?.line == "not a GitHub pull request: \(input)")
    }
}
