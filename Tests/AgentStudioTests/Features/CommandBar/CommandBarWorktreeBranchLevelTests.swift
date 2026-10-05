import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@testable import AgentStudioCommandBar

@MainActor
@Suite("Command Bar worktree branch level", .serialized)
struct CommandBarWorktreeBranchLevelTests {
    @Test("reopening From a branch requests a new listing in the same command-bar session")
    func reopensBranchListingForANewLevelVisit() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology)
            let repositoryPath = URL(filePath: "/tmp/branch-opening-\(UUIDv7.generate().uuidString)/repo")
            let repository = store.addRepo(at: repositoryPath)
            let currentRepository = try #require(store.repositoryTopologyAtom.repo(repository.id))
            let repoCache = RepoCacheAtom()
            let listing = SequencedBranchListing()
            let defaultStartPoint = WorktreeDefaultStartPoint.resolved(
                displayRef: "main", startPoint: "refs/heads/main")
            let controller = CommandBarPanelController(
                store: store,
                octiconLoader: makeCommandBarTestOcticonLoader(),
                repoCache: repoCache,
                dispatcher: FakeAppCommandDispatcher(),
                quickOpenDirectoryHandler: { _, _ in },
                commandBarSurface: CommandBarSurfaceAtom(),
                recentsDefaults: CommandBarRecentsDefaultsFixture().makeDefaults(),
                branchListing: listing)
            controller.state.show(prefix: ">")
            controller.state.recordDefaultStartPoint(defaultStartPoint, forRepositoryId: repository.id)

            let branchLevel = CommandBarDataSource.worktreeCreationMenuLevel(
                repository: currentRepository,
                store: store,
                repoCache: repoCache,
                defaultStartPoint: defaultStartPoint)
            controller.state.pushLevel(branchLevel)
            controller.requestCreationQueriesIfNeeded(for: branchLevel)
            #expect(await listing.awaitQueries(count: 1) == 1)
            let firstOpeningTask = try #require(controller.branchListingQueriesByRepositoryId[repository.id]?.task)
            await listing.answer(at: 0, with: ["branch-before-reopen"])
            await firstOpeningTask.value

            let rootSessionGeneration = controller.state.rootSessionGeneration
            let firstOpeningLevel = try #require(controller.state.currentLevel)
            #expect(controller.state.branchNamesByRepositoryId[repository.id] == ["branch-before-reopen"])

            controller.state.popLevel()
            controller.state.pushLevel(firstOpeningLevel)
            controller.requestCreationQueriesIfNeeded(for: firstOpeningLevel)
            let secondOpeningTask = controller.branchListingQueriesByRepositoryId[repository.id]?.task
            #expect(secondOpeningTask != nil)
            if let secondOpeningTask {
                #expect(await listing.awaitQueries(count: 2) == 2)
                await listing.answer(at: 1, with: ["branch-after-reopen"])
                await secondOpeningTask.value
            }

            #expect(controller.state.rootSessionGeneration == rootSessionGeneration)
            #expect(controller.state.branchNamesByRepositoryId[repository.id] == ["branch-after-reopen"])
        }
    }

    @Test("a branch listing arriving after typing refreshes real search results")
    func lateBranchListingRefreshesSearch() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology)
            let repositoryPath = URL(filePath: "/tmp/branch-search-\(UUIDv7.generate().uuidString)/repo")
            let repository = store.addRepo(at: repositoryPath)
            let currentRepository = try #require(store.repositoryTopologyAtom.repo(repository.id))
            let repoCache = RepoCacheAtom()
            let listing = SequencedBranchListing()
            let controller = CommandBarPanelController(
                store: store,
                octiconLoader: makeCommandBarTestOcticonLoader(),
                repoCache: repoCache,
                dispatcher: FakeAppCommandDispatcher(),
                quickOpenDirectoryHandler: { _, _ in },
                commandBarSurface: CommandBarSurfaceAtom(),
                recentsDefaults: CommandBarRecentsDefaultsFixture().makeDefaults(),
                branchListing: listing)
            controller.state.show(prefix: ">")
            controller.state.pushLevel(
                CommandBarDataSource.worktreeCreationMenuLevel(
                    repository: currentRepository, store: store, repoCache: repoCache))
            controller.requestCreationQueriesIfNeeded(for: try #require(controller.state.currentLevel))
            #expect(await listing.awaitQueries(count: 1) == 1)
            let listingTask = try #require(controller.branchListingQueriesByRepositoryId[repository.id]?.task)

            controller.state.rawInput = "feature/source"
            controller.queryChanged(text: controller.state.rawInput)
            let initialSearch = try #require(controller.pendingSearchTask)
            await initialSearch.value
            #expect(
                controller.state.appliedSearchResult?.displayedItems.contains {
                    $0.title == "feature/source"
                } == false)

            await listing.answer(at: 0, with: ["feature/source"])
            await listingTask.value
            let refreshedSearch = try #require(controller.pendingSearchTask)
            await refreshedSearch.value
            #expect(
                controller.state.appliedSearchResult?.displayedItems.contains {
                    $0.title == "feature/source"
                } == true)
        }
    }

    @Test("worktree search and fork rows show a known branch beneath the name")
    func knownBranchSecondaryLine() throws {
        try withTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology)
            let repositoryPath = URL(filePath: "/tmp/branch-line-\(UUIDv7.generate().uuidString)/repo")
            let repository = store.addRepo(at: repositoryPath)
            let mainWorktree = Worktree(
                id: UUIDv7.generate(), repoId: repository.id, name: "repo", path: repositoryPath,
                isMainWorktree: true)
            let branchWorktree = Worktree(
                id: UUIDv7.generate(), repoId: repository.id, name: "topic",
                path: repositoryPath.deletingLastPathComponent().appending(path: "topic"))
            store.reconcileDiscoveredWorktrees(repository.id, worktrees: [mainWorktree, branchWorktree])
            let currentRepository = try #require(store.repositoryTopologyAtom.repo(repository.id))
            let currentMain = try #require(currentRepository.worktrees.first { $0.isMainWorktree })
            let repoCache = RepoCacheAtom()
            repoCache.setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: branchWorktree.id, repoId: repository.id, branch: "feature/topic"))
            let branchIcon = AppCommand.newWorktreeFromBranch.definition.icon

            let searchRows = CommandBarDataSource.searchableRepositoryAndWorktreeItems(
                store: store, repoCache: repoCache, repositoryGroup: "Repos",
                repositoryPriority: 0, worktreePriority: 1)
            let branchSearchRow = try #require(
                searchRows.first {
                    $0.id == "repo-wt-\(branchWorktree.id.uuidString)"
                })
            let mainSearchRow = try #require(
                searchRows.first {
                    $0.id == "repo-wt-\(currentMain.id.uuidString)"
                })
            #expect(branchSearchRow.secondaryLine == .init(text: "feature/topic", icon: branchIcon))
            #expect(branchSearchRow.subtitle == repository.name)
            #expect(mainSearchRow.secondaryLine == nil)

            let menu = CommandBarDataSource.worktreeCreationMenuLevel(
                repository: currentRepository, store: store, repoCache: repoCache,
                eligibilityByWorktreeId: [currentMain.id: .available, branchWorktree.id: .available])
            let branchForkRow = try #require(
                menu.items.first {
                    $0.id == "newWorktree-fork-source-\(branchWorktree.id.uuidString)"
                })
            let mainForkRow = try #require(
                menu.items.first {
                    $0.id == "newWorktree-fork-source-\(currentMain.id.uuidString)"
                })
            #expect(branchForkRow.secondaryLine == .init(text: "feature/topic", icon: branchIcon))
            #expect(branchForkRow.subtitle == repository.name)
            #expect(mainForkRow.secondaryLine == nil)
        }
    }

    @Test("fork sources are inline and recent branches exclude default, deduplicate, and cap at five")
    func inlineForksAndRecentBranches() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology)
            let repositoryPath = URL(filePath: "/tmp/branch-level-\(UUIDv7.generate().uuidString)/repo")
            let repository = store.addRepo(at: repositoryPath)
            let mainWorktree = Worktree(
                id: UUIDv7.generate(), repoId: repository.id, name: "repo", path: repositoryPath,
                isMainWorktree: true)
            let featureWorktrees = (1...7).map { number in
                Worktree(
                    id: UUIDv7.generate(), repoId: repository.id, name: "feature-\(number)",
                    path: repositoryPath.deletingLastPathComponent().appending(path: "feature-\(number)"),
                    isMainWorktree: false)
            }
            store.reconcileDiscoveredWorktrees(repository.id, worktrees: [mainWorktree] + featureWorktrees)
            let currentRepository = try #require(store.repositoryTopologyAtom.repo(repository.id))
            let repoCache = RepoCacheAtom()
            repoCache.setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: mainWorktree.id, repoId: repository.id, branch: "main"))
            for (offset, worktree) in featureWorktrees.enumerated() {
                repoCache.setWorktreeEnrichment(
                    WorktreeEnrichment(
                        worktreeId: worktree.id, repoId: repository.id, branch: "feature-\(offset + 1)"))
                try coreAtoms.applicationEntityRecency.recordOpened(
                    repositoryStableKey: currentRepository.stableKey,
                    worktreeStableKey: worktree.stableKey,
                    at: Date().addingTimeInterval(Double(offset - 10)))
            }
            let available = Dictionary(
                uniqueKeysWithValues: currentRepository.worktrees.map { ($0.id, WorktreeForkEligibility.available) })
            let level = CommandBarDataSource.worktreeCreationMenuLevel(
                repository: currentRepository,
                store: store,
                repoCache: repoCache,
                defaultStartPoint: .resolved(displayRef: "origin/main", startPoint: "refs/remotes/origin/main"),
                branchNames: ["main", "other"] + (1...7).map { "feature-\($0)" },
                eligibilityByWorktreeId: available,
                focusedWorktreeId: featureWorktrees[6].id)

            let forks = level.items.filter { $0.group == "FORK A WORKTREE" }
            let branches = level.items.filter { $0.group == "FROM A BRANCH" }
            #expect(forks.map(\.title) == ["feature-7", "repo"] + (1...6).map { "feature-\($0)" })
            #expect(
                branches.map(\.title) == [
                    "From Default", "feature-7", "feature-6", "feature-5", "feature-4", "feature-3",
                ])
            #expect(level.searchOnlyItems.map(\.title) == ["other", "feature-1", "feature-2"])
            #expect(forks.allSatisfy { $0.isEnabled })
            guard case .navigate(let forkNameLevel) = forks[0].action,
                case .navigate(let branchNameLevel) = branches[1].action
            else {
                Issue.record("Expected direct name-entry levels")
                return
            }
            #expect(forkNameLevel.textEntry != nil)
            #expect(branchNameLevel.title == "From feature-7")
            let row = try #require(branchNameLevel.textEntry?.rowsForInput(.init(text: "new-feature")).first)
            guard case .createWorktree(let draft) = row.action else {
                Issue.record("Expected a typed branch creation row")
                return
            }
            let branchName = try WorktreeBranchName.validated("new-feature").get()
            #expect(
                CommandBarWorktreeCreationResolver.resolve(draft: draft)
                    == .dispatch(
                        .init(
                            kind: .fromBranch(referenceName: "refs/heads/feature-7"),
                            targetId: repository.id, branchName: branchName)))

            let state = CommandBarState()
            state.show(prefix: ">")
            state.pushLevel(level)
            let resultSession = CommandBarResultSession(
                store: store, repoCache: repoCache, dispatcher: FakeAppCommandDispatcher())
            let emptyDocuments = resultSession.prepareSearch(state: state).documentSet
            #expect(!emptyDocuments.documents.contains { $0.title == "other" })
            state.rawInput = "other"
            let searchable = resultSession.prepareSearch(state: state).documentSet
            let found = await SearchService().search(
                SearchRequest(
                    sequence: SearchRequestSequence(1), text: "other", recentItemIds: [],
                    documentSet: searchable))
            #expect(searchable.generation > emptyDocuments.generation)
            #expect(
                found.groups.flatMap(\.matches).contains {
                    $0.itemId.rawValue == "newWorktree-from-branch-\(repository.id.uuidString)-other"
                })
        }
    }
}
