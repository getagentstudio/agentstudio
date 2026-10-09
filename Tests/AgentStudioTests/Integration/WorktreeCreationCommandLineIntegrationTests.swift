import AgentStudioGit
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Darwin
import Foundation
import Testing

@Suite("Worktree creation command line integration")
struct WorktreeCreationCommandLineIntegrationTests {
    private typealias CreatedDocument = WorktreeCreationCommandLineDocuments.CreatedDocument
    private typealias RefusedDocument = WorktreeCreationCommandLineDocuments.RefusedDocument

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
                "new", branch, "--tracked-only", "--from-branch", startBranch, "--repo", repository.path, "--json",
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
        #expect(document.materialization?.kind == "trackedOnly")
        #expect(document.largeFiles == nil)
        #expect(try await git(at: destination, "rev-parse", "--abbrev-ref", "HEAD") == branch)
        #expect(try await git(at: destination, "rev-parse", "HEAD") == expectedTip)
        #expect(try await git(at: repository, "rev-parse", "refs/heads/\(startBranch)") == expectedTip)
    }

    @Test("new --from-branch without another flag creates its new branch at that local branch tip")
    func createsFromBranchWithoutTrackedOnly() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-from-branch-alone")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try "base\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git(at: repository, "add", "README.md")
        try await git(at: repository, "commit", "-m", "base")
        try await git(at: repository, "checkout", "-b", "release")
        try "release\n".write(to: repository.appending(path: "release.txt"), atomically: true, encoding: .utf8)
        try await git(at: repository, "add", "release.txt")
        try await git(at: repository, "commit", "-m", "release")
        let releaseTip = try await git(at: repository, "rev-parse", "refs/heads/release")
        try await git(at: repository, "checkout", "main")
        #expect(try await git(at: repository, "rev-parse", "HEAD") != releaseTip)
        let destination = try siblingDestination(repository: repository, branch: "feat")
        defer { try? FileManager.default.removeItem(at: destination) }

        let probe = WorktreeCreationCommandLineProbe()
        let exitCode = await WorktreeCommandLine.run(
            arguments: ["new", "feat", "--from-branch", "release", "--repo", repository.path, "--json"],
            currentDirectory: repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) }
        )

        let output = try #require(probe.outputSnapshot().first)
        #expect(exitCode == 0, "new --from-branch did not create: \(output)")
        #expect(probe.errorSnapshot().isEmpty)
        let document = try JSONDecoder().decode(CreatedDocument.self, from: Data(output.utf8))
        #expect(document.outcome == "created")
        #expect(document.branch == "feat")
        #expect(document.path == destination.path)
        #expect(document.materialization?.kind == "trackedOnly")
        #expect(try await git(at: repository, "rev-parse", "refs/heads/feat") == releaseTip)
        #expect(try await git(at: destination, "rev-parse", "HEAD") == releaseTip)
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
                "new", branch, "--tracked-only", "--repo", repository.path, "--from-branch", "feature/missing",
                "--json",
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
            arguments: ["new", branch, "--changes-only", "--from", repository.path, "--json"],
            currentDirectory: repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) }
        )

        #expect(exitCode == 0)
        #expect(probe.errorSnapshot().isEmpty)
        let output = try #require(probe.outputSnapshot().first)
        #expect(!output.contains("\"largeFiles\""))
        let document = try JSONDecoder().decode(CreatedDocument.self, from: Data(output.utf8))
        #expect(document.outcome == "created")
        #expect(document.operation == "new")
        #expect(document.branch == branch)
        #expect(document.path == destination.path)
        guard let report = document.materialization, report.kind == "changesOnly" else {
            Issue.record("expected the CLI to report changesOnly materialization")
            return
        }
        #expect(report.trackedChanges == 1)
        #expect(report.untrackedFiles == 1)
        #expect(report.ignoredExcluded == true)
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
            arguments: ["new", branch, "--from", repository.path, "--changes-only", "--json"],
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
        let expectedOptions = [
            WorktreeStopOption(
                action: .command("commit the changed .gitattributes first"),
                effect: "Commit the changed attributes, then retry --changes-only."
            ),
            WorktreeStopOption(
                action: .command("stash the changed .gitattributes first"),
                effect: "Stash the changed attributes, then retry --changes-only."
            ),
            WorktreeStopOption(
                action: .command("agentstudio worktree new <branch> --from <source>"),
                effect: "Use the APFS copy-on-write fork without --changes-only."
            ),
        ]
        #expect(document.options == expectedOptions)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await git(at: repository, "branch", "--list", branch).isEmpty)

        let humanProbe = WorktreeCreationCommandLineProbe()
        let humanExitCode = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--from", repository.path, "--changes-only"],
            currentDirectory: repository,
            output: { humanProbe.appendOutput($0) },
            errorOutput: { humanProbe.appendError($0) }
        )
        #expect(humanExitCode == 1)
        #expect(humanProbe.errorSnapshot().isEmpty)
        let humanOutput = try #require(humanProbe.outputSnapshot().first)
        #expect(humanOutput.contains("commit the changed .gitattributes first"))
        #expect(humanOutput.contains("stash the changed .gitattributes first"))
        #expect(humanOutput.contains("agentstudio worktree new <branch> --from <source>"))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await git(at: repository, "branch", "--list", branch).isEmpty)
    }

    @discardableResult
    private func git(at repository: URL, _ arguments: String...) async throws -> String {
        try await worktreeCreationGit(at: repository, arguments: arguments)
    }
}
