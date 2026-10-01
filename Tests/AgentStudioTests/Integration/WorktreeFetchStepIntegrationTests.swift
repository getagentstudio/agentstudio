import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree fetch step with real Git")
struct WorktreeFetchStepIntegrationTests {
    @Test("no origin HEAD fetches main's upstream and re-resolves E4")
    func fetchesOriginUpstreamWithoutOriginHead() async throws {
        let fixture = try await WorktreeFetchRepositoryFixture.create()
        defer { fixture.destroy() }
        let client = LibGit2AgentStudioGitLocalClient()
        let resolver = WorktreeIntegrationTargetResolver(client: client)
        let step = WorktreeFetchStep(
            localClient: client,
            remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        )

        #expect(!FileManager.default.fileExists(atPath: fixture.originHeadPath.path))
        let initialTarget = try #require(await resolver.resolve(repositoryPath: fixture.repository))
        #expect(initialTarget.referenceName == "refs/remotes/origin/main")
        #expect(initialTarget.branchName == "main")
        #expect(initialTarget.commit == fixture.initialCommit)
        #expect(initialTarget.fetchSource == .origin(branchName: "main"))

        let skipped = await step.run(
            repositoryPath: fixture.repository,
            target: initialTarget,
            policy: .skip
        )
        #expect(skipped.status == .skipped(reason: .noFetchFlag))
        #expect(skipped.target?.commit == fixture.initialCommit)
        #expect(try await fixture.reference("refs/remotes/origin/main") == fixture.initialCommit)

        let fetched = await step.run(
            repositoryPath: fixture.repository,
            target: initialTarget,
            policy: .defaultBranch
        )
        #expect(fetched.status == .fetched(commit: fixture.remoteCommit))
        #expect(fetched.target?.referenceName == "refs/remotes/origin/main")
        #expect(fetched.target?.branchName == "main")
        #expect(fetched.target?.commit == fixture.remoteCommit)
        #expect(try await fixture.reference("refs/remotes/origin/main") == fixture.remoteCommit)
        let remoteTrackingRefs = try await fixture.references(under: "refs/remotes/origin")
        #expect(!remoteTrackingRefs.contains("refs/remotes/origin/unrelated"))
    }

