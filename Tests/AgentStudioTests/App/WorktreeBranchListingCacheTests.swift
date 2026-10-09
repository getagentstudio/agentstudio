import AgentStudioCore
import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCommandBar

@Suite("Worktree branch listing cache")
struct WorktreeBranchListingCacheTests {
    @Test("the first repository query loads local branches and a repeated opening reuses them")
    func reusesListingForSameOpening() async throws {
        let query = BranchListingQueryProbe()
        let cache = WorktreeBranchListingCache(query: { path in try await query.branches(for: path) })
        let repositoryId = UUIDv7.generate()
        let repositoryPath = URL(filePath: "/tmp/branch-list-cache-repo")
        let openingToken = UUIDv7.generate()

        let first = try await cache.branchNames(
            forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: openingToken)
        let second = try await cache.branchNames(
            forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: openingToken)

        #expect(first == ["main", "feature/source"])
        #expect(second == first)
        #expect(await query.requestedPaths == [repositoryPath])
    }

    @Test("a new opening reloads only that repository's entry")
    func newOpeningReloadsOnlyItsRepository() async throws {
        let query = BranchListingQueryProbe()
        let cache = WorktreeBranchListingCache(query: { path in try await query.branches(for: path) })
        let firstRepositoryId = UUIDv7.generate()
        let secondRepositoryId = UUIDv7.generate()
        let firstPath = URL(filePath: "/tmp/branch-list-first")
        let secondPath = URL(filePath: "/tmp/branch-list-second")
        let firstOpening = UUIDv7.generate()
        let secondRepositoryOpening = UUIDv7.generate()
        let nextFirstRepositoryOpening = UUIDv7.generate()

        _ = try await cache.branchNames(
            forRepositoryId: firstRepositoryId, repositoryPath: firstPath, openingToken: firstOpening)
        _ = try await cache.branchNames(
            forRepositoryId: secondRepositoryId, repositoryPath: secondPath, openingToken: secondRepositoryOpening)
        _ = try await cache.branchNames(
            forRepositoryId: firstRepositoryId, repositoryPath: firstPath, openingToken: nextFirstRepositoryOpening)
        _ = try await cache.branchNames(
            forRepositoryId: secondRepositoryId, repositoryPath: secondPath, openingToken: secondRepositoryOpening)

        #expect(await query.requestedPaths == [firstPath, secondPath, firstPath])
    }

    @Test("concurrent requests in one opening share the in-flight read")
    func concurrentRequestsShareAnOpeningRead() async throws {
        let openingToken = UUIDv7.generate()
        let repositoryId = UUIDv7.generate()
        let repositoryPath = URL(filePath: "/tmp/branch-list-concurrent")
        let queryGate = HeldStep<Void>("branch names read for one opening")
        let query = HeldBranchListingQueryProbe(
            gates: [queryGate],
            results: [
                [
                    GitBranchSnapshot(name: "main", isCurrent: true, upstreamName: nil),
                    GitBranchSnapshot(name: "feature/source", isCurrent: false, upstreamName: nil),
                ]
            ])
        let cache = WorktreeBranchListingCache(query: { path in try await query.branches(for: path) })

        let firstRequest = Task {
            try await cache.branchNames(
                forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: openingToken)
        }
        _ = try await queryGate.firstArrival()
        let secondRequest = Task {
            try await cache.branchNames(
                forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: openingToken)
        }
        queryGate.release()

        let firstNames = try await firstRequest.value
        let secondNames = try await secondRequest.value
        #expect(firstNames == ["main", "feature/source"])
        #expect(secondNames == firstNames)
        #expect(await query.requestedPaths == [repositoryPath])
    }

