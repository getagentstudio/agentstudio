import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree remove command line with real Git")
struct WorktreeRemovalCommandLineIntegrationTests {
    @Test("remove dispatches to the standalone worktree path without invoking IPC")
    func removesWorktreeThroughCommandDispatch() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-command-line")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/dispatch")

        let exitCode = await WorktreeCommandLine.dispatch(
            arguments: [
                "worktree", "remove", "--repo", fixture.path.path, worktree.path,
                "--no-fetch", "--json",
            ],
            currentDirectory: fixture.path,
            output: { _ in },
            errorOutput: { _ in },
            runIPCCommand: { 99 }
        )

        #expect(exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(
            try await removalGit(fixture.path, "for-each-ref", "--format=%(refname)", "refs/heads/feature/dispatch")
                .isEmpty)
    }
}
