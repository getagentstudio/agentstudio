import AgentStudioGit
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree creation command line integration")
struct WorktreeCreationCommandLineIntegrationTests {
    private struct CreatedDocument: Decodable {
        let outcome: String
        let operation: String
        let branch: String
        let path: String
        let repository: String
        let materialization: GitWorktreeMaterializationResult?
    }

    private struct RefusedDocument: Decodable {
        let outcome: String
        let reason: String
        let path: String?
        let detail: String?
        let alternative: String?
    }

    @Test("new from branch creates its new branch at the named local branch tip")
    func createsNewBranchFromNamedLocalBranchTip() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-from-branch")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try "base\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git(at: repository, "add", "README.md")
        try await git(at: repository, "commit", "-m", "base")
        let startBranch = "feature/start-point"
        try await git(at: repository, "checkout", "-b", startBranch)
        try "start point\n".write(
            to: repository.appending(path: "start-point.txt"), atomically: true, encoding: .utf8)
        try await git(at: repository, "add", "start-point.txt")
        try await git(at: repository, "commit", "-m", "start point")
        let expectedTip = try await git(at: repository, "rev-parse", "HEAD")
        try await git(at: repository, "checkout", "main")

        let branch = "feature/from-start-point"
        let branchName = try WorktreeBranchName.validated(branch).get()
        guard
            let destination = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repository,
                branchName: branchName
            )
        else {
            Issue.record("expected a sibling destination for the validated branch")
            return
        }
        defer { try? FileManager.default.removeItem(at: destination) }

        let probe = WorktreeCreationCommandLineProbe()
        let exitCode = await WorktreeCommandLine.run(
            arguments: [
                "new", branch, "--from-branch", startBranch, "--repo", repository.path, "--json",
            ],
            currentDirectory: repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) }
        )

        #expect(exitCode == 0)
        #expect(probe.errorSnapshot().isEmpty)
        let output = try #require(probe.outputSnapshot().first)
        let document = try JSONDecoder().decode(CreatedDocument.self, from: Data(output.utf8))
        #expect(document.outcome == "created")
        #expect(document.operation == "new")
        #expect(document.branch == branch)
        #expect(document.path == destination.path)
        #expect(document.repository == repository.path)
        #expect(document.materialization == nil)
        #expect(try await git(at: destination, "rev-parse", "--abbrev-ref", "HEAD") == branch)
        #expect(try await git(at: destination, "rev-parse", "HEAD") == expectedTip)
        #expect(try await git(at: repository, "rev-parse", "refs/heads/\(startBranch)") == expectedTip)
    }

    @Test("new from a missing local branch refuses with startBranchNotFound")
    func refusesMissingStartBranch() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-missing-start-branch")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try "base\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git(at: repository, "add", "README.md")
        try await git(at: repository, "commit", "-m", "base")

        let branch = "feature/should-not-exist"
        let branchName = try WorktreeBranchName.validated(branch).get()
        guard
            let destination = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repository,
                branchName: branchName
            )
        else {
            Issue.record("expected a sibling destination for the validated branch")
            return
        }

        let probe = WorktreeCreationCommandLineProbe()
        let exitCode = await WorktreeCommandLine.run(
            arguments: [
                "new", branch, "--repo", repository.path, "--from-branch", "feature/missing", "--json",
            ],
            currentDirectory: repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) }
        )

        #expect(exitCode == 1)
        let output = try #require(probe.outputSnapshot().first)
        let document = try JSONDecoder().decode(RefusedDocument.self, from: Data(output.utf8))
        #expect(document.outcome == "refused")
        #expect(document.reason == "startBranchNotFound")
        #expect(document.detail == "feature/missing")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await git(at: repository, "branch", "--list", branch).isEmpty)
    }

    @Test("changes-only fork overlays carried files and reports its materialization")
    func forksWithChangesOnlyMaterialization() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-changes-only")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let trackedPath = repository.appending(path: "tracked.txt")
        try "initial\n".write(to: trackedPath, atomically: true, encoding: .utf8)
        try await git(at: repository, "add", "tracked.txt")
        try await git(at: repository, "commit", "-m", "base")
        let expectedHead = try await git(at: repository, "rev-parse", "HEAD")
        try "initial\nworking change\n".write(to: trackedPath, atomically: true, encoding: .utf8)
        try "untracked\n".write(
            to: repository.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)

        let branch = "feature/changes-only"
        let branchName = try WorktreeBranchName.validated(branch).get()
        guard
            let destination = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repository,
                branchName: branchName
            )
        else {
            Issue.record("expected a sibling destination for the validated branch")
            return
        }
        defer { try? FileManager.default.removeItem(at: destination) }

        let probe = WorktreeCreationCommandLineProbe()
        let exitCode = await WorktreeCommandLine.run(
            arguments: ["fork", branch, "--changes-only", "--from", repository.path, "--json"],
            currentDirectory: repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) }
        )

        #expect(exitCode == 0)
        #expect(probe.errorSnapshot().isEmpty)
        let output = try #require(probe.outputSnapshot().first)
        let document = try JSONDecoder().decode(CreatedDocument.self, from: Data(output.utf8))
        #expect(document.outcome == "created")
        #expect(document.operation == "fork")
        #expect(document.branch == branch)
        #expect(document.path == destination.path)
        guard case .changesOnly(let report) = document.materialization else {
            Issue.record("expected the CLI to report changesOnly materialization")
            return
        }
        #expect(report.trackedChanges == 1)
        #expect(report.untrackedFiles == 1)
        #expect(report.ignoredExcluded)
        #expect(try await git(at: destination, "rev-parse", "HEAD") == expectedHead)
        #expect(
            try String(contentsOf: destination.appending(path: "tracked.txt"), encoding: .utf8)
                == "initial\nworking change\n")
        #expect(
            try String(contentsOf: destination.appending(path: "untracked.txt"), encoding: .utf8) == "untracked\n")
        let destinationStatus = try await FilesystemTestGitRepo.runGit(
            at: destination,
            args: ["status", "--porcelain=v1"]
        )
        #expect(
            destinationStatus.split(separator: "\n").map(String.init).sorted()
                == [" M tracked.txt", "?? untracked.txt"])
        #expect(
            try String(contentsOf: trackedPath, encoding: .utf8) == "initial\nworking change\n")
    }

    @Test("changes-only refusal preserves its reason and relative source path")
    func refusesChangedGitAttributesWithPath() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-changes-only-attributes")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try "*.txt text\n".write(
            to: repository.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
        try "tracked\n".write(
            to: repository.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try await git(at: repository, "add", ".gitattributes", "tracked.txt")
        try await git(at: repository, "commit", "-m", "attributes")
        try "*.txt -text\n".write(
            to: repository.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)

        let branch = "feature/unsupported-state"
        let branchName = try WorktreeBranchName.validated(branch).get()
        guard
            let destination = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repository,
                branchName: branchName
            )
        else {
            Issue.record("expected a sibling destination for the validated branch")
            return
        }

        let probe = WorktreeCreationCommandLineProbe()
        let exitCode = await WorktreeCommandLine.run(
            arguments: ["fork", branch, "--from", repository.path, "--changes-only", "--json"],
            currentDirectory: repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) }
        )

        #expect(exitCode == 1)
        let output = try #require(probe.outputSnapshot().first)
        let document = try JSONDecoder().decode(RefusedDocument.self, from: Data(output.utf8))
        #expect(document.outcome == "refused")
        #expect(document.reason == "unsupportedWorkingState")
        #expect(document.path == ".gitattributes")
        #expect(document.detail == "attributesChanged")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await git(at: repository, "branch", "--list", branch).isEmpty)
    }

    @discardableResult
    private func git(at repository: URL, _ arguments: String...) async throws -> String {
        try await FilesystemTestGitRepo.runGit(at: repository, args: arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class WorktreeCreationCommandLineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String] = []
    private var errors: [String] = []

    func appendOutput(_ output: String) {
        lock.lock()
        outputs.append(output)
        lock.unlock()
    }

    func appendError(_ error: String) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func outputSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return outputs
    }

    func errorSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}
