import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

extension E2ESerializedTests {
    @MainActor
    @Suite(.serialized)
    struct FilesystemSourceE2ETests {
        @Test("filesystem actor events flow through coordinator into workspace stores")
        func filesystemEventsFlowThroughCoordinatorIntoStores() async throws {
            installTestCoreAtomsIfNeeded()
            let repoURL = try await FilesystemTestGitRepo.create(named: "filesystem-e2e")
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repoURL)

            let workspaceDir = repoURL.deletingLastPathComponent().appending(path: "workspace-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: workspaceDir) }
            let store = WorkspaceStore()
            let repo = store.addRepo(at: repoURL)
            let worktree = Worktree(
                repoId: repo.id,
                name: "main",
                path: repoURL,
                isMainWorktree: true
            )
            store.reconcileDiscoveredWorktrees(repo.id, worktrees: [worktree])
            let reconciledWorktree = try #require(store.repo(repo.id)?.worktrees.first)

            let pane = store.createPane(
                launchDirectory: reconciledWorktree.path,
                title: "Filesystem E2E Pane",
                facets: PaneContextFacets(
                    repoId: repo.id, worktreeId: reconciledWorktree.id, cwd: reconciledWorktree.path),
            )
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)

            let paneEventBus = EventBus<RuntimeEnvelope>()
            let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
            let gitWorkingTreeStatusProvider = ShellGitWorkingTreeStatusProvider(
                processExecutor: RunToExitProcessExecutor()
            )
            let filesystemSource = FilesystemGitPipeline(
                bus: paneEventBus,
                gitWorkingTreeProvider: gitWorkingTreeStatusProvider
            )
            let paneProjectionSubscription = await paneEventBus.subscribe(
                policy: .criticalUnbounded,
                subscriberName: #function
            )
            let paneProjectionSubscriber = RecordingSubscriber(subscription: paneProjectionSubscription)
            let repoCache = RepoCacheAtom()
            let cacheCoordinator = WorkspaceCacheCoordinator(
                bus: paneEventBus,
                workspaceStore: store,
                repoCache: repoCache,
                scopeSyncHandler: { _ in }
            )
            await cacheCoordinator.startConsuming()
            await filesystemSource.start()

            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: ViewRegistry(),
                runtime: SessionRuntime(store: store),
                surfaceManager: FilesystemE2ESurfaceManager(),
                terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
                terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: paneEventBus,
                gitWorkingTreeStatusProvider: gitWorkingTreeStatusProvider,
                gitStatusPhysicalGate: gitStatusPhysicalGate,
                filesystemSource: filesystemSource,
                windowLifecycleStore: WindowLifecycleAtom(),
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
            coordinator.syncFilesystemRootsAndActivity()

            await eventually("filesystem root should be registered for worktree") {
                coordinator.filesystemRegisteredContextsByWorktreeId[reconciledWorktree.id] != nil
            }

            await filesystemSource.enqueueRawPathsForTesting(
                worktreeId: reconciledWorktree.id,
                paths: ["tracked.txt", "untracked.txt"]
            )

            await eventually("workspace cache git snapshot should update") {
                guard let snapshot = repoCache.worktreeEnrichmentByWorktreeId[reconciledWorktree.id]?.snapshot else {
                    return false
                }
                return snapshot.summary.changed >= 1 && snapshot.summary.untracked >= 1
            }

            await eventually("pane projection event should publish") {
                RuntimeEnvelopeHarness.paneEvents(from: await paneProjectionSubscriber.snapshot()).contains { event in
                    guard event.paneId.uuid == pane.id else { return false }
                    guard
                        case .paneFilesystemContext(
                            .cwdSubtreeChanged(_, let paths, _)
                        ) = event.event
                    else { return false }
                    return paths.contains("tracked.txt") && paths.contains("untracked.txt")
                }
            }

            await coordinator.shutdown()
            await cacheCoordinator.shutdown()
            await paneProjectionSubscriber.shutdown()

            await eventually("filesystem source E2E should leave no subscribers behind") {
                await paneEventBus.subscriberCount == 0
            }
        }

        private func eventually(
            _ description: String,
            // High yield budget by design: we want scheduler-tolerant async
            // convergence without using wall-clock sleeps in tests.
            maxYields: Int = 300_000,
            condition: @escaping @MainActor () async -> Bool
        ) async {
            for _ in 0..<maxYields {
                if await condition() {
                    return
                }
                await Task.yield()
            }
            #expect(await condition(), "\(description) timed out")
        }
    }
}

@MainActor
private final class FilesystemE2ESurfaceManager:
    WorkspaceSurfaceManaging
{
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config _: Ghostty.SurfaceConfiguration,
        metadata _: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    @discardableResult
    func attach(_: UUID, to _: UUID) -> Ghostty.SurfaceView? { nil }

    func detach(_: UUID, reason _: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_: UUID) {}
}