    @Test("a main branch without an upstream skips automatic fetching")
    func noRemoteSkipsFetch() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "fetch-no-remote")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await createInitialCommit(in: repository)
        let client = LibGit2AgentStudioGitLocalClient()
        let resolver = WorktreeIntegrationTargetResolver(client: client)
        let step = WorktreeFetchStep(localClient: client)
        let target = try #require(await resolver.resolve(repositoryPath: repository))

        #expect(target.referenceName == "refs/heads/main")
        #expect(target.fetchSource == .noRemote)
        let result = await step.run(repositoryPath: repository, target: target, policy: .defaultBranch)
        #expect(result.status == .skipped(reason: .noRemote))
        #expect(result.target == target)
    }

    @Test("no target skips before the fetch policy in both fetch modes")
    func noTargetPrecedesNoFetchFlag() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "fetch-no-target")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let client = LibGit2AgentStudioGitLocalClient()
        let resolver = WorktreeIntegrationTargetResolver(client: client)
        let step = WorktreeFetchStep(localClient: client)
        let target = try await resolver.resolve(repositoryPath: repository)

        #expect(target == nil)
        let fetching = await step.run(repositoryPath: repository, target: target, policy: .defaultBranch)
        let skipping = await step.run(repositoryPath: repository, target: target, policy: .skip)
        #expect(fetching.target == nil)
        #expect(fetching.status == .skipped(reason: .noTarget))
        #expect(skipping.target == nil)
        #expect(skipping.status == .skipped(reason: .noTarget))
    }

    @Test("a non-origin upstream is assessed as-is without fetching")
    func nonOriginUpstreamIsNotFetched() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "fetch-non-origin")
        let bareRemote = repository.deletingLastPathComponent().appending(
            path: "non-origin-\(UUIDv7.generate().uuidString).git"
        )
        defer {
            FilesystemTestGitRepo.destroy(repository)
            try? FileManager.default.removeItem(at: bareRemote)
        }
        try await createInitialCommit(in: repository)
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["init", "--bare", bareRemote.path])
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["remote", "add", "company", bareRemote.path])
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["push", "--set-upstream", "company", "main"])
        try await FilesystemTestGitRepo.runGit(
            at: repository,
            args: ["fetch", "company", "+refs/heads/main:refs/remotes/company/main"]
        )
        let client = LibGit2AgentStudioGitLocalClient()
        let resolver = WorktreeIntegrationTargetResolver(client: client)
        let step = WorktreeFetchStep(
            localClient: client,
            remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        )
        let target = try #require(await resolver.resolve(repositoryPath: repository))
        let targetCommit = try await reference("refs/remotes/company/main", in: repository)

        #expect(target.referenceName == "refs/remotes/company/main")
        #expect(target.branchName == "main")
        #expect(target.commit == targetCommit)
        #expect(target.fetchSource == .upstreamNotOrigin)
        let result = await step.run(repositoryPath: repository, target: target, policy: .defaultBranch)
        #expect(result.status == .failed(reason: .upstreamNotOrigin))
        #expect(result.target == target)
        #expect(try await reference("refs/remotes/company/main", in: repository) == targetCommit)
    }

    @Test("a failed fetch retains the captured local target and reports the failure")
    func failedFetchFallsBackToLocalTarget() async throws {
        let fixture = try await WorktreeFetchRepositoryFixture.create()
        defer { fixture.destroy() }
        try await FilesystemTestGitRepo.runGit(
            at: fixture.repository,
            args: ["remote", "set-url", "origin", fixture.missingRemote.path]
        )
        let client = LibGit2AgentStudioGitLocalClient()
        let resolver = WorktreeIntegrationTargetResolver(client: client)
        let step = WorktreeFetchStep(
            localClient: client,
            remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        )
        let target = try #require(await resolver.resolve(repositoryPath: fixture.repository))
        #expect(target.commit == fixture.initialCommit)

        let result = await step.run(repositoryPath: fixture.repository, target: target, policy: .defaultBranch)
        #expect(result.target == target)
        guard case .failed(let reason, let lock, let lockResidue) = result.status else {
            Issue.record("expected a fail-soft fetch status, received \(result.status)")
            return
        }
        #expect(reason == .processFailure)
        #expect(lock == nil)
        #expect(lockResidue == nil)
    }

    @Test("a foreign remote-tracking lock is reported and preserved")
    func reportsForeignRemoteTrackingLock() async throws {
        let fixture = try await WorktreeFetchRepositoryFixture.create()
        defer { fixture.destroy() }
        let lockPath = fixture.remoteMainLockPath
        let lockBytes = Data("foreign owner\n".utf8)
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lockBytes.write(to: lockPath)

        let client = LibGit2AgentStudioGitLocalClient()
        let resolver = WorktreeIntegrationTargetResolver(client: client)
        let step = WorktreeFetchStep(
            localClient: client,
            remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        )
        let target = try #require(await resolver.resolve(repositoryPath: fixture.repository))
        let result = await step.run(repositoryPath: fixture.repository, target: target, policy: .defaultBranch)

        #expect(
            result.status
                == .failed(
                    reason: .gitLockHeld,
                    lock: WorktreeFetchLock(
                        path: lockPath.standardizedFileURL.path,
                        resource: .reference(name: "refs/remotes/origin/main")
                    )
                )
        )
        #expect(result.target == target)
        #expect(try Data(contentsOf: lockPath) == lockBytes)
    }

    private func createInitialCommit(in repository: URL) async throws {
        try "initial\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["add", "README.md"])
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["commit", "-m", "Initial commit"])
    }
}

private struct WorktreeFetchRepositoryFixture {
    let repository: URL
    let bareRemote: URL
    let updater: URL
    let missingRemote: URL
    let initialCommit: String
    let remoteCommit: String

    var originHeadPath: URL {
        repository.appending(path: ".git/refs/remotes/origin/HEAD")
    }

