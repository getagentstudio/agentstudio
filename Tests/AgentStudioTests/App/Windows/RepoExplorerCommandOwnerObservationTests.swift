import AgentStudioInfrastructure
import Observation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestHarness
@testable import AgentStudioTestSupport

@MainActor
@Suite("Repo Explorer observes selected command owners", .serialized)
struct RepoExplorerCommandOwnerObservationTests {
    @Test("shell installation republishes toolbar capability without changing visible rows")
    func shellInstallationRefreshesUnchangedVisibleRows() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            let preferences = RepoExplorerSidebarPrefsAtom(sidebarState: coreAtoms.workspaceSidebarState)
            let delegate = AppDelegate()
            delegate.atomStore = AtomRegistry(core: coreAtoms, repoExplorerSidebarPrefs: preferences)
            let dispatcher = delegate.commandDispatcherForBoot()
            let batch = RepoExplorerCommandPresentationBatch(
                store: WorkspaceStore(), repoExplorerPrefs: preferences,
                resolveCommandCapabilities: dispatcher.repoExplorerCommandPresentationSnapshot,
                executionOwnerIdentities: dispatcher.executionOwnerIdentities
            )
            let request = try #require(
                RepoExplorerToolbarCommandPresentation.requests().first {
                    $0.command == .toggleReposShowsPinned
                })
            batch.start()
            batch.acceptVisibleWorktreeSnapshot(
                RepoExplorerVisibleWorktreeSnapshot(
                    target: .init(
                        materializationHostLifetimeID: .init(rawValue: UUIDv7.generate()),
                        materializationGeneration: 1, visibleRevision: 1),
                    worktreeIDs: []
                ))
            #expect(batch.snapshot.results[request] == false)
            #expect(!dispatcher.dispatch(.toggleReposShowsPinned))
            let generationBefore = batch.snapshot.generation
            let source = LocalFactSource<String, Bool>(
                vocabulary: .init(
                    describeScope: { $0 }, describeFact: { $0 ? "published" : "unpublished" },
                    isClosing: { _, _ in false }
                ))
            let recorder = try source.attach()
            withObservationTracking {
                _ = batch.snapshot
            } onChange: {
                source.sink("shell installation command presentation", true)
            }
            do {
                delegate.markShellRuntimeOwnersInstalled()
                try await recorder.expectNext(in: "shell installation command presentation", true)
                #expect(batch.snapshot.generation > generationBefore)
                #expect(batch.snapshot.results[request] == true)
                let showsPinnedBefore = preferences.showsPinned(for: .repos)
                #expect(dispatcher.dispatch(.toggleReposShowsPinned))
                #expect(preferences.showsPinned(for: .repos) == !showsPinnedBefore)
            } catch {
                batch.stop()
                source.end()
                try? await recorder.finish()
                throw error
            }
            batch.stop()
            source.end()
            try await recorder.finish()
        }
    }
}
