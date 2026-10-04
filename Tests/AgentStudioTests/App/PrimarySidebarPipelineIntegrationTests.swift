import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite("PrimarySidebarPipeline")
struct PrimarySidebarPipelineIntegrationTests {
    @Test("filesystem -> git -> forge -> cache converges for two repos sharing one remote identity")
    func twoReposWithSharedRemoteIdentityConverge() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = makeWorkspaceStore()
        let repoCache = RepoCacheAtom()
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let (forgeActor, coordinator, projector) = makePipelineActors(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            applications: applications
        )

        try await withStartedPipelineActors(
            bus: bus,
            coordinator: coordinator,
            applications: applications,
            projector: projector,
            forgeActor: forgeActor
        ) {
            let repoA = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/pipeline-repo-a"))
            let repoB = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/pipeline-repo-b"))
            guard let worktreeA = repoA.worktrees.first?.id,
                let worktreeB = repoB.worktrees.first?.id
            else {
                Issue.record("Expected each repository to have its primary worktree")
                return
            }
            let topologyAssertion = await assertCanonicalProducerTopology(
                workspaceStore: workspaceStore,
                projector: projector,
                forgeActor: forgeActor
            )
            guard let worktreeALifetime = topologyAssertion.worktreeLifetimes[worktreeA],
                let worktreeBLifetime = topologyAssertion.worktreeLifetimes[worktreeB]
            else {
                Issue.record("Expected canonical observation lifetimes for both primary worktrees")
                return
            }
            await registerForgeWorktree(worktreeA, repository: repoA, forgeActor: forgeActor)
            await registerForgeWorktree(worktreeB, repository: repoB, forgeActor: forgeActor)
            await attendRepositoryFacts(
                worktreeIds: [worktreeA, worktreeB],
                activePaneWorktreeId: worktreeA,
                projector: projector
            )
            await forgeActor.setDemand(worktreeIds: [worktreeA, worktreeB])
            await postWorktreeRegistered(bus: bus, worktreeId: worktreeA, repoId: repoA.id, rootPath: repoA.repoPath)
            await postWorktreeRegistered(bus: bus, worktreeId: worktreeB, repoId: repoB.id, rootPath: repoB.repoPath)

            await postBranchChanged(
                bus: bus,
                worktreeId: worktreeA,
                repoId: repoA.id,
                from: "seed",
                to: "main",
                observationLifetime: worktreeALifetime
            )
            await postBranchChanged(
                bus: bus,
                worktreeId: worktreeB,
                repoId: repoB.id,
                from: "seed",
                to: "main",
                observationLifetime: worktreeBLifetime
            )

            for (repoId, worktreeId) in [(repoA.id, worktreeA), (repoB.id, worktreeB)] {
                try await applications.expectApplied(repositoryID: repoId, kind: .repositoryIdentity) {
                    guard case .resolvedRemote(_, _, let identity, _) = $0.repository else { return false }
                    return identity.groupKey == "remote:askluna/agent-studio"
                }
                try await applications.expectApplied(
                    repositoryID: repoId, kind: .worktreeEnrichment, worktreeID: worktreeId
                ) { $0.worktree?.branch == "main" }
                let key = try #require(RepoBranchKey(repoId: repoId, branch: "main"))
                try await applications.expectApplied(repositoryID: repoId, kind: .repositoryProjection) {
                    $0.pullRequests[key]?.openCount == 1 && !$0.isLoading
                }
                #expect(repoCache.pullRequestFactsForTest(worktreeId: worktreeId)?.openCount == 1)
            }
            guard case .resolvedRemote(_, _, let identityA, _) = repoCache.repoEnrichment(for: repoA.id),
                case .resolvedRemote(_, _, let identityB, _) = repoCache.repoEnrichment(for: repoB.id)
            else {
                Issue.record("Expected resolved identities for both repositories")
                return
            }
            #expect(identityA.groupKey == "remote:askluna/agent-studio")
            #expect(identityA.groupKey == identityB.groupKey)

        }
    }

    @Test("message-driven repo discovery seeds unresolved enrichment before origin resolves")
    func messageDrivenRepoDiscoverySeedsUnresolvedBeforeResolution() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = makeWorkspaceStore()
        let repoCache = RepoCacheAtom()
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let (forgeActor, coordinator, projector) = makePipelineActors(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            applications: applications
        )

        try await withStartedPipelineActors(
            bus: bus,
            coordinator: coordinator,
            applications: applications,
            projector: projector,
            forgeActor: forgeActor
        ) {
            let repoPath = URL(fileURLWithPath: "/tmp/pipeline-discovered-\(UUIDv7.generate().uuidString)")
            await postRepoDiscovered(bus: bus, repoPath: repoPath)

            let seeded = try await applications.expectApplied(kind: .repositoryIdentity) {
                if case .awaitingOrigin = $0.repository { return true }
                return false
            }
            let discoveredRepoId = try #require(seeded.repository?.repoId)
            #expect(repoCache.repoEnrichment(for: discoveredRepoId) == .awaitingOrigin(repoId: discoveredRepoId))

            guard let repo = workspaceStore.repos.first(where: { $0.repoPath == repoPath }),
                let worktreeId = repo.worktrees.first?.id
            else {
                Issue.record("Expected discovered repo with a main worktree")
                return
            }

            await assertCanonicalProducerTopology(
                workspaceStore: workspaceStore,
                projector: projector,
                forgeActor: forgeActor
            )

            await attendRepositoryFacts(
                worktreeIds: [worktreeId],
                activePaneWorktreeId: worktreeId,
                projector: projector
            )

            await postWorktreeRegistered(
                bus: bus,
                worktreeId: worktreeId,
                repoId: repo.id,
                rootPath: repoPath
            )

            let resolved = try await applications.expectApplied(repositoryID: repo.id, kind: .repositoryIdentity) {
                guard case .resolvedRemote(_, let raw, let identity, _) = $0.repository else { return false }
                return raw.origin == "git@github.com:askluna/agent-studio.git"
                    && identity.groupKey == "remote:askluna/agent-studio"
            }
            guard case .resolvedRemote(_, let raw, let identity, _) = resolved.repository
            else {
                Issue.record("Expected resolved repository identity")
                return
            }
            #expect(raw.origin == "git@github.com:askluna/agent-studio.git")
            #expect(identity.groupKey == "remote:askluna/agent-studio")

        }
    }

    @Test("message-driven origin and branch events trigger one admitted repository refresh")
    func messageDrivenOriginAndBranchEventsTriggerOneAdmittedRefresh() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = makeWorkspaceStore()
        let repoCache = RepoCacheAtom()
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let callCounter = ForgeProviderCallCounter()
        let forgeActor = ForgeActor(
            bus: bus,
            statusProvider: .stub { _ in
                await callCounter.increment()
                return .complete([
                    ForgePullRequest(
                        headRefName: "main",
                        url: URL(string: "https://github.com/askluna/agent-studio/pull/1")!
                    )
                ])
            },
            providerName: "stub",
            monotonicNow: { .zero }
        )
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { change in
                switch change {
                case .registerForgeRepo(let repoId, let remote, let expectedLifetime):
                    let currentLifetime = await workspaceStore.repositoryTopologyAtom.repositoryObservationLifetimes[
                        repoId]
                    guard expectedLifetime == currentLifetime else { return }
                    await forgeActor.setOrigin(repo: repoId, remote: remote)
                case .unregisterForgeRepo(let repoId, let expectedLifetime):
                    await forgeActor.removeRepository(repo: repoId, expectedLifetime: expectedLifetime)
                case .refreshForgeRepo(let repoId, let correlationId):
                    await forgeActor.refresh(repo: repoId, correlationId: correlationId)
                case .updateWatchedFolders, .updateRepositoryScanBaseline:
                    break
                }
            },
            enrichmentApplyTickCadence: .zero,
            factSink: applications.sink
        )

        try await withStartedForgeScopeCoordinator(
            bus: bus, coordinator: coordinator, applications: applications, forgeActor: forgeActor
        ) {
            let repo = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/pipeline-forge-dedupe"))
            guard let worktreeId = repo.worktrees.first?.id,
                let observationLifetime = workspaceStore.repositoryTopologyAtom.worktreeObservationLifetimes[
                    worktreeId]
            else {
                Issue.record("Expected canonical worktree and observation lifetime")
                return
            }
            await forgeActor.assertObservationLifetimes(
                makeCanonicalTopologyAssertion(workspaceStore: workspaceStore)
            )
            await forgeActor.register(
                worktreeId: worktreeId,
                repoId: repo.id,
                rootPath: repo.repoPath
            )
            await forgeActor.setDemand(worktreeIds: [worktreeId])
            await postOriginChanged(
                bus: bus,
                repoId: repo.id,
                worktreeId: worktreeId,
                from: "",
                to: "git@github.com:askluna/agent-studio.git",
                observationLifetime: observationLifetime
            )
            await postBranchChanged(
                bus: bus,
                worktreeId: worktreeId,
                repoId: repo.id,
                from: "seed",
                to: "main",
                observationLifetime: observationLifetime
            )

            let key = try #require(RepoBranchKey(repoId: repo.id, branch: "main"))
            try await applications.expectApplied(repositoryID: repo.id, kind: .repositoryProjection) {
                $0.pullRequests[key]?.openCount == 1 && !$0.isLoading
            }
            #expect(await callCounter.value() == 1)

        }

        #expect(await callCounter.value() == 1)
    }

    @Test("origin change updates resolved identity grouping")
    func originChangeUpdatesResolvedIdentityGrouping() {
        let workspaceStore = makeWorkspaceStore()
        let repoCache = RepoCacheAtom()
        let coordinator = WorkspaceCacheCoordinator(
            bus: EventBus<RuntimeEnvelope>(),
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { _ in }
        )

        let repo = workspaceStore.addRepo(at: URL(fileURLWithPath: "/tmp/pipeline-origin-change"))
        guard let worktreeId = repo.worktrees.first?.id,
            let observationLifetime = workspaceStore.repositoryTopologyAtom.worktreeObservationLifetimes[worktreeId]
        else {
            Issue.record("Expected canonical worktree and observation lifetime")
            return
        }

        coordinator.handleEnrichment(
            WorktreeEnvelope.test(
                event: .gitWorkingDirectory(
                    .originChanged(repoId: repo.id, from: "", to: "git@github.com:org-a/repo.git")
                ),
                repoId: repo.id,
                worktreeId: worktreeId,
                source: .system(.builtin(.gitWorkingDirectoryProjector)),
                observationLifetime: .worktree(observationLifetime)
            )
        )
        coordinator.handleEnrichment(
            WorktreeEnvelope.test(
                event: .gitWorkingDirectory(
                    .originChanged(
                        repoId: repo.id,
                        from: "git@github.com:org-a/repo.git",
                        to: "git@github.com:org-b/repo.git"
                    )
                ),
                repoId: repo.id,
                worktreeId: worktreeId,
                source: .system(.builtin(.gitWorkingDirectoryProjector)),
                observationLifetime: .worktree(observationLifetime)
            )
        )

        guard case .some(.resolvedRemote(_, _, let identity, _)) = repoCache.repoEnrichmentByRepoId[repo.id] else {
            Issue.record("Expected resolved enrichment")
            return
        }
        #expect(identity.groupKey == "remote:org-b/repo")
        #expect(identity.organizationName == "org-b")
    }

    @Test("project-dev shape converges remote grouping and PR enrichment across sibling checkouts")
    func projectDevShapeConvergesGroupingAndPullRequestCounts() async throws {
        let tempRoot = try await makeProjectDevShapeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let discoveredRepoPaths = await RepoScanner().scanForGitRepos(in: tempRoot, maxDepth: 4)
        let discoveredPathSet = Set(discoveredRepoPaths.map(canonicalPath(_:)))

        #expect(discoveredPathSet.contains(canonicalPath(tempRoot.appending(path: "askluna-project/askluna-finance"))))
        #expect(
            discoveredPathSet.contains(
                canonicalPath(tempRoot.appending(path: "-worktrees/askluna-finance/transaction-table-3"))
            )
        )
        #expect(
            discoveredPathSet.contains(
                canonicalPath(tempRoot.appending(path: "-worktrees/askluna-finance/rlvr-forking"))
            )
        )
        #expect(!discoveredPathSet.contains(canonicalPath(tempRoot.appending(path: "-worktrees"))))

        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = makeWorkspaceStore()
        let repoCache = RepoCacheAtom()
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let financeRemote = "git@github.com:askluna/askluna-finance.git"
        let pathStatusByRootPath = makePathStatusByRootPath(
            root: tempRoot,
            financeRemote: financeRemote
        )

        let (forgeActor, coordinator, projector) = makePipelineActors(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            applications: applications,
            gitStatusByRootPath: pathStatusByRootPath
        )

        try await withStartedPipelineActors(
            bus: bus,
            coordinator: coordinator,
            applications: applications,
            projector: projector,
            forgeActor: forgeActor
        ) {
            let fixture = await prepareProjectDevPipelineFixture(
                inputs: ProjectDevPipelineFixtureInputs(
                    discoveredRepoPaths: discoveredRepoPaths,
                    pathStatusByRootPath: pathStatusByRootPath,
                    financeRemote: financeRemote,
                    workspaceStore: workspaceStore,
                    bus: bus,
                    projector: projector,
                    forgeActor: forgeActor
                )
            )

            try #require(!fixture.financeRepositoryIDs.isEmpty)
            var financeGroupKeys: Set<String> = []
            for repoId in fixture.financeRepositoryIDs {
                let applied = try await applications.expectApplied(repositoryID: repoId, kind: .repositoryIdentity) {
                    guard case .resolvedRemote(_, _, let identity, _) = $0.repository else { return false }
                    return identity.groupKey == "remote:askluna/askluna-finance"
                }
                if case .resolvedRemote(_, _, let identity, _) = applied.repository {
                    financeGroupKeys.insert(identity.groupKey)
                }
            }
            #expect(financeGroupKeys == ["remote:askluna/askluna-finance"])

            let primaryBranchId = try #require(fixture.financeWorktreeIDByBranch["master"])
            let transactionTableId = try #require(fixture.financeWorktreeIDByBranch["transaction-table-3"])
            let rlvrForkingId = try #require(fixture.financeWorktreeIDByBranch["rlvr-forking"])
            let expectedOpenCounts = [1, 2, 3]
            for (worktreeId, branch, count) in [
                (primaryBranchId, "master", 1), (transactionTableId, "transaction-table-3", 2),
                (rlvrForkingId, "rlvr-forking", 3),
            ] {
                let repoId = try #require(
                    workspaceStore.repos.first { $0.worktrees.contains { $0.id == worktreeId } }?.id)
                let key = try #require(RepoBranchKey(repoId: repoId, branch: branch))
                try await applications.expectApplied(
                    repositoryID: repoId, kind: .worktreeEnrichment, worktreeID: worktreeId
                ) {
                    $0.worktree?.branch == branch
                }
                try await applications.expectApplied(repositoryID: repoId, kind: .repositoryProjection) {
                    $0.pullRequests[key]?.openCount == count && !$0.isLoading
                }
            }
            let financeOpenCounts = [primaryBranchId, transactionTableId, rlvrForkingId].compactMap {
                repoCache.pullRequestFactsForTest(worktreeId: $0)?.openCount
            }
            #expect(financeOpenCounts == expectedOpenCounts)

            let sidebarRepos = makeRepoPresentationItems(repositories: workspaceStore.repos)
            let metadata = RepoExplorerView.buildRepoMetadata(
                repos: sidebarRepos,
                repoEnrichmentByRepoId: repoCache.repoEnrichmentByRepoId
            )
            let groups = RepoPresentationGrouping.buildGroups(
                repos: sidebarRepos,
                metadataByRepoId: metadata
            )
            let financeGroup = groups.first { $0.id == "remote:askluna/askluna-finance" }
            #expect(financeGroup != nil)
            #expect((financeGroup?.repos.count ?? 0) >= 3)
        }
    }

    private func makeRepoPresentationItems(repositories: [Repo]) -> [RepoPresentationItem] {
        repositories.map { repo in
            RepoPresentationItem(
                repo: repo,
                stableKey: repo.stableKey,
                worktreeStableKeysByID: Dictionary(
                    uniqueKeysWithValues: repo.worktrees.map { ($0.id, $0.stableKey) }
                )
            )
        }
    }

    private func attendRepositoryFacts(
        worktreeIds: Set<UUID>,
        activePaneWorktreeId: UUID? = nil,
        projector: GitWorkingDirectoryProjector
    ) async {
        await projector.setRepositoryFactAttention(
            activePaneWorktreeId: activePaneWorktreeId,
            sidebarAttendedWorktreeIds: worktreeIds,
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: worktreeIds,
            backgroundOnlyAutomaticWorktreeIds: []
        )
    }

    private func registerForgeWorktree(
        _ worktreeId: UUID,
        repository: Repo,
        forgeActor: ForgeActor
    ) async {
        await forgeActor.register(
            worktreeId: worktreeId,
            repoId: repository.id,
            rootPath: repository.repoPath
        )
    }

    private func makeCanonicalTopologyAssertion(
        workspaceStore: WorkspaceStore
    ) -> FilesystemTopologyAssertion {
        let topology = workspaceStore.repositoryTopologyAtom
        return FilesystemTopologyAssertion(
            generation: topology.worktreePathIndexGeneration,
            contextsByWorktreeId: Dictionary(
                uniqueKeysWithValues: topology.repos.flatMap { repository in
                    repository.worktrees.map { worktree in
                        (
                            worktree.id,
                            WorktreeFilesystemContext(repoId: repository.id, rootPath: worktree.path)
                        )
                    }
                }
            ),
            repositoryLifetimes: topology.repositoryObservationLifetimes,
            worktreeLifetimes: topology.worktreeObservationLifetimes
        )
    }

    @discardableResult
    private func assertCanonicalProducerTopology(
        workspaceStore: WorkspaceStore,
        projector: GitWorkingDirectoryProjector,
        forgeActor: ForgeActor
    ) async -> FilesystemTopologyAssertion {
        let assertion = makeCanonicalTopologyAssertion(workspaceStore: workspaceStore)
        await projector.assertTopology(assertion)
        await forgeActor.assertObservationLifetimes(assertion)
        return assertion
    }

    private func makeWorkspaceStore() -> WorkspaceStore {
        WorkspaceStore()
    }

    private func makePipelineActors(
        bus: EventBus<RuntimeEnvelope>,
        workspaceStore: WorkspaceStore,
        repoCache: RepoCacheAtom,
        applications: WorkspaceCacheApplicationRecorder,
        gitStatusByRootPath: [String: GitWorkingTreeStatus]? = nil
    ) -> (ForgeActor, WorkspaceCacheCoordinator, GitWorkingDirectoryProjector) {
        let forgeActor = ForgeActor(
            bus: bus,
            statusProvider: .stub { _ in
                .complete([
                    ForgePullRequest(
                        headRefName: "main",
                        url: URL(string: "https://github.com/askluna/agent-studio/pull/1")!
                    ),
                    ForgePullRequest(
                        headRefName: "master",
                        url: URL(string: "https://github.com/askluna/askluna-finance/pull/1")!
                    ),
                    ForgePullRequest(
                        headRefName: "transaction-table-3",
                        url: URL(string: "https://github.com/askluna/askluna-finance/pull/2")!
                    ),
                    ForgePullRequest(
                        headRefName: "transaction-table-3",
                        url: URL(string: "https://github.com/askluna/askluna-finance/pull/3")!
                    ),
                    ForgePullRequest(
                        headRefName: "rlvr-forking",
                        url: URL(string: "https://github.com/askluna/askluna-finance/pull/4")!
                    ),
                    ForgePullRequest(
                        headRefName: "rlvr-forking",
                        url: URL(string: "https://github.com/askluna/askluna-finance/pull/5")!
                    ),
                    ForgePullRequest(
                        headRefName: "rlvr-forking",
                        url: URL(string: "https://github.com/askluna/askluna-finance/pull/6")!
                    ),
                ])
            },
            providerName: "stub",
            monotonicNow: { .zero }
        )
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { change in
                switch change {
                case .registerForgeRepo(let repoId, let remote, let expectedLifetime):
                    let currentLifetime = await workspaceStore.repositoryTopologyAtom.repositoryObservationLifetimes[
                        repoId]
                    guard expectedLifetime == currentLifetime else { return }
                    await forgeActor.setOrigin(repo: repoId, remote: remote)
                case .unregisterForgeRepo(let repoId, let expectedLifetime):
                    await forgeActor.removeRepository(repo: repoId, expectedLifetime: expectedLifetime)
                case .refreshForgeRepo(let repoId, let correlationId):
                    await forgeActor.refresh(repo: repoId, correlationId: correlationId)
                case .updateWatchedFolders, .updateRepositoryScanBaseline:
                    break
                }
            },
            enrichmentApplyTickCadence: .zero,
            factSink: applications.sink
        )
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: .stub { rootPath in
                if let gitStatusByRootPath {
                    return gitStatusByRootPath[rootPath.standardizedFileURL.path]
                }
                return GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    origin: "git@github.com:askluna/agent-studio.git"
                )
            },
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )

        return (forgeActor, coordinator, projector)
    }

    private func makeProjectDevShapeFixture() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "project-dev-shape-\(UUIDv7.generate().uuidString)")

        let repoPaths = [
            "-worktrees/askluna-finance/transaction-table-3",
            "-worktrees/askluna-finance/rlvr-forking",
            "askluna-project/askluna-finance",
            "askluna-project/askluna",
        ]

        for path in repoPaths {
            try await initializeGitRepository(at: root.appending(path: path))
        }

        return root
    }

    private func initializeGitRepository(at path: URL) async throws {
        let git = try await TestToolResolver.resolved().git
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let exitCode = try await withoutBlockingCooperativePool {
            let process = Process()
            process.executableURL = git
            process.arguments = ["-C", path.path, "init"]
            try TestToolResolver.launch(process)
            process.waitUntilExit()
            TestToolResolver.recordFailedExit(process)
            return process.terminationStatus
        }
        #expect(exitCode == 0)
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func makePathStatusByRootPath(
        root: URL,
        financeRemote: String
    ) -> [String: GitWorkingTreeStatus] {
        func status(branch: String, origin: String) -> GitWorkingTreeStatus {
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: branch,
                origin: origin
            )
        }

        return [
            root.appending(path: "-worktrees/askluna-finance/transaction-table-3").standardizedFileURL.path:
                status(branch: "transaction-table-3", origin: financeRemote),
            root.appending(path: "-worktrees/askluna-finance/rlvr-forking").standardizedFileURL.path:
                status(branch: "rlvr-forking", origin: financeRemote),
            root.appending(path: "askluna-project/askluna-finance").standardizedFileURL.path:
                status(branch: "master", origin: financeRemote),
            root.appending(path: "askluna-project/askluna").standardizedFileURL.path:
                status(branch: "main", origin: "git@github.com:askluna/askluna.git"),
        ]
    }

    private func postWorktreeRegistered(
        bus: EventBus<RuntimeEnvelope>,
        worktreeId: UUID,
        repoId: UUID,
        rootPath: URL
    ) async {
        _ = await bus.post(
            .system(
                SystemEnvelope.test(
                    event: .topology(
                        .worktreeRegistered(
                            worktreeId: worktreeId,
                            repoId: repoId,
                            rootPath: rootPath
                        )
                    ),
                    source: .builtin(.filesystemWatcher)
                )
            )
        )
    }

    private func postRepoDiscovered(
        bus: EventBus<RuntimeEnvelope>,
        repoPath: URL
    ) async {
        _ = await bus.post(
            .system(
                SystemEnvelope.test(
                    event: .topology(
                        .repoDiscovered(
                            repoPath: repoPath,
                            parentPath: repoPath.deletingLastPathComponent()
                        )
                    ),
                    source: .builtin(.filesystemWatcher)
                )
            )
        )
    }

    private func postBranchChanged(
        bus: EventBus<RuntimeEnvelope>,
        worktreeId: UUID,
        repoId: UUID,
        from: String,
        to: String,
        observationLifetime: WorktreeObservationLifetime
    ) async {
        _ = await bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .branchChanged(
                            worktreeId: worktreeId,
                            repoId: repoId,
                            from: from,
                            to: to
                        )
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector)),
                    observationLifetime: .worktree(observationLifetime)
                )
            )
        )
    }

    private func postOriginChanged(
        bus: EventBus<RuntimeEnvelope>,
        repoId: UUID,
        worktreeId: UUID,
        from: String,
        to: String,
        observationLifetime: WorktreeObservationLifetime
    ) async {
        _ = await bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .originChanged(repoId: repoId, from: from, to: to)
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector)),
                    observationLifetime: .worktree(observationLifetime)
                )
            )
        )
    }

    private func withStartedPipelineActors(
        bus: EventBus<RuntimeEnvelope>,
        coordinator: WorkspaceCacheCoordinator,
        applications: WorkspaceCacheApplicationRecorder,
        projector: GitWorkingDirectoryProjector,
        forgeActor: ForgeActor,
        operation: @MainActor () async throws -> Void
    ) async throws {
        await coordinator.startConsuming()
        await projector.start()
        await forgeActor.start()
        do {
            try await operation()
            await projector.shutdown()
            await forgeActor.shutdown()
            await coordinator.shutdown()
            #expect(await bus.subscriberCount == 0)
            try await applications.finish()
        } catch {
            await projector.shutdown()
            await forgeActor.shutdown()
            await coordinator.shutdown()
            try? await applications.finish()
            throw error
        }
    }

    private func withStartedForgeScopeCoordinator(
        bus: EventBus<RuntimeEnvelope>,
        coordinator: WorkspaceCacheCoordinator,
        applications: WorkspaceCacheApplicationRecorder,
        forgeActor: ForgeActor,
        operation: @MainActor () async throws -> Void
    ) async throws {
        await coordinator.startConsuming()
        await forgeActor.start()
        do {
            try await operation()
            await forgeActor.shutdown()
            await coordinator.shutdown()
            #expect(await bus.subscriberCount == 0)
            try await applications.finish()
        } catch {
            await forgeActor.shutdown()
            await coordinator.shutdown()
            try? await applications.finish()
            throw error
        }
    }
}

