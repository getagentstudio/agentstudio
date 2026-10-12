import AgentStudioWorktreeOperations
import Foundation
import Observation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

/// First interaction of the whole New Worktree path: dispatcher, shell owner,
/// creation coordinator, the Git SDK, the FilesystemActor hold and rescan, and
/// watched-folder discovery into `repositoryTopologyAtom`. Only FSEvents delivery
/// is controlled; scanning, Git, and topology application are production code.
@MainActor
@Suite("Worktree creation end to end", .serialized)
struct WorktreeCreationEndToEndTests {
    @Test("From Default creates at origin/HEAD even when the local worktree has advanced")
    func newWorktreeReachesTopologyThroughDiscovery() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = try await EndToEndFixture.make(destinationFolderName: "repo.feat-end-to-end")
            defer { fixture.remove() }
            try await fixture.seedOriginDefaultAndAdvanceLocalMain()
            let system = EndToEndSystem.make(repoCache: atoms.repoCache)
            do {
                // Act
                let result = try await createThroughDispatcher(
                    kind: .fromDefault, branch: "feat/end-to-end", fixture: fixture, system: system)

                // Assert
                #expect(result.accepted)
                #expect(
                    system.store.repositoryTopologyAtom.repo(containing: result.created.id)?.id == result.sourceRepoId)
                #expect(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "README.md").path))
                #expect(try await git(fixture.destination, "rev-parse", "--abbrev-ref", "HEAD") == "feat/end-to-end")
                #expect(
                    try await git(fixture.destination, "rev-parse", "HEAD")
                        == git(fixture.repositoryPath, "rev-parse", "refs/remotes/origin/main"))
            } catch {
                await system.shutdown()
                throw error
            }
            await system.shutdown()
        }
    }

    @Test("From Branch dispatches through the shell and creates at the selected local reference")
    func selectedLocalBranchReachesTopology() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = try await EndToEndFixture.make(destinationFolderName: "repo.feat-from-branch")
            defer { fixture.remove() }
            try await fixture.seedOriginDefaultAndAdvanceLocalMain()
            _ = try await git(fixture.repositoryPath, "branch", "feature/source", "refs/remotes/origin/main")
            let system = EndToEndSystem.make(repoCache: atoms.repoCache)
            do {
                let result = try await createThroughDispatcher(
                    kind: .fromBranch(referenceName: "refs/heads/feature/source"),
                    branch: "feat/from-branch", fixture: fixture, system: system)

                #expect(result.accepted)
                #expect(
                    system.store.repositoryTopologyAtom.repo(containing: result.created.id)?.id == result.sourceRepoId)
                #expect(try await git(fixture.destination, "rev-parse", "--abbrev-ref", "HEAD") == "feat/from-branch")
                #expect(
                    try await git(fixture.destination, "rev-parse", "HEAD")
                        == git(fixture.repositoryPath, "rev-parse", "refs/heads/feature/source"))
            } catch {
                await system.shutdown()
                throw error
            }
            await system.shutdown()
        }
    }

    @Test("a worktree created under a symlinked watched folder is accepted and published")
    func symlinkedWatchedFolderPublishesCreatedWorktree() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = try await EndToEndFixture.make(
                destinationFolderName: "repo.feat-through-link", watchThroughSymlink: true)
            defer { fixture.remove() }
            let system = EndToEndSystem.make(repoCache: atoms.repoCache)
            do {
                // Act
                let result = try await createThroughDispatcher(
                    kind: .fromDefault, branch: "feat/through-link", fixture: fixture, system: system)

                // Assert
                #expect(result.accepted)
                #expect(
                    system.store.repositoryTopologyAtom.repo(containing: result.created.id)?.id == result.sourceRepoId)
                #expect(try await git(fixture.destination, "rev-parse", "--abbrev-ref", "HEAD") == "feat/through-link")
                #expect(
                    try await git(fixture.destination, "rev-parse", "HEAD")
                        == git(fixture.repositoryPath, "rev-parse", "refs/heads/main"))
            } catch {
                await system.shutdown()
                throw error
            }
            await system.shutdown()
        }
    }

    @Test("Worktree Fork carries modified, staged, untracked, and ignored files into a published fork")
    func worktreeForkCarriesWorkingStateThroughDiscovery() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = try await EndToEndFixture.make(destinationFolderName: "repo.fork-end-to-end")
            defer { fixture.remove() }
            try await fixture.seedWorkingStateAcrossTheStatusMatrix()
            let system = EndToEndSystem.make(repoCache: atoms.repoCache)
            do {
                // Act
                let result = try await createThroughDispatcher(
                    kind: .fork, branch: "fork/end-to-end", fixture: fixture, system: system)

                // Assert
                #expect(result.accepted)
                #expect(
                    system.store.repositoryTopologyAtom.repo(containing: result.created.id)?.id == result.sourceRepoId)
                #expect(try await git(fixture.destination, "rev-parse", "--abbrev-ref", "HEAD") == "fork/end-to-end")
                #expect(
                    try await git(fixture.destination, "rev-parse", "HEAD")
                        == git(fixture.repositoryPath, "rev-parse", "HEAD"))
                let fork = fixture.destination
                #expect(
                    try String(contentsOf: fork.appending(path: "tracked.txt"), encoding: .utf8)
                        == "tracked\nmodified\n")
                #expect(try String(contentsOf: fork.appending(path: "untracked.txt"), encoding: .utf8) == "untracked\n")
                #expect(try String(contentsOf: fork.appending(path: "ignored.log"), encoding: .utf8) == "ignored\n")
                // Staged changes arrive unstaged; untracked stays untracked; ignored stays ignored.
                #expect(
                    try await statusLines(fork)
                        == [" M staged.txt", " M tracked.txt", "?? untracked.txt"])
                #expect(
                    try await statusLines(fixture.repositoryPath)
                        == [" M tracked.txt", "?? untracked.txt", "M  staged.txt"])
            } catch {
                await system.shutdown()
                throw error
            }
            await system.shutdown()
        }
    }
}

