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
        let initialResolution = await resolver.resolve(repositoryPath: fixture.repository)
        let initialTarget = try #require(initialResolution.target)
        #expect(initialTarget.referenceName == "refs/remotes/origin/main")
        #expect(initialTarget.branchName == "main")
        #expect(initialTarget.commit == fixture.initialCommit)
        #expect(initialTarget.fetchSource == .origin(branchName: "main"))

        let skipped = await step.run(
            repositoryPath: fixture.repository,
            resolution: initialResolution,
            policy: .skip
        )
        #expect(skipped.status == .skipped(reason: .noFetchFlag))
        #expect(skipped.target?.commit == fixture.initialCommit)
        #expect(try await fixture.reference("refs/remotes/origin/main") == fixture.initialCommit)

        let fetched = await step.run(
            repositoryPath: fixture.repository,
            resolution: initialResolution,
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
        let resolution = await resolver.resolve(repositoryPath: repository)
        let target = try #require(resolution.target)

        #expect(target.referenceName == "refs/heads/main")
        #expect(target.fetchSource == .noRemote)
        let result = await step.run(repositoryPath: repository, resolution: resolution, policy: .defaultBranch)
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
        let resolution = await resolver.resolve(repositoryPath: repository)

        guard case .absent = resolution else {
            Issue.record("expected a legitimately absent E4, got \(resolution)")
            return
        }
        let fetching = await step.run(repositoryPath: repository, resolution: resolution, policy: .defaultBranch)
        let skipping = await step.run(repositoryPath: repository, resolution: resolution, policy: .skip)
        #expect(fetching.target == nil)
        #expect(fetching.status == .skipped(reason: .noTarget))
        #expect(skipping.target == nil)
        #expect(skipping.status == .skipped(reason: .noTarget))
    }

    @Test("successful fetch residue stays visible in list and a later read failure")
    func successfulFetchResidueSurvivesListAndReadFailure() async throws {
        let fixture = try await WorktreeFetchRepositoryFixture.create()
        defer { fixture.destroy() }
        let client = LibGit2AgentStudioGitLocalClient()
        let residuePath = fixture.repository.appending(path: ".git/FETCH_HEAD.lock")
        let expectedFetch = fetchStatus(fixture: fixture, residuePath: residuePath)
        let remoteClient = fetchResidueRemoteClient(fixture: fixture, residuePath: residuePath)
        let outcome = await WorktreeOperationRunner(client: client, remoteClient: remoteClient).run(
            .list(
                start: fixture.repository, callerDirectory: fixture.repository, targets: [], fetchPolicy: .defaultBranch
            )
        )
        try expectFetchResidue(outcome, expected: expectedFetch, path: residuePath)

        let mainSnapshot = try #require(
            await client.worktrees(for: fixture.repository).first(where: \.isMainWorktree)
        )
        let identity = try await client.repositoryIdentity(for: fixture.repository)
        let unreadableListClient = WorktreeOperationClientStub(
            startPath: fixture.repository,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: client,
            failsWorktreeListing: true
        )
        let readFailureOutcome = await WorktreeOperationRunner(
            client: unreadableListClient,
            remoteClient: remoteClient
        ).run(
            .list(
                start: fixture.repository, callerDirectory: fixture.repository, targets: [], fetchPolicy: .defaultBranch
            )
        )
        try expectFetchResidue(readFailureOutcome, expected: expectedFetch, path: residuePath)
    }

    @Test("successful fetch residue stays visible in remove, preview and prune")
    func successfulFetchResidueSurvivesRemovalAndPrune() async throws {
        let fixture = try await WorktreeFetchRepositoryFixture.create()
        defer { fixture.destroy() }
        let client = LibGit2AgentStudioGitLocalClient()
        let removalPath = fixture.repository.deletingLastPathComponent()
            .appending(path: "fetch-residue-remove", directoryHint: .isDirectory)
        let previewPath = fixture.repository.deletingLastPathComponent()
            .appending(path: "fetch-residue-preview", directoryHint: .isDirectory)
        let prunePath = fixture.repository.deletingLastPathComponent()
            .appending(path: "fetch-residue-prune", directoryHint: .isDirectory)
        let linkedPaths = [removalPath, previewPath, prunePath]
        defer {
            for path in linkedPaths {
                try? FileManager.default.removeItem(at: path)
            }
        }
        let branchNames = [
            "feature/fetch-residue-remove", "feature/fetch-residue-preview", "feature/fetch-residue-prune",
        ]
        for (branchName, destinationPath) in zip(branchNames, linkedPaths) {
            _ = try await client.createWorktree(
                GitCreateWorktreeRequest(
                    repositoryPath: fixture.repository,
                    destinationPath: destinationPath,
                    mode: .newBranch(name: branchName, startPoint: .named("refs/heads/main"))
                ))
        }

        let residuePath = fixture.repository.appending(path: ".git/FETCH_HEAD.lock")
        let expectedFetch = fetchStatus(fixture: fixture, residuePath: residuePath)
        let runner = WorktreeOperationRunner(
            client: client,
            remoteClient: fetchResidueRemoteClient(fixture: fixture, residuePath: residuePath)
        )
        let previewOutcome = await runner.run(
            .remove(
                worktreeRemovalRequest(
                    repository: fixture.repository,
                    targets: [previewPath.path],
                    callerDirectory: fixture.repository,
                    branchPolicy: .keep,
                    fetchPolicy: .defaultBranch,
                    dryRun: true
                ))
        )
        try expectFetchResidue(previewOutcome, expected: expectedFetch, path: residuePath)

        let removalOutcome = await runner.run(
            .remove(
                worktreeRemovalRequest(
                    repository: fixture.repository,
                    targets: [removalPath.path],
                    callerDirectory: fixture.repository,
                    branchPolicy: .keep,
                    fetchPolicy: .defaultBranch
                ))
        )
        try expectFetchResidue(removalOutcome, expected: expectedFetch, path: residuePath)

        let pruneOutcome = await runner.run(
            .prune(
                WorktreePruneRequest(
                    start: fixture.repository,
                    callerDirectory: fixture.repository,
                    apply: false,
                    evidencePolicy: .requireEmpty,
                    fetchPolicy: .defaultBranch
                ))
        )
        try expectFetchResidue(pruneOutcome, expected: expectedFetch, path: residuePath)
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
        let resolution = await resolver.resolve(repositoryPath: repository)
        let target = try #require(resolution.target)
        let targetCommit = try await reference("refs/remotes/company/main", in: repository)

        #expect(target.referenceName == "refs/remotes/company/main")
        #expect(target.branchName == "main")
        #expect(target.commit == targetCommit)
        #expect(target.fetchSource == .upstreamNotOrigin)
        let result = await step.run(repositoryPath: repository, resolution: resolution, policy: .defaultBranch)
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
        let resolution = await resolver.resolve(repositoryPath: fixture.repository)
        let target = try #require(resolution.target)
        #expect(target.commit == fixture.initialCommit)

        let result = await step.run(repositoryPath: fixture.repository, resolution: resolution, policy: .defaultBranch)
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
        let resolution = await resolver.resolve(repositoryPath: fixture.repository)
        let target = try #require(resolution.target)
        let result = await step.run(repositoryPath: fixture.repository, resolution: resolution, policy: .defaultBranch)

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

    @Test("a successful fetch keeps its status and protects the branch when E4 refresh cannot be read")
    func protectsBranchAfterSuccessfulFetchAndUnreadableRefresh() async throws {
        let fixture = try await WorktreeFetchRepositoryFixture.create()
        defer { fixture.destroy() }
        try await FilesystemTestGitRepo.runGit(at: fixture.repository, args: ["checkout", "--detach"])
        #expect(!FileManager.default.fileExists(atPath: fixture.originHeadPath.path))
        let branchName = "feature/refresh-read-failure"
        let linkedWorktreePath = fixture.repository.deletingLastPathComponent()
            .appending(path: "linked-refresh-read-failure", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: linkedWorktreePath) }
        try await FilesystemTestGitRepo.runGit(
            at: fixture.repository,
            args: ["worktree", "add", "-b", branchName, linkedWorktreePath.path]
        )
        let branchCommitBefore = try await reference("refs/heads/\(branchName)", in: fixture.repository)

        let baseClient = LibGit2AgentStudioGitLocalClient()
        let mainSnapshot = try #require(
            await baseClient.worktrees(for: fixture.repository).first(where: \.isMainWorktree))
        let identity = try await baseClient.repositoryIdentity(for: fixture.repository)
        let defaultTargetFailures = WorktreeDefaultTargetResolutionFailureSchedule(failingReadNumbers: [2])
        let client = WorktreeOperationClientStub(
            startPath: fixture.repository,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: baseClient,
            defaultTargetResolutionFailureSchedule: defaultTargetFailures
        )
        let configPath = fixture.repository.appending(path: ".git/config")
        let reflogPath = fixture.repository.appending(path: ".git/logs/refs/heads/main")
        let configBytesBefore = try Data(contentsOf: configPath)
        let reflogBytesBefore = try Data(contentsOf: reflogPath)

        let report = await WorktreeRemovalRunner(
            client: client,
            remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        ).run(
            worktreeRemovalRequest(
                repository: fixture.repository,
                targets: [linkedWorktreePath.path],
                callerDirectory: fixture.repository,
                branchPolicy: .deleteAtObservedCommit,
                fetchPolicy: .defaultBranch
            )
        )

        guard case .removed(let entry)? = report.entries.first else {
            Issue.record("expected linked worktree removal with its branch retained, got \(report)")
            return
        }
        #expect(report.fetch == .fetched(commit: fixture.remoteCommit))
        #expect(entry.effects.assessment == .unknown(.readFailed))
        #expect(entry.effects.branch?.disposition == .retained)
        #expect(entry.effects.branch?.reason == .defaultBranchUnverified)
        #expect(!FileManager.default.fileExists(atPath: linkedWorktreePath.path))
        #expect(try await reference("refs/heads/\(branchName)", in: fixture.repository) == branchCommitBefore)
        #expect(try await fixture.reference("refs/remotes/origin/main") == fixture.remoteCommit)
        #expect(try Data(contentsOf: configPath) == configBytesBefore)
        #expect(try Data(contentsOf: reflogPath) == reflogBytesBefore)
        #expect(await defaultTargetFailures.observedReadCount() == 2)
    }

    private func createInitialCommit(in repository: URL) async throws {
        try "initial\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["add", "README.md"])
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["commit", "-m", "Initial commit"])
    }
}