extension PrimarySidebarPipelineIntegrationTests {
    fileprivate struct ProjectDevPipelineFixtureInputs {
        let discoveredRepoPaths: [URL]
        let pathStatusByRootPath: [String: GitWorkingTreeStatus]
        let financeRemote: String
        let workspaceStore: WorkspaceStore
        let bus: EventBus<RuntimeEnvelope>
        let projector: GitWorkingDirectoryProjector
        let forgeActor: ForgeActor
    }

    fileprivate struct ProjectDevPipelineFixture {
        let financeWorktreeIDByBranch: [String: UUID]
        let financeRepositoryIDs: [UUID]
    }

    fileprivate func prepareProjectDevPipelineFixture(
        inputs: ProjectDevPipelineFixtureInputs
    ) async -> ProjectDevPipelineFixture {
        var financeWorktreeIDByBranch: [String: UUID] = [:]
        var financeRepositoryIDs: [UUID] = []
        var registeredWorktreeIDs: Set<UUID> = []
        var registrations: [(repository: Repo, worktree: Worktree, rootPath: URL)] = []
        for repoPath in inputs.discoveredRepoPaths {
            let repository = inputs.workspaceStore.addRepo(at: repoPath)
            guard let worktree = repository.worktrees.first else { continue }
            let normalizedPath = repoPath.standardizedFileURL.path
            if inputs.pathStatusByRootPath[normalizedPath]?.origin == inputs.financeRemote {
                financeRepositoryIDs.append(repository.id)
                if let branch = inputs.pathStatusByRootPath[normalizedPath]?.branch {
                    financeWorktreeIDByBranch[branch] = worktree.id
                }
            }
            registrations.append((repository: repository, worktree: worktree, rootPath: repoPath))
            registeredWorktreeIDs.insert(worktree.id)
        }
        await assertCanonicalProducerTopology(
            workspaceStore: inputs.workspaceStore,
            projector: inputs.projector,
            forgeActor: inputs.forgeActor
        )
        for registration in registrations {
            await inputs.forgeActor.register(
                worktreeId: registration.worktree.id,
                repoId: registration.repository.id,
                rootPath: registration.rootPath
            )
            await postWorktreeRegistered(
                bus: inputs.bus,
                worktreeId: registration.worktree.id,
                repoId: registration.repository.id,
                rootPath: registration.rootPath
            )
        }
        await attendRepositoryFacts(worktreeIds: registeredWorktreeIDs, projector: inputs.projector)
        await inputs.forgeActor.setDemand(worktreeIds: registeredWorktreeIDs)
        return ProjectDevPipelineFixture(
            financeWorktreeIDByBranch: financeWorktreeIDByBranch,
            financeRepositoryIDs: financeRepositoryIDs
        )
    }
}

private actor ForgeProviderCallCounter {
    private var calls = 0

    func increment() {
        calls += 1
    }

    func value() -> Int {
        calls
    }
}
