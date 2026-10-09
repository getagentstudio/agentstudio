import AgentStudioGit
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree source preflight integration")
struct WorktreeSourcePreflightIntegrationTests {
    @Test("default new invoked from a linked checkout copies main as it is, including an included ignored folder")
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
        try Data("included ignored content".utf8).write(to: cache)
        let linkedBranch = "feature/caller"
        let linked = try siblingDestination(repository: repository, branch: linkedBranch)
        defer { try? FileManager.default.removeItem(at: linked) }
        _ = try await LibGit2AgentStudioGitLocalClient().createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: repository, destinationPath: linked,
                mode: .newBranch(name: linkedBranch, startPoint: .named("HEAD"), upstream: nil)))
        try Data("caller only".utf8).write(to: linked.appending(path: "caller.txt"))
        try await worktreeCreationGit(at: linked, arguments: ["add", "caller.txt"])
        try await worktreeCreationGit(at: linked, arguments: ["commit", "-m", "caller change"])
        let branch = "feature/default-main-copy"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        let probe = WorktreeCreationCommandLineProbe()
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", "-c", branch, "--json"], currentDirectory: linked,
            output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) })
        #expect(exit == 0)
        #expect(probe.errorSnapshot().isEmpty)
        #expect(probe.outputSnapshot().first?.contains("copyOnWrite") == true)
        #expect(
            try Data(contentsOf: destination.appending(path: ".build-cache/output"))
                == Data("included ignored content".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "caller.txt").path))
        #expect(
            try await worktreeCreationGit(at: destination, arguments: ["rev-parse", "HEAD"])
                == worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"]))
    }

    @Test("copy capability refusal offers --changes-only only where it is a valid continuation")
    func reportsValidCopyAlternatives() async throws {
        struct AlternativesCase {
            let source: WorktreeCreateSource
            let branch: String
            let create: Bool
            let startBranch: String?
            let offersChangesOnly: Bool
        }
        let repository = try await seededRepository(named: "new-copy-alternatives")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await worktreeCreationGit(at: repository, arguments: ["branch", "feature/existing"])
        let realClient = LibGit2AgentStudioGitLocalClient()
        let snapshot = try #require(await realClient.worktrees(for: repository).first)
        let identity = try await realClient.repositoryIdentity(for: repository)
        let canonicalRepository = try #require(identity.mainWorktreePath).standardizedFileURL
        let client = WorktreeOperationClientStub(
            startPath: canonicalRepository, snapshot: snapshot, identity: identity, baseClient: realClient)
        let cases = [
            // The main worktree as the source: --changes-only needs --from.
            AlternativesCase(
                source: .mainWorktree, branch: "feature/unavailable", create: true, startBranch: nil,
                offersChangesOnly: false),
            // -c --from creating a new branch at the source's HEAD: --changes-only would do it without a fork.
            AlternativesCase(
                source: .worktree(canonicalRepository), branch: "feature/unavailable", create: true, startBranch: nil,
                offersChangesOnly: true),
            // --from with --from-branch: --changes-only excludes --from-branch.
            AlternativesCase(
                source: .worktree(canonicalRepository), branch: "feature/unavailable", create: true,
                startBranch: "main", offersChangesOnly: false),
            // --from opening an existing branch (no -c): --changes-only only creates.
            AlternativesCase(
                source: .worktree(canonicalRepository), branch: "feature/existing", create: false, startBranch: nil,
                offersChangesOnly: false),
        ]
        for testCase in cases {
            let outcome = await WorktreeOperationRunner(client: client).run(
                .create(
                    WorktreeCreateRequest(
                        start: canonicalRepository, branch: testCase.branch, create: testCase.create,
                        source: testCase.source, startBranch: testCase.startBranch, materialization: .copyOnWrite,
                        fetchPolicy: .skip)
                ))
            #expect(
                outcome
                    == .refused(
                        .forkUnavailable(.clientCapabilityUnavailable, offersChangesOnly: testCase.offersChangesOnly),
                        creationFetch: .skipped(.noFetchFlag)),
                "\(testCase.branch) \(testCase.startBranch ?? "-")")
            let response = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
            let document = try #require(JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
            #expect(document["alternative"] == nil)
            #expect(
                document["alternatives"] as? [String]
                    == (testCase.offersChangesOnly ? ["checkout", "changesOnly"] : ["checkout"]))
            let human = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
            #expect(human.text.contains("--no-fork"))
            #expect(human.text.contains("--changes-only") == testCase.offersChangesOnly)
        }
    }

    @Test("default new forks a dirty main checkout as it is and leaves main unchanged")
    func forksDirtyDefaultSourceAsItIs() async throws {
        let repository = try await seededRepository(named: "new-dirty-default")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let unstagedBytes = Data("tracked\nunstaged change\n".utf8)
        let untrackedBytes = Data("untracked work\n".utf8)
        try unstagedBytes.write(to: repository.appending(path: "tracked.txt"))
        try untrackedBytes.write(to: repository.appending(path: "untracked.txt"))
        let mainHead = try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"])
        let beforeStatus = try await worktreeCreationGit(at: repository, arguments: ["status", "--porcelain=v1"])
        #expect(beforeStatus.contains("M tracked.txt"))
        #expect(beforeStatus.contains("?? untracked.txt"))
        let branch = "feature/dirty-copy"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }

        let document = try await runDefaultNew(repository: repository, branch: branch)

        #expect(document.outcome == "created")
        #expect(document.materialization?.kind == "copyOnWrite")
        #expect(try Data(contentsOf: destination.appending(path: "tracked.txt")) == unstagedBytes)
        #expect(try Data(contentsOf: destination.appending(path: "untracked.txt")) == untrackedBytes)
        #expect(try await worktreeCreationGit(at: destination, arguments: ["rev-parse", "HEAD"]) == mainHead)
        #expect(try await worktreeCreationGit(at: repository, arguments: ["status", "--porcelain=v1"]) == beforeStatus)
        #expect(try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"]) == mainHead)
    }

    @Test("default new forks a main checkout on a non-default branch at its HEAD commit")
    func forksOffBranchDefaultSourceAtItsHead() async throws {
        let repository = try await seededRepository(named: "new-off-default-copy")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await worktreeCreationGit(at: repository, arguments: ["checkout", "-b", "feature/source"])
        try Data("source branch\n".utf8).write(to: repository.appending(path: "source.txt"))
        try await worktreeCreationGit(at: repository, arguments: ["add", "source.txt"])
        try await worktreeCreationGit(at: repository, arguments: ["commit", "-m", "source branch commit"])
        let mainHead = try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"])
        #expect(try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "refs/heads/main"]) != mainHead)
        let branch = "feature/off-branch-copy"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }

        let document = try await runDefaultNew(repository: repository, branch: branch)

        #expect(document.outcome == "created")
        #expect(document.materialization?.kind == "copyOnWrite")
        #expect(
            try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "refs/heads/\(branch)"]) == mainHead)
        #expect(try await worktreeCreationGit(at: destination, arguments: ["rev-parse", "HEAD"]) == mainHead)
        #expect(
            try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
                == "feature/source")
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
            arguments: ["new", "-c", branch, "--from", repository.path, "--json"], currentDirectory: repository,
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
        "malformed config refuses only copy-on-write and offers --no-fork",
        arguments: [WorktreeCreateMaterialization.copyOnWrite, .changesOnly, .checkout])
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
        case .checkout: options = ["--no-fork"]
        }
        let beforeHead = try await worktreeCreationGit(at: repository, arguments: ["rev-parse", "HEAD"])
        let beforeStatus = try await worktreeCreationGit(at: repository, arguments: ["status", "--porcelain=v1"])
        let probe = WorktreeCreationCommandLineProbe()
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", "-c", branch, "--repo", repository.path, "--json"] + options,
            currentDirectory: repository,
            output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) })
        #expect(probe.errorSnapshot().isEmpty)
        let output = try #require(probe.outputSnapshot().first)
        if materialization == .copyOnWrite {
            #expect(exit == 1)
            #expect(output.contains("configInvalid"))
            #expect(output.contains(".agentstudio.config.json"))
            #expect(output.contains("--no-fork"))
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

    private func runDefaultNew(
        repository: URL, branch: String
    ) async throws -> WorktreeCreationCommandLineDocuments.CreatedDocument {
        let probe = WorktreeCreationCommandLineProbe()
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", "-c", branch, "--repo", repository.path, "--json"], currentDirectory: repository,
            output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) })
        let output = try #require(probe.outputSnapshot().first)
        #expect(exit == 0, "default new did not create: \(output)")
        #expect(probe.errorSnapshot().isEmpty)
        return try JSONDecoder().decode(
            WorktreeCreationCommandLineDocuments.CreatedDocument.self, from: Data(output.utf8))
    }

    private func expectNoCreation(repository: URL, destination: URL, branch: String) async throws {
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await worktreeCreationGit(at: repository, arguments: ["branch", "--list", branch]).isEmpty)
    }
}