private struct WorktreeFetchResidueRemoteClient: AgentStudioGitRemoteClient {
    let result: GitFetchResult

    func clone(_ request: GitCloneRequest) async throws(GitDataPlaneError) -> GitCloneResult {
        throw .unsupported(message: "clone is unused by the fetch residue test")
    }

    func fetch(_ request: GitFetchRequest)
        async throws(GitLockedOperationFailure<GitDataPlaneError>) -> GitFetchResult
    {
        result
    }

    func captureRemoteTrackingSnapshot(_ request: GitRemoteTrackingSnapshotRequest)
        async throws(GitDataPlaneError) -> GitRemoteTrackingSnapshot
    {
        throw .unsupported(message: "remote snapshot is unused by the fetch residue test")
    }

    func stageFetch(_ request: GitStagedFetchRequest) async throws(GitDataPlaneError) -> GitStagedFetchResult {
        throw .unsupported(message: "staged fetch is unused by the fetch residue test")
    }

    func promoteStagedFetch(_ request: GitPromoteStagedFetchRequest)
        async throws(GitDataPlaneError) -> GitPromoteStagedFetchResult
    {
        throw .unsupported(message: "staged fetch promotion is unused by the fetch residue test")
    }

    func cleanupStagedFetch(_ request: GitCleanupStagedFetchRequest)
        async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult
    {
        throw .unsupported(message: "staged fetch cleanup is unused by the fetch residue test")
    }

