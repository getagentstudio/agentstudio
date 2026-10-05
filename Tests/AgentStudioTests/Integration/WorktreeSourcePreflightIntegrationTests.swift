import AgentStudioGit
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree source preflight integration")
struct WorktreeSourcePreflightIntegrationTests {
    @Test("default new invoked from a linked checkout copies the clean main HEAD and warm cache")
    func copiesMainSourceFromLinkedCheckout() async throws {
        let repository = try await seededRepository(named: "new-main-from-linked")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try Data(".build-cache/\n".utf8).write(to: repository.appending(path: ".gitignore"))
        try Data(#"{"worktree":{"include":[".build-cache/"]}}"#.utf8)
            .write(to: repository.appending(path: ".agentstudio.config.json"))
        try await worktreeCreationGit(at: repository, arguments: ["add", ".gitignore", ".agentstudio.config.json"])
        try await worktreeCreationGit(at: repository, arguments: ["commit", "-m", "declare cache"])
        let cache = repository.appending(path: ".build-cache/output")
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("warm cache".utf8).write(to: cache)
        let linkedBranch = "feature/caller"
        let linked = try siblingDestination(repository: repository, branch: linkedBranch)
        defer { try? FileManager.default.removeItem(at: linked) }
        _ = try await LibGit2AgentStudioGitLocalClient().createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: repository, destinationPath: linked,
                mode: .newBranch(name: linkedBranch, startPoint: .named("HEAD"))))
        try Data("caller only".utf8).write(to: linked.appending(path: "caller.txt"))
        try await worktreeCreationGit(at: linked, arguments: ["add", "caller.txt"])
        try await worktreeCreationGit(at: linked, arguments: ["commit", "-m", "caller change"])
        let branch = "feature/default-main-copy"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        let probe = WorktreeCreationCommandLineProbe()
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--json"], currentDirectory: linked,
            output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) })
        #expect(exit == 0)
        #expect(probe.errorSnapshot().isEmpty)
        #expect(probe.outputSnapshot().first?.contains("copyOnWrite") == true)
        #expect(try Data(contentsOf: destination.appending(path: ".build-cache/output")) == Data("warm cache".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "caller.txt").path))
        #expect(
            try await worktreeCreationGit(at: destination, arguments: ["rev-parse", "HEAD"])
                == worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"]))
    }

    @Test("copy capability refusal offers only alternatives valid for the selected source")
    func reportsSourceSpecificCopyAlternatives() async throws {
        let repository = try await seededRepository(named: "new-copy-alternatives")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let realClient = LibGit2AgentStudioGitLocalClient()
        let snapshot = try #require(await realClient.worktrees(for: repository).first)
        let identity = try await realClient.repositoryIdentity(for: repository)
        let canonicalRepository = try #require(identity.mainWorktreePath).standardizedFileURL
        let client = WorktreeOperationClientStub(
            startPath: canonicalRepository, snapshot: snapshot, identity: identity, baseClient: realClient)
        for source in [WorktreeCreateSource.mainWorktree, .worktree(canonicalRepository)] {
            let outcome = await WorktreeOperationRunner(client: client).run(
                .create(
                    WorktreeCreateRequest(
                        start: canonicalRepository, branch: "feature/unavailable", source: source,
                        materialization: .copyOnWrite)
                ))
            #expect(outcome == .refused(.forkUnavailable(.clientCapabilityUnavailable, source: source)))
            let response = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
            let document = try #require(JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
            #expect(document["alternative"] == nil)
            #expect(
                document["alternatives"] as? [String]
                    == (source == .mainWorktree ? ["trackedOnly"] : ["trackedOnly", "changesOnly"]))
            let human = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
            #expect(human.text.contains("--tracked-only"))
            #expect(human.text.contains("--changes-only") == (source != .mainWorktree))
        }
    }

    @Test("default source off default branch refuses without mutation")
    func refusesNonDefaultMainBranch() async throws {
        let repository = try await seededRepository(named: "new-off-default")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await worktreeCreationGit(at: repository, arguments: ["checkout", "-b", "feature/source"])
        let branch = "feature/refused"
        let destination = try siblingDestination(repository: repository, branch: branch)
        let outcome = await WorktreeOperationRunner().run(
            .create(
                WorktreeCreateRequest(
                    start: repository, branch: branch, source: .mainWorktree, materialization: .copyOnWrite)))
        #expect(
            outcome == .refused(.creationStopped(.sourceNotOnDefaultBranch(actual: "feature/source", expected: "main")))
        )
        try await expectNoCreation(repository: repository, destination: destination, branch: branch)
    }

    @Test("explicit main source copies dirty files and its HEAD even off default branch")
    func copiesExplicitDirtyMainSource() async throws {
        let repository = try await seededRepository(named: "new-explicit-dirty")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await worktreeCreationGit(at: repository, arguments: ["checkout", "-b", "feature/source"])
        try Data("dirty source\n".utf8).write(to: repository.appending(path: "tracked.txt"))
        let branch = "feature/copied"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        let probe = WorktreeCreationCommandLineProbe()
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--from", repository.path, "--json"], currentDirectory: repository,
            output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) })
        #expect(exit == 0)
        #expect(probe.errorSnapshot().isEmpty)
        #expect(probe.outputSnapshot().first?.contains("copyOnWrite") == true)
        #expect(try Data(contentsOf: destination.appending(path: "tracked.txt")) == Data("dirty source\n".utf8))
        #expect(
            try await worktreeCreationGit(at: destination, arguments: ["rev-parse", "HEAD"])
                == worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"]))
    }

    @Test(
        "malformed config refuses only copy-on-write and offers tracked-only",
        arguments: [WorktreeCreateMaterialization.copyOnWrite, .changesOnly, .trackedOnly(startBranch: nil)])
    func readsConfigOnlyForCopyOnWrite(materialization: WorktreeCreateMaterialization) async throws {
        let repository = try await seededRepository(named: "new-invalid-config")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try Data("{".utf8).write(to: repository.appending(path: ".agentstudio.config.json"))
        let branch = "feature/invalid-config"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        let options: [String]
        switch materialization {
        case .copyOnWrite: options = ["--from", repository.path]
        case .changesOnly: options = ["--from", repository.path, "--changes-only"]
        case .trackedOnly: options = ["--tracked-only"]
        }
        let beforeHead = try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"])
        let beforeStatus = try await worktreeCreationGit(at: repository, arguments: ["status", "--porcelain=v1"])
        let probe = WorktreeCreationCommandLineProbe()
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--repo", repository.path, "--json"] + options,
            currentDirectory: repository,
            output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) })
        #expect(probe.errorSnapshot().isEmpty)
        let output = try #require(probe.outputSnapshot().first)
        if materialization == .copyOnWrite {
            #expect(exit == 1)
            #expect(output.contains("configInvalid"))
            #expect(output.contains(".agentstudio.config.json"))
            #expect(output.contains("--tracked-only"))
            try await expectNoCreation(repository: repository, destination: destination, branch: branch)
        } else {
            #expect(exit == 0)
            #expect(output.contains("created"))
            #expect(try Data(contentsOf: destination.appending(path: "tracked.txt")) == Data("tracked\n".utf8))
            #expect(
                try await worktreeCreationGit(at: repository, arguments: ["branch", "--list", branch]).isEmpty == false)
        }
        #expect(try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"]) == beforeHead)
        #expect(try await worktreeCreationGit(at: repository, arguments: ["status", "--porcelain=v1"]) == beforeStatus)
    }

    private func seededRepository(named name: String) async throws -> URL {
        let repository = try await FilesystemTestGitRepo.create(named: name)
        try Data("tracked\n".utf8).write(to: repository.appending(path: "tracked.txt"))
        try await worktreeCreationGit(at: repository, arguments: ["add", "tracked.txt"])
        try await worktreeCreationGit(at: repository, arguments: ["commit", "-m", "base"])
        return repository
    }

    private func expectNoCreation(repository: URL, destination: URL, branch: String) async throws {
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await worktreeCreationGit(at: repository, arguments: ["branch", "--list", branch]).isEmpty)
    }
}
