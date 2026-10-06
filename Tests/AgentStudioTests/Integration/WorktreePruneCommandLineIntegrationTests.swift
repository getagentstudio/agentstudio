import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree prune command line with real Git")
struct WorktreePruneCommandLineIntegrationTests {
    @Test("preview preserves lifecycle state and apply removes only an integrated linked worktree")
    func previewAndApplyUseTheStandaloneWorktreeCommand() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-prune-dispatch")
        defer { fixture.destroy() }
        let integratedWorktree = try await fixture.addWorktree(branch: "feature/prune-integrated")
        let stateBeforePreview = try await removalRepositorySnapshot(fixture.path)

        let previewExit = await WorktreeCommandLine.dispatch(
            arguments: ["worktree", "prune", "--repo", fixture.path.path, "--no-fetch", "--json"],
            currentDirectory: fixture.path,
            output: { _ in },
            errorOutput: { _ in },
            runIPCCommand: { 97 }
        )

        #expect(previewExit == 0)
        let stateAfterPreview = try await removalRepositorySnapshot(fixture.path)
        #expect(stateAfterPreview.worktrees == stateBeforePreview.worktrees)
        #expect(stateAfterPreview.branches == stateBeforePreview.branches)
        #expect(FileManager.default.fileExists(atPath: integratedWorktree.path))

        let applyExit = await WorktreeCommandLine.dispatch(
            arguments: ["worktree", "prune", "--repo", fixture.path.path, "--no-fetch", "--apply", "--json"],
            currentDirectory: fixture.path,
            output: { _ in },
            errorOutput: { _ in },
            runIPCCommand: { 97 }
        )

        #expect(applyExit == 0)
        #expect(!FileManager.default.fileExists(atPath: integratedWorktree.path))
        let retainedBranch = try await removalGit(
            fixture.path,
            "for-each-ref",
            "--format=%(refname)",
            "refs/heads/feature/prune-integrated"
        )
        #expect(retainedBranch.isEmpty)
    }
}