    var remoteMainLockPath: URL {
        repository.appending(path: ".git/refs/remotes/origin/main.lock")
    }

    static func create() async throws -> Self {
        let repository = try await FilesystemTestGitRepo.create(named: "fetch-origin")
        let baseFolder = repository.deletingLastPathComponent()
        let suffix = UUIDv7.generate().uuidString
        let bareRemote = baseFolder.appending(path: "origin-\(suffix).git")
        let updater = baseFolder.appending(path: "updater-\(suffix)")
        let missingRemote = baseFolder.appending(path: "missing-\(suffix).git")
        do {
            try "initial\n".write(
                to: repository.appending(path: "README.md"),
                atomically: true,
                encoding: .utf8
            )
            try await FilesystemTestGitRepo.runGit(at: repository, args: ["add", "README.md"])
            try await FilesystemTestGitRepo.runGit(at: repository, args: ["commit", "-m", "Initial commit"])
            let initialCommit = try await reference("refs/heads/main", in: repository)

            try await FilesystemTestGitRepo.runGit(at: repository, args: ["init", "--bare", bareRemote.path])
            try await FilesystemTestGitRepo.runGit(at: repository, args: ["remote", "add", "origin", bareRemote.path])
            try await FilesystemTestGitRepo.runGit(
                at: repository,
                args: ["push", "--set-upstream", "origin", "main"]
            )
            try await FilesystemTestGitRepo.runGit(
                at: repository,
                args: ["fetch", "origin", "+refs/heads/main:refs/remotes/origin/main"]
            )
            try await FilesystemTestGitRepo.runGit(
                at: repository,
                args: ["clone", "--branch", "main", bareRemote.path, updater.path]
            )
            try await FilesystemTestGitRepo.runGit(
                at: updater, args: ["config", "user.email", "fetch-tests@example.com"])
            try await FilesystemTestGitRepo.runGit(at: updater, args: ["config", "user.name", "Fetch Tests"])
            try await FilesystemTestGitRepo.runGit(at: updater, args: ["config", "commit.gpgsign", "false"])
            try "remote\n".write(
                to: updater.appending(path: "remote.txt"),
                atomically: true,
                encoding: .utf8
            )
            try await FilesystemTestGitRepo.runGit(at: updater, args: ["add", "remote.txt"])
            try await FilesystemTestGitRepo.runGit(at: updater, args: ["commit", "-m", "Advance remote main"])
            let remoteCommit = try await reference("refs/heads/main", in: updater)
            try await FilesystemTestGitRepo.runGit(at: updater, args: ["push", "origin", "main"])
            try await FilesystemTestGitRepo.runGit(at: updater, args: ["branch", "unrelated"])
            try await FilesystemTestGitRepo.runGit(
                at: updater,
                args: ["push", "origin", "refs/heads/unrelated:refs/heads/unrelated"]
            )
            return Self(
                repository: repository,
                bareRemote: bareRemote,
                updater: updater,
                missingRemote: missingRemote,
                initialCommit: initialCommit,
                remoteCommit: remoteCommit
            )
        } catch {
            FilesystemTestGitRepo.destroy(repository)
            try? FileManager.default.removeItem(at: bareRemote)
            try? FileManager.default.removeItem(at: updater)
            throw error
        }
    }

    func destroy() {
        FilesystemTestGitRepo.destroy(repository)
        try? FileManager.default.removeItem(at: bareRemote)
        try? FileManager.default.removeItem(at: updater)
    }

    func reference(_ name: String) async throws -> String {
        try await Self.reference(name, in: repository)
    }

    func references(under prefix: String) async throws -> [String] {
        let output = try await FilesystemTestGitRepo.runGit(
            at: repository,
            args: ["for-each-ref", "--format=%(refname)", prefix]
        )
        return output.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func reference(_ name: String, in repository: URL) async throws -> String {
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["rev-parse", "--verify", name])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func reference(_ name: String, in repository: URL) async throws -> String {
    try await FilesystemTestGitRepo.runGit(at: repository, args: ["rev-parse", "--verify", name])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