    func cleanupAbandonedStagedFetches(_ request: GitCleanupAbandonedStagedFetchesRequest)
        async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult
    {
        throw .unsupported(message: "abandoned fetch cleanup is unused by the fetch residue test")
    }

    func push(_ request: GitPushRequest) async throws(GitDataPlaneError) -> GitPushResult {
        throw .unsupported(message: "push is unused by the fetch residue test")
    }

    func remoteReferences(_ request: GitRemoteReferencesRequest) async throws(GitDataPlaneError) -> [GitRemoteReference]
    {
        throw .unsupported(message: "remote reference lookup is unused by the fetch residue test")
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

private func fetchStatus(
    fixture: WorktreeFetchRepositoryFixture,
    residuePath: URL
) -> WorktreeFetchStatus {
    .fetched(
        commit: fixture.initialCommit,
        lockResidue: [residuePath.standardizedFileURL.path]
    )
}

private func fetchResidueRemoteClient(
    fixture: WorktreeFetchRepositoryFixture,
    residuePath: URL
) -> WorktreeFetchResidueRemoteClient {
    WorktreeFetchResidueRemoteClient(
        result: GitFetchResult(
            fetchedRemoteName: "origin",
            fetchedCommit: fixture.initialCommit,
            lockResidue: [residuePath]
        )
    )
}

private func expectFetchResidue(
    _ outcome: WorktreeOperationOutcome,
    expected: WorktreeFetchStatus,
    path: URL
) throws {
    let observedFetch: WorktreeFetchStatus
    switch outcome {
    case .listed(let listing):
        observedFetch = listing.fetch
    case .fetchingReadFailure(let failure):
        observedFetch = failure.fetch
    case .removal(let report):
        observedFetch = report.fetch
    case .pruned(let summary):
        observedFetch = summary.fetch
    case .created, .refused, .failed:
        Issue.record("expected a worktree outcome that carries fetch status, got \(outcome)")
        return
    }

    #expect(observedFetch == expected)
    let json = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
    let human = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
    #expect(json.text.contains(path.standardizedFileURL.path))
    #expect(human.text.contains("leftover lock paths \(path.standardizedFileURL.path)"))
}
