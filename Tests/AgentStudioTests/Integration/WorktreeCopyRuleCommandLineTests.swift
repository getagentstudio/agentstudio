import AgentStudioGit
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Darwin
import Foundation
import Testing

@Suite("Worktree copy-rule command line")
struct WorktreeCopyRuleCommandLineTests {
    @Test("new copies included ignored directories, excludes unmatched paths and reports the materialization")
    func copiesOnlyIncludedIgnoredPaths() async throws {
        let repository = try await makeRepository(named: "cli-copy-rules", include: ["included/"])
        defer { FilesystemTestGitRepo.destroy(repository) }
        let destination = try siblingDestination(repository: repository, branch: "feature/rules")
        defer { try? FileManager.default.removeItem(at: destination) }
        let (exit, text) = try await runNew(repository: repository, branch: "feature/rules", json: true)
        #expect(exit == 0)
        #expect(
            try Data(contentsOf: destination.appending(path: "included/cache.bin"))
                == Data("included ignored content".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "excluded").path))
        let document = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let report = try #require(document["materialization"] as? [String: Any])
        #expect(report["ignoredIncludedPatterns"] as? [String] == ["included/"])
        #expect(report["ignoredExcludedCount"] as? Int == 2)
        #expect((report["nestedWorktreesSkipped"] as? [String])?.isEmpty == true)
    }

    @Test("missing include declaration copies no ignored files", arguments: [false, true])
    func absentRulesExcludeIgnoredPaths(hasConfig: Bool) async throws {
        let repository = try await makeRepository(named: "cli-empty-copy-rules", include: hasConfig ? [] : nil)
        defer { FilesystemTestGitRepo.destroy(repository) }
        let destination = try siblingDestination(repository: repository, branch: "feature/empty-rules")
        defer { try? FileManager.default.removeItem(at: destination) }
        let (exit, _) = try await runNew(repository: repository, branch: "feature/empty-rules", json: true)
        #expect(exit == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "included").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "excluded").path))
        #expect(try Data(contentsOf: destination.appending(path: "tracked.txt")) == Data("tracked".utf8))
    }

    @Test(
        "invalid include entries refuse before creation with the declaration path and offending entry",
        arguments: ["!included/", "#comment"])
    func refusesInvalidIncludePatterns(pattern: String) async throws {
        let repository = try await makeRepository(named: "cli-invalid-copy-rules", include: [pattern])
        defer { FilesystemTestGitRepo.destroy(repository) }
        let branch = "feature/invalid-rules"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        for json in [false, true] {
            let (exit, text) = try await runNew(repository: repository, branch: branch, json: json)
            #expect(exit == 1)
            #expect(text.contains("configInvalid"))
            #expect(text.contains(".agentstudio.config.json"))
            #expect(text.contains(pattern))
        }
        try await expectAbsent(repository: repository, destination: destination, branch: branch)
    }

    @Test("unreadable source index fails closed on default and explicit sources", arguments: [false, true])
    func refusesUnreadableSourceIndex(usesExplicitSource: Bool) async throws {
        let repository = try await makeRepository(named: "cli-unreadable-index", include: [])
        defer { FilesystemTestGitRepo.destroy(repository) }
        let index = repository.appending(path: ".git/index")
        try #require(chmod(index.path, 0o000) == 0)
        defer { _ = chmod(index.path, 0o644) }
        let branch = "feature/unreadable-index"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        for json in [false, true] {
            let (exit, text) = try await runNew(
                repository: repository, branch: branch, json: json, explicitSource: usesExplicitSource)
            #expect(exit == 1)
            #expect(text.contains("sourceIndexUnreadable"))
            #expect(!text.contains("changesUnknown"))
            #expect(text.contains("retry"))
            #expect(text.contains("--no-fork"))
        }
        try await expectAbsent(repository: repository, destination: destination, branch: branch)
    }

    @Test("unsupported split index fails closed on default and explicit sources", arguments: [false, true])
    func refusesUnsupportedSourceIndex(usesExplicitSource: Bool) async throws {
        let repository = try await makeRepository(named: "cli-split-index", include: [])
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await worktreeCreationGit(at: repository, arguments: ["update-index", "--split-index"])
        let branch = "feature/unsupported-index"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        for json in [false, true] {
            let (exit, text) = try await runNew(
                repository: repository, branch: branch, json: json, explicitSource: usesExplicitSource)
            #expect(exit == 1)
            #expect(text.contains("sourceIndexUnsupported"))
            #expect(!text.contains("changesUnknown"))
            #expect(text.contains("--no-fork"))
            #expect(!text.contains("retry"))
        }
        try await expectAbsent(repository: repository, destination: destination, branch: branch)
    }

    @Test("human creation prints one line and the copy-rule report stays in --json")
    func humanOutputIsOneLineAndJSONCarriesCopyRuleReport() async throws {
        let repository = try await makeRepository(named: "cli-copy-rules-human", include: ["included/"])
        defer { FilesystemTestGitRepo.destroy(repository) }
        let destination = try siblingDestination(repository: repository, branch: "feature/human")
        defer { try? FileManager.default.removeItem(at: destination) }
        let (exit, text) = try await runNew(repository: repository, branch: "feature/human", json: false)
        #expect(exit == 0)
        #expect(text == "created feature/human at \(destination.path) (copy-on-write)")

        let jsonBranch = "feature/human-json"
        let jsonDestination = try siblingDestination(repository: repository, branch: jsonBranch)
        defer { try? FileManager.default.removeItem(at: jsonDestination) }
        let (jsonExit, json) = try await runNew(repository: repository, branch: jsonBranch, json: true)
        #expect(jsonExit == 0)
        let document = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let materialization = try #require(document["materialization"] as? [String: Any])
        #expect(materialization["ignoredIncludedPatterns"] as? [String] == ["included/"])
        #expect(materialization["ignoredExcludedCount"] as? Int == 2)
        #expect((materialization["nestedWorktreesSkipped"] as? [String])?.isEmpty == true)
    }

    private func makeRepository(named name: String, include: [String]?) async throws -> URL {
        let repository = try await FilesystemTestGitRepo.create(named: name)
        try Data("tracked".utf8).write(to: repository.appending(path: "tracked.txt"))
        try Data("included/\nexcluded/\n".utf8).write(to: repository.appending(path: ".gitignore"))
        if let include {
            let config = AgentStudioRepositoryConfig(worktree: WorktreeCopyConfig(include: include))
            try JSONEncoder().encode(config).write(to: repository.appending(path: ".agentstudio.config.json"))
        }
        try await worktreeCreationGit(at: repository, arguments: ["add", "."])
        try await worktreeCreationGit(at: repository, arguments: ["commit", "-m", "base"])
        for directory in ["included", "excluded"] {
            try FileManager.default.createDirectory(
                at: repository.appending(path: directory), withIntermediateDirectories: true)
            try Data("included ignored content".utf8).write(to: repository.appending(path: "\(directory)/cache.bin"))
        }
        return repository
    }

    private func runNew(repository: URL, branch: String, json: Bool, explicitSource: Bool = false) async throws -> (
        Int32, String
    ) {
        let probe = WorktreeCreationCommandLineProbe()
        let source = explicitSource ? ["--from", repository.path] : []
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", "-c", branch, "--repo", repository.path] + source + (json ? ["--json"] : []),
            currentDirectory: repository,
            output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) })
        #expect(probe.errorSnapshot().isEmpty)
        return (exit, try #require(probe.outputSnapshot().first))
    }

    private func expectAbsent(repository: URL, destination: URL, branch: String) async throws {
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await worktreeCreationGit(at: repository, arguments: ["branch", "--list", branch]).isEmpty)
    }
}