    @Test("a stale opening cannot replace a newer opening's cached result")
    func staleOpeningCannotReplaceNewerListing() async throws {
        let repositoryId = UUIDv7.generate()
        let repositoryPath = URL(filePath: "/tmp/branch-list-stale-opening")
        let staleOpening = UUIDv7.generate()
        let currentOpening = UUIDv7.generate()
        let staleQueryGate = HeldStep<Void>("stale branch-list query")
        let currentQueryGate = HeldStep<Void>("current branch-list query")
        let query = HeldBranchListingQueryProbe(
            gates: [staleQueryGate, currentQueryGate],
            results: [
                [GitBranchSnapshot(name: "old", isCurrent: false, upstreamName: nil)],
                [GitBranchSnapshot(name: "new", isCurrent: false, upstreamName: nil)],
            ])
        let cache = WorktreeBranchListingCache(query: { path in try await query.branches(for: path) })

        let staleRequest = Task {
            try await cache.branchNames(
                forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: staleOpening)
        }
        _ = try await staleQueryGate.firstArrival()
        let currentRequest = Task {
            try await cache.branchNames(
                forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: currentOpening)
        }
        _ = try await currentQueryGate.firstArrival()
        currentQueryGate.release()
        let currentNames = try await currentRequest.value
        staleQueryGate.release()
        let staleNames = try await staleRequest.value
        let cachedCurrentNames = try await cache.branchNames(
            forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: currentOpening)

        #expect(currentNames == ["new"])
        #expect(staleNames == ["old"])
        #expect(cachedCurrentNames == currentNames)
        #expect(await query.requestedPaths == [repositoryPath, repositoryPath])
    }

    @Test("a failed listing does not poison the cache")
    func failedListingMayRetry() async throws {
        let query = BranchListingQueryProbe(failFirstQuery: true)
        let cache = WorktreeBranchListingCache(query: { path in try await query.branches(for: path) })
        let repositoryId = UUIDv7.generate()
        let repositoryPath = URL(filePath: "/tmp/branch-list-retry")
        let openingToken = UUIDv7.generate()

        await #expect(throws: BranchListingQueryError.self) {
            _ = try await cache.branchNames(
                forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: openingToken)
        }
        let recovered = try await cache.branchNames(
            forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: openingToken)
        let reused = try await cache.branchNames(
            forRepositoryId: repositoryId, repositoryPath: repositoryPath, openingToken: openingToken)

        #expect(recovered == ["main", "feature/source"])
        #expect(reused == recovered)
        #expect(await query.requestedPaths == [repositoryPath, repositoryPath])
    }
}

private enum BranchListingQueryError: Error {
    case unavailable
    case unexpectedRequest
}

private actor BranchListingQueryProbe {
    private(set) var requestedPaths: [URL] = []
    private var failFirstQuery: Bool

    init(failFirstQuery: Bool = false) {
        self.failFirstQuery = failFirstQuery
    }

    func branches(for path: URL) throws -> [GitBranchSnapshot] {
        requestedPaths.append(path)
        if failFirstQuery {
            failFirstQuery = false
            throw BranchListingQueryError.unavailable
        }
        return [
            GitBranchSnapshot(name: "main", isCurrent: true, upstreamName: nil),
            GitBranchSnapshot(name: "feature/source", isCurrent: false, upstreamName: nil),
        ]
    }
}

private actor HeldBranchListingQueryProbe {
    private let gates: [HeldStep<Void>]
    private let results: [[GitBranchSnapshot]]
    private var nextQueryIndex = 0
    private(set) var requestedPaths: [URL] = []

    init(gates: [HeldStep<Void>], results: [[GitBranchSnapshot]]) {
        self.gates = gates
        self.results = results
    }

    func branches(for path: URL) async throws -> [GitBranchSnapshot] {
        let queryIndex = nextQueryIndex
        nextQueryIndex += 1
        requestedPaths.append(path)
        guard gates.indices.contains(queryIndex), results.indices.contains(queryIndex) else {
            throw BranchListingQueryError.unexpectedRequest
        }
        try await gates[queryIndex].arrive(())
        return results[queryIndex]
    }
}