private struct CreationThroughDispatcher {
    let accepted: Bool
    let created: Worktree
    let sourceRepoId: UUID
}

/// Discovers the fixture repository, then dispatches one creation through the real
/// dispatcher and shell owner and awaits its publication in topology.
@MainActor
private func createThroughDispatcher(
    kind: WorktreeCreationKind,
    branch: String,
    fixture: EndToEndFixture,
    system: EndToEndSystem
) async throws -> CreationThroughDispatcher {
    await system.cacheCoordinator.startConsuming()
    let watchedPath = try #require(system.store.mutationCoordinator.addWatchedPath(fixture.watchedRoot))
    _ = await system.pipeline.refreshWatchedFolders([watchedPath])
    let source = await awaitTopology(system.store) { mainWorktree(in: system.store, fixture: fixture) }
    let delegate = AppDelegate()
    delegate.store = system.store
    delegate.installWorktreeCreationCoordinator(publication: system.pipeline)
    let request = WorktreeCreationRequest(
        kind: kind,
        targetId: kind == .fork ? source.id : source.repoId,
        branchName: try WorktreeBranchName.validated(branch).get()
    )

    let accepted = try await withCommandDispatcherFixture(
        configure: { configuration in configuration.shellOwner = delegate },
        body: { dispatcher in dispatcher.dispatchWorktreeCreation(request) }
    )
    await delegate.worktreeCreationCoordinator?.waitUntilIdle()
    // A creation the coordinator refused would otherwise leave the topology wait below
    // with nothing to wake it.
    try #require(FileManager.default.fileExists(atPath: fixture.destination.path), "creation produced no worktree")
    let created = await awaitTopology(system.store) { linkedWorktree(in: system.store, fixture: fixture) }
    return CreationThroughDispatcher(accepted: accepted, created: created, sourceRepoId: source.repoId)
}

