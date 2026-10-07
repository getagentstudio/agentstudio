import AgentStudioGit
import AgentStudioTestSupport
import Foundation

func seedMainBranch(in repository: URL) async throws {
    try "initial\n".write(to: repository.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
    _ = try await FilesystemTestGitRepo.runGit(at: repository, args: ["add", "tracked.txt"])
    _ = try await FilesystemTestGitRepo.runGit(at: repository, args: ["commit", "-m", "Initial"])
}

func createBranchWorktree(
    _ branch: String,
    at destination: URL,
    repository: URL,
    client: LibGit2AgentStudioGitLocalClient
) async throws -> GitWorktreeSnapshot {
    try await client.createWorktree(
        GitCreateWorktreeRequest(
            repositoryPath: repository,
            destinationPath: destination,
            mode: .newBranch(name: branch, startPoint: .named("refs/heads/main"))
        )
    ).worktree
}

func path(for branch: String, beside repository: URL) -> URL {
    let suffix = branch.replacingOccurrences(of: "/", with: "-")
    return repository.deletingLastPathComponent()
        .appending(path: "\(repository.lastPathComponent).\(suffix)", directoryHint: .isDirectory)
}
