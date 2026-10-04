import AgentStudioGit
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Darwin
import Foundation
import Testing

@Suite("Worktree source preflight integration")
struct WorktreeSourcePreflightIntegrationTests {
    @Test("default new invoked from a linked checkout copies the clean main HEAD and warm cache")
    func copiesMainSourceFromLinkedCheckout() async throws {
        let repository = try await seededRepository(named: "new-main-from-linked")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try Data("*.lock\n.build-cache/\n".utf8).write(to: repository.appending(path: ".gitignore"))
        try Data(#"{"worktree":{"include":[".build-cache/"],"busyLocks":["build.lock"]}}"#.utf8)
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

    @Test("declared busy lock refuses real exclusive and shared holder processes", arguments: [false, true])
    func refusesRealBusyLock(shared: Bool) async throws {
        let repository = try await seededRepository(named: "new-busy-lock")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let config = repository.appending(path: ".agentstudio.config.json")
        try Data(#"{"worktree":{"busyLocks":["build.lock"]}}"#.utf8).write(to: config)
        try await worktreeCreationGit(at: repository, arguments: ["add", ".agentstudio.config.json"])
        try await worktreeCreationGit(at: repository, arguments: ["commit", "-m", "declare lock"])
        let lock = repository.appending(path: "build.lock")
        try Data("lock contents".utf8).write(to: lock)
        let holder = WorktreeSourceLockHolder()
        try await holder.start(lock: lock, shared: shared)
        do {
            let branch = "feature/busy"
            let destination = try siblingDestination(repository: repository, branch: branch)
            for source in [WorktreeCreateSource.mainWorktree, .worktree(repository)] {
                let outcome = await WorktreeOperationRunner().run(
                    .create(
                        WorktreeCreateRequest(
                            start: repository, branch: branch, source: source, materialization: .copyOnWrite)))
                #expect(outcome == .refused(.creationStopped(.sourceBusy(path: lock.path))))
                try await expectNoCreation(repository: repository, destination: destination, branch: branch)
            }
            #expect(try Data(contentsOf: lock) == Data("lock contents".utf8))
        } catch {
            _ = await holder.stop()
            throw error
        }
        #expect(await holder.stop() == 0)
        #expect(await WorktreeSourceBusyLockProbe.refusal(lockFiles: [lock]) == nil)
        #expect(try Data(contentsOf: lock) == Data("lock contents".utf8))
    }

    @Test("missing and free locks stay untouched while no-follow errors carry errno")
    func testsConcreteLocksWithoutCreatingOrFollowing() async throws {
        let repository = try await seededRepository(named: "new-lock-probe")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let absent = repository.appending(path: "absent.lock")
        #expect(await WorktreeSourceBusyLockProbe.refusal(lockFiles: [absent]) == nil)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        let real = repository.appending(path: "real.lock")
        try Data("unchanged".utf8).write(to: real)
        #expect(await WorktreeSourceBusyLockProbe.refusal(lockFiles: [real]) == nil)
        let link = repository.appending(path: "linked.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(
            await WorktreeSourceBusyLockProbe.refusal(lockFiles: [link])
                == .sourceBusyUnknown(path: link.path, errno: ELOOP))
        #expect(try Data(contentsOf: real) == Data("unchanged".utf8))
    }

    @Test("malformed config refuses all materializations before mutation")
    func refusesInvalidRepositoryConfig() async throws {
        let repository = try await seededRepository(named: "new-invalid-config")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try Data("{".utf8).write(to: repository.appending(path: ".agentstudio.config.json"))
        for materialization in [
            WorktreeCreateMaterialization.copyOnWrite, .changesOnly, .trackedOnly(startBranch: nil),
        ] {
            let branch = "feature/invalid-config"
            let destination = try siblingDestination(repository: repository, branch: branch)
            let source: WorktreeCreateSource =
                materialization == .trackedOnly(startBranch: nil) ? .mainWorktree : .worktree(repository)
            let outcome = await WorktreeOperationRunner().run(
                .create(
                    WorktreeCreateRequest(
                        start: repository, branch: branch, source: source, materialization: materialization)))
            guard case .refused(.creationStopped(.configInvalid(let path, let error))) = outcome else {
                Issue.record("expected configInvalid, received \(outcome)")
                continue
            }
            #expect(path == repository.appending(path: ".agentstudio.config.json").path)
            #expect(!error.isEmpty)
            try await expectNoCreation(repository: repository, destination: destination, branch: branch)
        }
    }

    private func seededRepository(named name: String) async throws -> URL {
        let repository = try await FilesystemTestGitRepo.create(named: name)
        try Data("tracked\n".utf8).write(to: repository.appending(path: "tracked.txt"))
        try Data("*.lock\n".utf8).write(to: repository.appending(path: ".gitignore"))
        try await worktreeCreationGit(at: repository, arguments: ["add", "tracked.txt", ".gitignore"])
        try await worktreeCreationGit(at: repository, arguments: ["commit", "-m", "base"])
        return repository
    }

    private func expectNoCreation(repository: URL, destination: URL, branch: String) async throws {
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await worktreeCreationGit(at: repository, arguments: ["branch", "--list", branch]).isEmpty)
    }
}

private final class WorktreeSourceLockHolder: @unchecked Sendable {
    private let process = Process()
    private let readiness = Pipe()
    private let lifetime = Pipe()

    func start(lock: URL, shared: Bool) async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-MFcntl=:flock", "-e",
            """
            $| = 1;
            open(my $lock, '<', $ARGV[0]) or die $!;
            flock($lock, $ARGV[1] eq 'shared' ? LOCK_SH : LOCK_EX) or die $!;
            print 'R';
            while (defined(my $line = <STDIN>)) { }
            """,
            lock.path,
            shared ? "shared" : "exclusive",
        ]
        process.standardOutput = readiness
        process.standardInput = lifetime
        try process.run()
        try readiness.fileHandleForWriting.close()
        try lifetime.fileHandleForReading.close()
        let ready = try await withoutBlockingCooperativePool {
            try self.readiness.fileHandleForReading.read(upToCount: 1)
        }
        guard ready == Data("R".utf8) else {
            _ = await stop()
            throw NSError(domain: "WorktreeSourceLockHolder", code: 1)
        }
    }

    func stop() async -> Int32 {
        try? lifetime.fileHandleForWriting.close()
        return await withoutBlockingCooperativePool {
            self.process.waitUntilExit()
            try? self.readiness.fileHandleForReading.close()
            return self.process.terminationStatus
        }
    }
}