@MainActor
@Suite("Worktree branch-list opening", .serialized)
struct WorktreeBranchListingOpeningIntegrationTests {
    @Test("reopening From a branch reads created, deleted, renamed, and packed refs")
    func reopensBranchListWithCurrentGitReferences() async throws {
        let repositoryPath = try await FilesystemTestGitRepo.create(named: "command-bar-branch-list")
        defer { FilesystemTestGitRepo.destroy(repositoryPath) }

        let trackedFile = repositoryPath.appending(path: "tracked.txt")
        try "initial\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["commit", "-m", "Initial commit"])
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["branch", "delete-me"])
        try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["branch", "rename-me"])

        let statusBeforeReferenceChanges = try await FilesystemTestGitRepo.runGit(
            at: repositoryPath, args: ["status", "--porcelain=v1"])
        let defaultsSuiteName = "agentstudio.tests.worktree-branch-list.\(UUIDv7.generate().uuidString)"
        let recentsDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { recentsDefaults.removePersistentDomain(forName: defaultsSuiteName) }

        try await withAsyncTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology)
            let repository = store.addRepo(at: repositoryPath)
            let currentRepository = try #require(store.repositoryTopologyAtom.repo(repository.id))
            let repoCache = RepoCacheAtom()
            let branchListingCache = WorktreeBranchListingCache()
            let controller = CommandBarPanelController(
                store: store,
                octiconLoader: OcticonLoader(resourceRootURL: testAgentStudioResourceRootURL(from: #filePath)),
                repoCache: repoCache,
                dispatcher: WorktreeBranchListingAppCommandDispatcher(),
                quickOpenDirectoryHandler: { _, _ in },
                commandBarSurface: CommandBarSurfaceAtom(),
                recentsDefaults: recentsDefaults,
                branchListing: branchListingCache)
            let defaultStartPoint = WorktreeDefaultStartPoint.resolved(
                displayRef: "main", startPoint: "refs/heads/main")
            controller.state.show(prefix: ">")
            controller.state.recordDefaultStartPoint(defaultStartPoint, forRepositoryId: repository.id)

            let branchLevel = CommandBarDataSource.worktreeCreationMenuLevel(
                repository: currentRepository,
                store: store,
                repoCache: repoCache,
                defaultStartPoint: defaultStartPoint)
            controller.state.pushLevel(branchLevel)
            controller.requestCreationQueriesIfNeeded(for: branchLevel)
            let firstOpeningTask = try #require(controller.branchListingQueriesByRepositoryId[repository.id]?.task)
            await firstOpeningTask.value

            let rootSessionGeneration = controller.state.rootSessionGeneration
            let firstOpeningLevel = try #require(controller.state.currentLevel)
            #expect(
                Set(controller.state.branchNamesByRepositoryId[repository.id] ?? [])
                    == ["main", "delete-me", "rename-me"])
            #expect(Set(firstOpeningLevel.searchOnlyItems.map(\.title)) == ["delete-me", "rename-me"])

            controller.state.popLevel()
            try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["branch", "created-after-open"])
            try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["branch", "-D", "delete-me"])
            try await FilesystemTestGitRepo.runGit(
                at: repositoryPath, args: ["branch", "-m", "rename-me", "renamed-after-open"])
            try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["pack-refs", "--all", "--prune"])

            let statusAfterReferenceChanges = try await FilesystemTestGitRepo.runGit(
                at: repositoryPath, args: ["status", "--porcelain=v1"])
            let oracleReferences = try await FilesystemTestGitRepo.runGit(
                at: repositoryPath,
                args: ["for-each-ref", "--format=%(refname:short)", "refs/heads"])
            let packedReferencesURL = repositoryPath.appending(path: ".git/packed-refs")
            let packedReferences = try String(contentsOf: packedReferencesURL, encoding: .utf8)

            #expect(statusAfterReferenceChanges == statusBeforeReferenceChanges)
            #expect(
                Set(oracleReferences.split(whereSeparator: \.isNewline).map(String.init))
                    == ["main", "created-after-open", "renamed-after-open"])
            #expect(packedReferences.contains("refs/heads/created-after-open"))
            #expect(packedReferences.contains("refs/heads/renamed-after-open"))

            controller.state.pushLevel(firstOpeningLevel)
            controller.requestCreationQueriesIfNeeded(for: firstOpeningLevel)
            let secondOpeningTask = controller.branchListingQueriesByRepositoryId[repository.id]?.task
            #expect(secondOpeningTask != nil)
            if let secondOpeningTask {
                await secondOpeningTask.value
            }

            #expect(controller.state.rootSessionGeneration == rootSessionGeneration)
            #expect(
                Set(controller.state.branchNamesByRepositoryId[repository.id] ?? [])
                    == ["main", "created-after-open", "renamed-after-open"])
            #expect(
                Set(controller.state.currentLevel?.searchOnlyItems.map(\.title) ?? [])
                    == ["created-after-open", "renamed-after-open"])
        }
    }
}

@MainActor
private final class WorktreeBranchListingAppCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func dispatch(_: AppCommand) -> Bool { true }

    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}

    func canDispatch(_: AppCommand) -> Bool { true }

    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { true }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }

    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}

    func dispatchWorktreeCreation(_: WorktreeCreationRequest) -> Bool { false }
}
