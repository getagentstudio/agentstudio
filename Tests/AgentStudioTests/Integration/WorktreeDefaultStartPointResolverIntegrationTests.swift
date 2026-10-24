import AgentStudioInfrastructure
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@Suite("Worktree default start point resolver with real Git")
struct WorktreeDefaultStartPointResolverIntegrationTests {
    @Test("origin HEAD, local main, local master, and no branch resolve in priority order")
    func resolvesAvailableDefaultReferences() async throws {
        let resolver = SDKWorktreeDefaultStartPointResolver()

        let originRepository = try await FilesystemTestGitRepo.create(named: "default-origin")
        defer { FilesystemTestGitRepo.destroy(originRepository) }
        try await commitInitialFile(in: originRepository)
        let originPath = originRepository.deletingLastPathComponent()
            .appending(path: "origin-\(UUIDv7.generate().uuidString).git")
        defer { try? FileManager.default.removeItem(at: originPath) }
        try await FilesystemTestGitRepo.createBareRemote(at: originPath)
        try await FilesystemTestGitRepo.runGit(
            at: originRepository, args: ["remote", "add", "origin", originPath.path])
        try await FilesystemTestGitRepo.runGit(
            at: originRepository, args: ["push", "--set-upstream", "origin", "main"])
        try await FilesystemTestGitRepo.runGit(at: originRepository, args: ["remote", "set-head", "origin", "main"])
        #expect(
            try await resolver.resolveDefaultStartPoint(repositoryPath: originRepository)
                == .resolved(displayRef: "origin/main", startPoint: "refs/remotes/origin/main"))

        let mainRepository = try await FilesystemTestGitRepo.create(named: "default-main")
        defer { FilesystemTestGitRepo.destroy(mainRepository) }
        try await commitInitialFile(in: mainRepository)
        #expect(
            try await resolver.resolveDefaultStartPoint(repositoryPath: mainRepository)
                == .resolved(displayRef: "main", startPoint: "refs/heads/main"))

        let legacyDefaultBranchRepository = try await FilesystemTestGitRepo.create(named: "default-master")
        defer { FilesystemTestGitRepo.destroy(legacyDefaultBranchRepository) }
        try await FilesystemTestGitRepo.runGit(
            at: legacyDefaultBranchRepository, args: ["symbolic-ref", "HEAD", "refs/heads/master"])
        try await commitInitialFile(in: legacyDefaultBranchRepository)
        #expect(
            try await resolver.resolveDefaultStartPoint(repositoryPath: legacyDefaultBranchRepository)
                == .resolved(displayRef: "master", startPoint: "refs/heads/master"))

        let emptyRepository = try await FilesystemTestGitRepo.create(named: "default-empty")
        defer { FilesystemTestGitRepo.destroy(emptyRepository) }
        #expect(try await resolver.resolveDefaultStartPoint(repositoryPath: emptyRepository) == .noDefaultBranch)
    }

    private func commitInitialFile(in repository: URL) async throws {
        try "initial\n".write(
            to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["add", "README.md"])
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["commit", "-m", "Initial commit"])
    }
}