private func git(_ directory: URL, _ args: String...) async throws -> String {
    try await FilesystemTestGitRepo.runGit(at: directory, args: args)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Porcelain status lines in byte order, so a leading space sorts before `??` and `M`.
private func statusLines(_ directory: URL) async throws -> [String] {
    try await FilesystemTestGitRepo.runGit(at: directory, args: ["status", "--porcelain=v1"])
        .split(separator: "\n").map(String.init).sorted()
}

@MainActor
private func mainWorktree(in store: WorkspaceStore, fixture: EndToEndFixture) -> Worktree? {
    store.repositoryTopologyAtom.repos.flatMap(\.worktrees).first {
        canonicalPath($0.path) == canonicalPath(fixture.repositoryPath)
    }
}

@MainActor
private func linkedWorktree(in store: WorkspaceStore, fixture: EndToEndFixture) -> Worktree? {
    store.repositoryTopologyAtom.repos.flatMap(\.worktrees).first {
        canonicalPath($0.path) == canonicalPath(fixture.destination)
            && !store.repositoryTopologyAtom.isWorktreeUnavailable($0.id)
    }
}

/// Awaits observed topology changes until the predicate holds. Each wake is a
/// topology mutation, never a scheduler turn or a clock.
@MainActor
private func awaitTopology<TObservation: Sendable>(
    _ store: WorkspaceStore,
    until observe: @escaping @MainActor () -> TObservation?
) async -> TObservation {
    while true {
        let (changes, changeContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = withObservationTracking {
            _ = store.repositoryTopologyAtom.repos
            return observe()
        } onChange: {
            changeContinuation.yield()
        }
        if let observation {
            changeContinuation.finish()
            return observation
        }
        var changeIterator = changes.makeAsyncIterator()
        _ = await changeIterator.next()
        changeContinuation.finish()
    }
}

/// Canonical path text resolved the way discovery resolves it (through symlinks); URL
/// equality would also compare a trailing slash that `URL(fileURLWithPath:)` adds only
/// once the directory exists.
private func canonicalPath(_ url: URL) -> String {
    FilesystemRootOwnership.canonicalizeKernelPath(RepoScanner.canonicalURL(url).path)
}

@MainActor
private struct EndToEndSystem {
    let store: WorkspaceStore
    let pipeline: FilesystemGitPipeline
    let cacheCoordinator: WorkspaceCacheCoordinator

    static func make(repoCache: RepoCacheAtom) -> Self {
        let bus = EventBus<RuntimeEnvelope>()
        let store = WorkspaceStore()
        let pipeline = FilesystemGitPipeline(
            bus: bus,
            gitWorkingTreeProvider: .stub { _ in nil },
            forgeStatusProvider: .stub { _ in .complete([]) },
            fseventStreamClient: ControllableFSEventStreamClient(),
            watchedFolderScanScheduler: .production(deadlineScheduler: InertWorktreeCreationDiscoveryDeadline()),
            gitCoalescingWindow: .zero,
            gitRefreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let cacheCoordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: store,
            repoCache: repoCache,
            // Mirrors production boot: observations and retention refreshes are
            // validated against the same pipeline that produced them.
            refreshRetentionScopes: { [weak pipeline] paths, repositories, revision, scopeIDs in
                guard let pipeline else { return [] }
                return await pipeline.refreshForRepositoryRetention(
                    watchedPaths: paths, repositories: repositories, membershipRevision: revision, scanning: scopeIDs
                )
            },
            validateSourceObservations: { [weak pipeline] observations in
                guard let pipeline else { return false }
                return await pipeline.areCurrentWatchedFolderObservations(observations)
            },
            scopeSyncHandler: { [weak pipeline] scopeChange in
                await pipeline?.applyScopeChange(scopeChange)
            },
            enrichmentApplyTickCadence: .zero
        )
        return Self(store: store, pipeline: pipeline, cacheCoordinator: cacheCoordinator)
    }

    func shutdown() async {
        await cacheCoordinator.shutdown()
        await pipeline.shutdown()
    }
}

/// Real scanning and Git discovery without a machine-load-dependent admission deadline.
private struct InertWorktreeCreationDiscoveryDeadline: RepoDiscoveryDeadlineScheduler {
    func scheduleDeadline(
        after duration: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> RepoDiscoveryScheduledDeadline {
        RepoDiscoveryScheduledDeadline(cancel: {})
    }
}

private struct EndToEndFixture {
    let fixtureRoot: URL
    let watchedRoot: URL
    let repositoryPath: URL
    let destination: URL

    /// With `watchThroughSymlink`, the watched folder is a symlink to the folder that
    /// actually holds the repository, as when a user watches a linked projects folder.
    static func make(destinationFolderName: String, watchThroughSymlink: Bool = false) async throws -> Self {
        let fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "tmp/worktree-creation-e2e-tests/\(UUIDv7.generate().uuidString)")
            .standardizedFileURL
        let realRoot = fixtureRoot.appending(path: "watched")
        let repositoryPath = realRoot.appending(path: "repo")
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        try "# fixture\n".write(to: repositoryPath.appending(path: "README.md"), atomically: true, encoding: .utf8)
        for args in [
            ["init"], ["symbolic-ref", "HEAD", "refs/heads/main"],
            ["config", "user.email", "luna-tests@example.com"], ["config", "user.name", "Luna Tests"],
            ["config", "commit.gpgsign", "false"], ["add", "README.md"], ["commit", "-m", "Initial commit"],
        ] {
            try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: args)
        }
        let watchedRoot: URL
        if watchThroughSymlink {
            watchedRoot = fixtureRoot.appending(path: "watched-link")
            try FileManager.default.createSymbolicLink(at: watchedRoot, withDestinationURL: realRoot)
        } else {
            watchedRoot = realRoot
        }
        return Self(
            fixtureRoot: fixtureRoot,
            watchedRoot: watchedRoot,
            repositoryPath: repositoryPath,
            destination: realRoot.appending(path: destinationFolderName)
        )
    }

    func seedOriginDefaultAndAdvanceLocalMain() async throws {
        let originPath = fixtureRoot.appending(path: "origin.git")
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["init", "--bare", originPath.path])
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["remote", "add", "origin", originPath.path])
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["push", "--set-upstream", "origin", "main"])
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["remote", "set-head", "origin", "main"])
        try "local advance\n".write(
            to: repositoryPath.appending(path: "local-only.txt"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["add", "local-only.txt"])
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["commit", "-m", "Local advance"])
    }

    /// One file per cell of the fork status matrix: modified, staged, untracked, ignored.
    func seedWorkingStateAcrossTheStatusMatrix() async throws {
        try "tracked\n".write(to: repositoryPath.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try "staged\n".write(to: repositoryPath.appending(path: "staged.txt"), atomically: true, encoding: .utf8)
        try "ignored.log\n".write(to: repositoryPath.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        for args in [["add", "tracked.txt", "staged.txt", ".gitignore"], ["commit", "-m", "Track files"]] {
            try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: args)
        }
        try "tracked\nmodified\n".write(
            to: repositoryPath.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try "staged\nchanged\n".write(
            to: repositoryPath.appending(path: "staged.txt"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["add", "staged.txt"])
        try "untracked\n".write(to: repositoryPath.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: repositoryPath.appending(path: "ignored.log"), atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }
}
