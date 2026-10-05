import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree new preflight")
struct WorktreeNewPreflightTests {
    @Test("new option combinations are refusals rather than usage errors")
    func refusesInvalidCreationCombinations() async throws {
        let combinations: [([String], String)] = [
            (["--from-branch", "main"], "fromBranchNeedsTrackedOnly"),
            (["--changes-only"], "changesOnlyNeedsFrom"),
            (["--tracked-only", "--from", "/tmp/source"], "trackedOnlyExcludesSource"),
            (["--tracked-only", "--changes-only"], "trackedOnlyExcludesSource"),
        ]
        for (options, reason) in combinations {
            for json in [false, true] {
                let probe = WorktreeCreationCommandLineProbe()
                let exit = await WorktreeCommandLine.run(
                    arguments: ["new", "feature/example"] + options + (json ? ["--json"] : []),
                    currentDirectory: URL(fileURLWithPath: "/tmp"),
                    output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) }
                )
                #expect(exit == 1)
                #expect(probe.errorSnapshot().isEmpty)
                let output = try #require(probe.outputSnapshot().first)
                #expect(output.contains(reason))
                #expect(output.contains("options"))
            }
        }
    }

    @Test("removed fork verb names new --from on stderr even with JSON")
    func rejectsRemovedForkVerb() async {
        for options in [[], ["--json"]] {
            let probe = WorktreeCreationCommandLineProbe()
            let exit = await WorktreeCommandLine.run(
                arguments: ["fork", "feature/example"] + options,
                currentDirectory: URL(fileURLWithPath: "/tmp"),
                output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) }
            )
            #expect(exit == 64)
            #expect(probe.outputSnapshot().isEmpty)
            #expect(probe.errorSnapshot().count == 1)
            #expect(probe.errorSnapshot().first?.contains("new --from") == true)
        }
    }

    @Test("default new refuses dirty main without creating branch or destination")
    func refusesDirtyDefaultSource() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "new-dirty-default")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)
        let branch = "feature/refused-dirty"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        let probe = WorktreeCreationCommandLineProbe()
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--repo", repository.path, "--json"],
            currentDirectory: repository,
            output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) }
        )
        #expect(exit == 1)
        #expect(probe.outputSnapshot().first?.contains("sourceDirty") == true)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await worktreeCreationGit(at: repository, arguments: ["branch", "--list", branch]).isEmpty)
    }

    @Test("default new refuses untracked-only dirt and reports its count and path")
    func refusesUntrackedOnlyDefaultSource() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "new-untracked-only-default")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try Data("tracked seed\n".utf8).write(to: repository.appending(path: "tracked.txt"))
        try await worktreeCreationGit(at: repository, arguments: ["add", "tracked.txt"])
        try await worktreeCreationGit(at: repository, arguments: ["commit", "-m", "clean seed"])
        #expect(try await worktreeCreationGit(at: repository, arguments: ["status", "--porcelain=v1"]).isEmpty)
        let untrackedPath = "untracked-only.txt"
        let untrackedBytes = Data("only untracked dirt\n".utf8)
        try untrackedBytes.write(to: repository.appending(path: untrackedPath))
        let beforeHead = try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"])
        let beforeStatus = try await worktreeCreationGit(at: repository, arguments: ["status", "--porcelain=v1"])
        #expect(beforeStatus.split(separator: "\n").map(String.init) == ["?? \(untrackedPath)"])
        let branch = "feature/refused-untracked-only"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }

        for json in [false, true] {
            let probe = WorktreeCreationCommandLineProbe()
            let exit = await WorktreeCommandLine.run(
                arguments: ["new", branch, "--repo", repository.path] + (json ? ["--json"] : []),
                currentDirectory: repository,
                output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) })
            #expect(exit == 1)
            #expect(probe.errorSnapshot().isEmpty)
            let output = try #require(probe.outputSnapshot().first)
            if json {
                let document = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
                #expect(document["reason"] as? String == "sourceDirty")
                let details = try #require(document["details"] as? [String: Any])
                let stop = try JSONDecoder().decode(
                    WorktreeCreationStop.self, from: JSONSerialization.data(withJSONObject: details))
                guard case .sourceDirty(let changes) = stop else {
                    Issue.record("expected sourceDirty, received \(stop)")
                    return
                }
                #expect(changes.staged == 0)
                #expect(changes.unstaged == 0)
                #expect(changes.conflicted == 0)
                #expect(changes.untracked == 1)
                #expect(changes.firstPaths == [untrackedPath])
            } else {
                #expect(output.contains("sourceDirty"))
                #expect(output.contains("untracked=1"))
                #expect(output.contains("paths=[\(untrackedPath)]"))
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try await worktreeCreationGit(at: repository, arguments: ["branch", "--list", branch]).isEmpty)
            #expect(try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"]) == beforeHead)
            #expect(
                try await worktreeCreationGit(at: repository, arguments: ["status", "--porcelain=v1"]) == beforeStatus)
            #expect(try Data(contentsOf: repository.appending(path: untrackedPath)) == untrackedBytes)
        }
    }
}
