import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree listing with URL branch remotes")
struct WorktreeListingURLRemoteIntegrationTests {
    @Test("a URL-valued branch remote does not hide any worktree rows")
    func listsBranchesWhenRemoteIsURL() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-url-remote")
        let worktreePath = repository.deletingLastPathComponent()
            .appending(path: "\(repository.lastPathComponent).feature-url-remote", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: worktreePath)
            FilesystemTestGitRepo.destroy(repository)
        }

        try "initial\n".write(to: repository.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["commit", "-m", "Initial"])
        let client = LibGit2AgentStudioGitLocalClient()
        _ = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: repository,
                destinationPath: worktreePath,
                mode: .newBranch(name: "feature/url-remote", startPoint: .named("refs/heads/main"))
            ))
        try await FilesystemTestGitRepo.runGit(
            at: repository,
            args: ["config", "branch.feature/url-remote.remote", "https://github.com/example/project.git"]
        )

        let outcome = await WorktreeOperationRunner(client: client).run(
            .list(start: repository, callerDirectory: nil, targets: [], fetchPolicy: .fetch)
        )

        guard case .listed(let listing) = outcome else {
            Issue.record("expected URL-remote branch not to fail the list, got \(outcome)")
            return
        }
        #expect(listing.fetch == .skipped(reason: .noRemote))
        #expect(listing.worktrees.map(\.branch).compactMap { $0 }.sorted() == ["feature/url-remote", "main"])
    }
}
