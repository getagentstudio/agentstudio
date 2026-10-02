import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct FilesystemToPrimarySidebarIntegrationTests {
    @Test("filesystem-to-primary-sidebar pipeline converges project-dev-shaped grouping and PR enrichment")
    func filesystemToPrimarySidebarPipelineConverges() async throws {
        installTestCoreAtomsIfNeeded()

        let fixtureRoot = try await makeProjectDevShapeFixture()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let discoveredRepoPaths = await RepoScanner().scanForGitRepos(in: fixtureRoot, maxDepth: 4)
        assertScannerOutput(discoveredRepoPaths: discoveredRepoPaths, fixtureRoot: fixtureRoot)

        let financeRemote = "git@github.com:askluna/askluna-finance.git"
        let statusByRootPath = makeStatusByRootPath(root: fixtureRoot, financeRemote: financeRemote)
        let testSystem = try makeIntegratedTestSystem(statusByRootPath: statusByRootPath)
        try await withStartedIntegratedTestSystem(testSystem) {
            let intake = await registerDiscoveredRepos(
                discoveredRepoPaths: discoveredRepoPaths,
                workspaceStore: testSystem.workspaceStore,
                pipeline: testSystem.pipeline,
                statusByRootPath: statusByRootPath,
                financeRemote: financeRemote
            )
            await assertCanonicalTopology(
                workspaceStore: testSystem.workspaceStore,
                pipeline: testSystem.pipeline
            )
            await publishFinanceRepositoryFactDemand(
                intake: intake,
                workspaceStore: testSystem.workspaceStore,
                pipeline: testSystem.pipeline
            )

            try #require(!intake.financeRepoIds.isEmpty)
            for repoId in intake.financeRepoIds {
                try await testSystem.applications.expectApplied(repositoryID: repoId, kind: .repositoryIdentity) {
                    guard case .resolvedRemote(_, _, let identity, _) = $0.repository else { return false }
                    return identity.groupKey == "remote:askluna/askluna-finance"
                }
                guard case .resolvedRemote(_, _, let identity, _) = testSystem.repoCache.repoEnrichment(for: repoId)
                else {
                    Issue.record("Expected resolved finance repository identity")
                    continue
                }
                #expect(identity.groupKey == "remote:askluna/askluna-finance")
            }

            for (branch, count) in [("master", 1), ("transaction-table-3", 2), ("rlvr-forking", 3)] {
                let worktreeId = try #require(intake.financeWorktreeIdByBranch[branch])
                let repoId = try #require(
                    testSystem.workspaceStore.repos.first {
                        $0.worktrees.contains { $0.id == worktreeId }
                    }?.id)
                let key = try #require(RepoBranchKey(repoId: repoId, branch: branch))
                try await testSystem.applications.expectApplied(
                    repositoryID: repoId, kind: .worktreeEnrichment, worktreeID: worktreeId
                ) { $0.worktree?.branch == branch }
                try await testSystem.applications.expectApplied(repositoryID: repoId, kind: .repositoryProjection) {
                    $0.pullRequests[key]?.openCount == count && !$0.isLoading
                }
                #expect(testSystem.repoCache.pullRequestFactsForTest(worktreeId: worktreeId)?.openCount == count)
            }

            let sidebarRepos = testSystem.workspaceStore.repos.map { repo in
                RepoPresentationItem(
                    repo: repo,
                    stableKey: repo.stableKey,
                    worktreeStableKeysByID: Dictionary(
                        uniqueKeysWithValues: repo.worktrees.map { ($0.id, $0.stableKey) }
                    )
                )
            }
            let metadataByRepoId = RepoExplorerView.buildRepoMetadata(
                repos: sidebarRepos,
                repoEnrichmentByRepoId: testSystem.repoCache.repoEnrichmentByRepoId
            )
            let groups = RepoPresentationGrouping.buildGroups(
                repos: sidebarRepos,
                metadataByRepoId: metadataByRepoId
            )

            let financeGroup = groups.first { $0.id == "remote:askluna/askluna-finance" }
            #expect(financeGroup != nil)
            #expect((financeGroup?.repos.count ?? 0) >= 3)

            // Branch labels should be sourced from enrichment/canonical branch data, not detached fallback.
            if let financeGroup {
                let allFinanceWorktrees = financeGroup.repos.flatMap(\.worktrees)
                let visibleBranchLabels = allFinanceWorktrees.map {
                    atom(\.paneDisplay).resolvedBranchName(
                        worktree: $0,
                        enrichment: testSystem.repoCache.worktreeEnrichmentByWorktreeId[$0.id]
                    )
                }
                #expect(visibleBranchLabels.contains("master"))
                #expect(visibleBranchLabels.contains("transaction-table-3"))
                #expect(visibleBranchLabels.contains("rlvr-forking"))
            }

            // Search model should still find grouped finance checkouts.
            let filtered = RepoExplorerFilter.filter(repos: sidebarRepos, query: "rlvr")
            #expect(!filtered.isEmpty)
        }
    }

    private struct IntegratedTestSystem {
        let bus: EventBus<RuntimeEnvelope>
        let workspaceStore: WorkspaceStore
        let repoCache: RepoCacheAtom
        let coordinator: WorkspaceCacheCoordinator
        let pipeline: FilesystemGitPipeline
        let applications: WorkspaceCacheApplicationRecorder
    }

    private struct FinanceIntake {
        let financeRepoIds: [UUID]
        let financeWorktreeIdByBranch: [String: UUID]
    }

    private func makeIntegratedTestSystem(
        statusByRootPath: [String: GitWorkingTreeStatus]
    ) throws -> IntegratedTestSystem {
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = makeWorkspaceStore()
        let repoCache = RepoCacheAtom()
        let applications = try WorkspaceCacheApplicationRecorder(cache: repoCache)
        let pipeline = FilesystemGitPipeline(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider.stub { rootPath in
                statusByRootPath[rootPath.standardizedFileURL.path]
                    ?? GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                        branch: "main",
                        origin: nil
                    )
            },
            forgeStatusProvider: StubForgeStatusProvider.stub { _ in
                .complete([
                    ForgePullRequest(
                        headRefName: "master",
                        url: URL(string: "https://github.com/acme/studio/pull/1")!
                    ),
                    ForgePullRequest(
                        headRefName: "transaction-table-3",
                        url: URL(string: "https://github.com/acme/studio/pull/2")!
                    ),
                    ForgePullRequest(
                        headRefName: "transaction-table-3",
                        url: URL(string: "https://github.com/acme/studio/pull/3")!
                    ),
                    ForgePullRequest(
                        headRefName: "rlvr-forking",
                        url: URL(string: "https://github.com/acme/studio/pull/4")!
                    ),
                    ForgePullRequest(
                        headRefName: "rlvr-forking",
                        url: URL(string: "https://github.com/acme/studio/pull/5")!
                    ),
                    ForgePullRequest(
                        headRefName: "rlvr-forking",
                        url: URL(string: "https://github.com/acme/studio/pull/6")!
                    ),
                ])
            },
            gitCoalescingWindow: .zero,
            gitRefreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { [weak pipeline] scopeChange in
                guard let pipeline else { return }
                await pipeline.applyScopeChange(scopeChange)
            },
            enrichmentApplyTickCadence: .zero,
            factSink: applications.sink
        )
        return IntegratedTestSystem(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            coordinator: coordinator,
            pipeline: pipeline,
            applications: applications
        )
    }

    private func registerDiscoveredRepos(
        discoveredRepoPaths: [URL],
        workspaceStore: WorkspaceStore,
        pipeline: FilesystemGitPipeline,
        statusByRootPath: [String: GitWorkingTreeStatus],
        financeRemote: String
    ) async -> FinanceIntake {
        var financeRepoIds: [UUID] = []
        var financeWorktreeIdByBranch: [String: UUID] = [:]

        for discoveredPath in discoveredRepoPaths {
            let repo = workspaceStore.addRepo(at: discoveredPath)
            guard let worktree = repo.worktrees.first else { continue }
            if statusByRootPath[discoveredPath.standardizedFileURL.path]?.origin == financeRemote {
                financeRepoIds.append(repo.id)
                if let branch = statusByRootPath[discoveredPath.standardizedFileURL.path]?.branch {
                    financeWorktreeIdByBranch[branch] = worktree.id
                }
            }
            await pipeline.register(
                worktreeId: worktree.id,
                repoId: repo.id,
                rootPath: discoveredPath
            )
        }

        return FinanceIntake(
            financeRepoIds: financeRepoIds,
            financeWorktreeIdByBranch: financeWorktreeIdByBranch
        )
    }

    private func assertCanonicalTopology(
        workspaceStore: WorkspaceStore,
        pipeline: FilesystemGitPipeline
    ) async {
        let topology = workspaceStore.repositoryTopologyAtom
        let canonicalRepositories = topology.repos
        await pipeline.assertTopology(
            FilesystemTopologyAssertion(
                generation: topology.worktreePathIndexGeneration,
                contextsByWorktreeId: Dictionary(
                    uniqueKeysWithValues: canonicalRepositories.flatMap { repository in
                        repository.worktrees.map { worktree in
                            (
                                worktree.id,
                                WorktreeFilesystemContext(repoId: repository.id, rootPath: worktree.path)
                            )
                        }
                    }
                ),
                repositoryStableKeysByWorktreeId: Dictionary(
                    uniqueKeysWithValues: canonicalRepositories.flatMap { repository in
                        repository.worktrees.map { worktree in
                            (worktree.id, repository.stableKey)
                        }
                    }
                ),
                repositoryLifetimes: topology.repositoryObservationLifetimes,
                worktreeLifetimes: topology.worktreeObservationLifetimes
            )
        )
    }

    private func publishFinanceRepositoryFactDemand(
        intake: FinanceIntake,
        workspaceStore: WorkspaceStore,
        pipeline: FilesystemGitPipeline
    ) async {
        let demandedWorktreeIds = Set(intake.financeWorktreeIdByBranch.values)
        let repositoryIdByWorktreeId = Dictionary(
            uniqueKeysWithValues: workspaceStore.repos.flatMap { repository in
                repository.worktrees.compactMap { worktree in
                    demandedWorktreeIds.contains(worktree.id)
                        ? (worktree.id, repository.id)
                        : nil
                }
            }
        )
        await pipeline.setRepositoryFactDemand(
            RepositoryFactDemandSnapshot(
                activePaneWorktreeId: nil,
                sidebarAttendedWorktreeIds: demandedWorktreeIds,
                visibleActiveTabWorktreeIds: [],
                openWorktreeIds: demandedWorktreeIds,
                repositoryIdByWorktreeId: repositoryIdByWorktreeId,
                warmRepositoryIds: Set(repositoryIdByWorktreeId.values),
                unknownRepositoryIds: [],
                locallyInactiveRepositoryIds: [],
                warmAutomaticWorktreeIds: Set(repositoryIdByWorktreeId.keys),
                unknownWorktreeIds: [],
                backgroundOnlyAutomaticWorktreeIds: [],
                locallyInactiveWorktreeIds: []
            )
        )
    }

    private func assertScannerOutput(discoveredRepoPaths: [URL], fixtureRoot: URL) {
        let discoveredPathSet = Set(discoveredRepoPaths.map { $0.standardizedFileURL.path })
        #expect(!discoveredPathSet.contains(fixtureRoot.appending(path: "-worktrees").path))
        #expect(!discoveredPathSet.contains(fixtureRoot.appending(path: "agent-studio.window-system").path))
        #expect(
            discoveredPathSet.contains(fixtureRoot.appending(path: "askluna-project/askluna-finance").path))
        #expect(
            discoveredPathSet.contains(
                fixtureRoot.appending(path: "-worktrees/askluna-finance/rlvr-forking").path))
        #expect(
            discoveredPathSet.contains(
                fixtureRoot.appending(path: "-worktrees/askluna-finance/transaction-table-3").path))
    }

    private func makeWorkspaceStore() -> WorkspaceStore {
        WorkspaceStore()
    }

    private func makeProjectDevShapeFixture() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "project-dev-shape-e2e-\(UUIDv7.generate().uuidString)")
        let fm = FileManager.default

        let repoPaths = [
            "-worktrees/askluna-finance/transaction-table-3",
            "-worktrees/askluna-finance/rlvr-forking",
            "askluna-project/askluna-finance",
            "askluna-project/askluna",
            "askluna-project/askluna-agent-design",
        ]

        for path in repoPaths {
            try await initializeGitRepository(at: root.appending(path: path))
        }

        // Real-world stale worktree path shape: has a `.git` marker but is not a valid worktree.
        let invalidWorktreePath = root.appending(path: "agent-studio.window-system")
        try fm.createDirectory(at: invalidWorktreePath, withIntermediateDirectories: true)
        try "gitdir: /tmp/non-existent/.git/worktrees/agent-studio.window-system\n".write(
            to: invalidWorktreePath.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )

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

    private func makeStatusByRootPath(
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
            root.appending(path: "askluna-project/askluna-finance").standardizedFileURL.path:
                status(branch: "master", origin: financeRemote),
            root.appending(path: "-worktrees/askluna-finance/transaction-table-3").standardizedFileURL.path:
                status(branch: "transaction-table-3", origin: financeRemote),
            root.appending(path: "-worktrees/askluna-finance/rlvr-forking").standardizedFileURL.path:
                status(branch: "rlvr-forking", origin: financeRemote),
            root.appending(path: "askluna-project/askluna").standardizedFileURL.path:
                status(branch: "main", origin: "git@github.com:askluna/askluna.git"),
            root.appending(path: "askluna-project/askluna-agent-design").standardizedFileURL.path:
                status(branch: "main", origin: "git@github.com:askluna/askluna-agent-design.git"),
        ]
    }

    private func withStartedIntegratedTestSystem(
        _ testSystem: IntegratedTestSystem,
        operation: @MainActor () async throws -> Void
    ) async throws {
        await testSystem.pipeline.start()
        await testSystem.coordinator.startConsuming()
        do {
            try await operation()
            await testSystem.pipeline.shutdown()
            await testSystem.coordinator.shutdown()
            #expect(await testSystem.bus.subscriberCount == 0)
            try await testSystem.applications.finish()
        } catch {
            await testSystem.pipeline.shutdown()
            await testSystem.coordinator.shutdown()
            try? await testSystem.applications.finish()
            throw error
        }
    }
}
