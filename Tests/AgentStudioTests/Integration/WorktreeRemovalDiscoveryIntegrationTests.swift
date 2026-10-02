import AgentStudioTestHarness
import AgentStudioWorktreeOperations
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite("Worktree removal discovery integration", .serialized)
struct WorktreeRemovalDiscoveryIntegrationTests {
    @Test("CLI removal disappears from the real sidebar projection and leaves its pane open unassociated")
    func removesDiscoveredLinkedWorktreeAndRetainsOpenPane() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let watchedRoot = FileManager.default.temporaryDirectory
                .appending(path: "worktree-removal-discovery-\(UUIDv7.generate())", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: watchedRoot) }
            let scenario = try await makeScenario(atoms: atoms, watchedRoot: watchedRoot)
            do {
                let discovered = try await discoverLinkedWorktree(in: scenario, atoms: atoms)
                try await removeLinkedWorktree(in: scenario, discovered: discovered)
                assertRemovedSidebarRowAndOpenPane(in: scenario, discovered: discovered)
                await finishScenario(scenario)
            } catch {
                await stopScenario(scenario)
                throw error
            }
        }
    }

    private func makeScenario(
        atoms: CoreAtoms,
        watchedRoot: URL
    ) async throws -> WorktreeRemovalDiscoveryScenario {
        let repositoryPath = watchedRoot.appending(path: "repository", directoryHint: .isDirectory)
        let linkedWorktreePath = watchedRoot.appending(path: "linked-feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watchedRoot, withIntermediateDirectories: true)
        try await makeRepositoryWithLinkedWorktree(
            repositoryPath: repositoryPath,
            linkedWorktreePath: linkedWorktreePath,
            branch: "feature/discovery"
        )

        let bus = EventBus<RuntimeEnvelope>()
        let filesystem = FilesystemActor(bus: bus, fseventStreamClient: ControllableFSEventStreamClient())
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology,
            graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout
        )
        let watchedPath = try #require(store.mutationCoordinator.addWatchedPath(watchedRoot))
        let surfaceCoordinator = makeWorkspaceSurfaceCoordinator(store: store, bus: bus)
        let topologyFactSource = LocalFactSource<UUID, WorktreeTopologyDelta>(
            vocabulary: FactVocabulary(
                describeScope: { $0.uuidString },
                describeFact: {
                    "topologyDelta(added:\($0.addedWorktreeIds.count), removed:\($0.removedWorktrees.map(\.path.lastPathComponent)))"
                },
                isClosing: { _, _ in false }
            )
        )
        let topologyFacts = try topologyFactSource.attach()
        let topologyEffects = WorktreeRemovalTopologyEffectRecorder(
            watchedPathID: watchedPath.id,
            surfaceCoordinator: surfaceCoordinator,
            factSink: topologyFactSource.sink
        )
        let cacheCoordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: store,
            repoCache: atoms.repoCache,
            topologyEffectHandler: topologyEffects,
            validateSourceObservations: { observations in
                await filesystem.areCurrentWatchedFolderObservations(observations)
            },
            scopeSyncHandler: { change in
                switch change {
                case .updateRepositoryScanBaseline(let repositories, let revision):
                    await filesystem.updateRepositoryScanBaseline(repositories, membershipRevision: revision)
                case .updateWatchedFolders(let paths, let repositories, let revision):
                    _ = await filesystem.refreshWatchedFolders(
                        paths, restoring: repositories, membershipRevision: revision)
                case .registerForgeRepo, .unregisterForgeRepo, .refreshForgeRepo:
                    break
                }
            }
        )
        let discoveryFacts = await watchedFolderTopologyFacts(bus: bus, watchedPathID: watchedPath.id)
        await filesystem.start()
        return WorktreeRemovalDiscoveryScenario(
            watchedRoot: watchedRoot,
            repositoryPath: repositoryPath,
            linkedWorktreePath: linkedWorktreePath,
            watchedPath: watchedPath,
            filesystem: filesystem,
            store: store,
            surfaceCoordinator: surfaceCoordinator,
            cacheCoordinator: cacheCoordinator,
            topologyFactSource: topologyFactSource,
            topologyFacts: topologyFacts,
            discoveryFacts: discoveryFacts
        )
    }

    private func discoverLinkedWorktree(
        in scenario: WorktreeRemovalDiscoveryScenario,
        atoms: CoreAtoms
    ) async throws -> DiscoveredLinkedWorktree {
        let initialSummary = await scenario.filesystem.refreshWatchedFolders(
            [scenario.watchedPath],
            restoring: [],
            membershipRevision: scenario.store.repositoryTopologyAtom.worktreePathIndexGeneration
        )
        #expect(initialSummary.repoPaths(in: scenario.watchedRoot) == [scenario.repositoryPath])
        #expect(initialSummary.linkedWorktreePaths(in: scenario.watchedRoot) == [scenario.linkedWorktreePath])
        let initialFact = try await scenario.discoveryFacts.expectNext(
            in: scenario.watchedPath.id,
            where: { _ in true },
            "real watched-folder discovery publishes its initial topology observation"
        )
        #expect(initialFact.observation.registration.sourceID.rootID == scenario.watchedPath.id)
        #expect(initialFact.sequence > 0)
        await scenario.cacheCoordinator.consumeWatchedFolderObservation(
            initialFact.observation,
            sequence: initialFact.sequence
        )
        let discoveryAddition = try await scenario.topologyFacts.expectNext(
            in: scenario.watchedPath.id,
            where: { !$0.addedWorktreeIds.isEmpty },
            "real discovery adds the main and linked worktrees"
        )
        let discovered = try #require(
            scenario.store.repositoryTopologyAtom.repoAndWorktree(containing: scenario.linkedWorktreePath)
        )
        #expect(discovered.repo.id == discoveryAddition.repoId)
        atoms.repoCache.setRepoEnrichment(
            .resolvedLocal(
                repoId: discovered.repo.id,
                identity: RepoIdentity(
                    groupKey: "local:\(discovered.repo.name)",
                    remoteSlug: nil,
                    organizationName: nil,
                    displayName: discovered.repo.name
                ),
                updatedAt: Date()
            )
        )
        let projectionCapture = RepoExplorerProjectionInputCapture(
            store: scenario.store,
            preferences: RepoExplorerSidebarPrefsAtom(sidebarState: atoms.workspaceSidebarState),
            repoCache: atoms.repoCache,
            sidebarState: atoms.workspaceSidebarState,
            sidebarCache: atoms.sidebarCache,
            coreAtoms: atoms,
            bridgeAttendanceSnapshot: { _ in nil },
            latestPaneMessageSnapshot: { _ in nil }
        )
        let pane = scenario.store.createPane(
            launchDirectory: scenario.linkedWorktreePath,
            facets: PaneContextFacets(
                repoId: discovered.repo.id,
                worktreeId: discovered.worktree.id,
                cwd: scenario.linkedWorktreePath
            )
        )
        let tab = Tab(paneId: pane.id)
        scenario.store.appendTab(tab)
        let initialProjection = RepoExplorerProjection.project(
            projectionCapture.captureRequest(query: "", referenceDate: Date(), trigger: .dataRefresh).snapshot
        )
        #expect(
            initialProjection.worktreeRowsByGroupId.values.flatMap { $0 }
                .contains { $0.worktree.id == discovered.worktree.id }
        )
        return DiscoveredLinkedWorktree(
            worktree: discovered.worktree,
            pane: pane,
            tab: tab,
            initialObservationSequence: initialFact.sequence,
            projectionCapture: projectionCapture
        )
    }

    private func removeLinkedWorktree(
        in scenario: WorktreeRemovalDiscoveryScenario,
        discovered: DiscoveredLinkedWorktree
    ) async throws {
        let commandExit = await WorktreeCommandLine.dispatch(
            arguments: [
                "worktree", "remove", "--repo", scenario.repositoryPath.path, scenario.linkedWorktreePath.path,
                "--no-fetch", "--json",
            ],
            currentDirectory: scenario.repositoryPath,
            output: { _ in },
            errorOutput: { _ in },
            runIPCCommand: { 99 }
        )
        try #require(commandExit == 0)
        #expect(!FileManager.default.fileExists(atPath: scenario.linkedWorktreePath.path))
        _ = await scenario.filesystem.refreshWatchedFolders(
            [scenario.watchedPath],
            restoring: scenario.store.repositoryTopologyAtom.repos,
            membershipRevision: scenario.store.repositoryTopologyAtom.worktreePathIndexGeneration
        )
        let currentReceipts = await scenario.filesystem.currentWatchedFolderObservationReceipts()
        let currentRemovalReceipt = try #require(
            currentReceipts.first {
                $0.observation.root.standardizedFileURL.path == scenario.watchedRoot.standardizedFileURL.path
            }
        )
        let removalFact = try await scenario.discoveryFacts.expectNext(
            in: scenario.watchedPath.id,
            where: { $0.sequence == currentRemovalReceipt.sequence },
            "authoritative watched-folder discovery reports the removed linked checkout"
        )
        let removalObservation = removalFact.observation
        #expect(removalFact.sequence > discovered.initialObservationSequence)
        _ = try #require(
            removalObservation.entries.first {
                $0.path.standardizedFileURL.path == scenario.repositoryPath.standardizedFileURL.path
            },
            "expected \(scenario.repositoryPath.path); entries: \(removalObservation.entries.map { $0.path.path })"
        )
        let hasAuthoritativeCoverage: Bool
        if case .authoritative = removalObservation.coverage {
            hasAuthoritativeCoverage = true
        } else {
            hasAuthoritativeCoverage = false
        }
        try #require(
            hasAuthoritativeCoverage,
            "removal observation must be authoritative before applying absence; entries: \(removalObservation.entries.map { $0.path.path })"
        )
        await scenario.cacheCoordinator.consumeWatchedFolderObservation(
            removalObservation,
            sequence: removalFact.sequence
        )
        let removalDelta = try await scenario.topologyFacts.expectNext(
            in: scenario.watchedPath.id,
            where: { delta in delta.removedWorktrees.contains { $0.id == discovered.worktree.id } },
            "topology reconciliation emits a typed removed-worktree delta"
        )
        #expect(removalDelta.removedWorktrees.contains { $0.id == discovered.worktree.id })
    }

    private func assertRemovedSidebarRowAndOpenPane(
        in scenario: WorktreeRemovalDiscoveryScenario,
        discovered: DiscoveredLinkedWorktree
    ) {
        let finalProjection = RepoExplorerProjection.project(
            discovered.projectionCapture.captureRequest(query: "", referenceDate: Date(), trigger: .dataRefresh)
                .snapshot
        )
        #expect(
            !finalProjection.worktreeRowsByGroupId.values.flatMap { $0 }
                .contains { $0.worktree.id == discovered.worktree.id }
        )
        #expect(scenario.store.repositoryTopologyAtom.isWorktreeUnavailable(discovered.worktree.id))
        #expect(scenario.store.pane(discovered.pane.id)?.residency == .active)
        #expect(scenario.store.tabContaining(paneId: discovered.pane.id)?.id == discovered.tab.id)
        let durableFacets = scenario.store.paneAtom.graphAtom.paneState(discovered.pane.id)?.durableContextFacets
        #expect(durableFacets?.repoId == nil)
        #expect(durableFacets?.worktreeId == nil)
    }

    private func finishScenario(_ scenario: WorktreeRemovalDiscoveryScenario) async throws {
        await shutdown(scenario)
        scenario.topologyFactSource.end()
        try await scenario.topologyFacts.finish()
        try await scenario.discoveryFacts.finish()
    }

    private func stopScenario(_ scenario: WorktreeRemovalDiscoveryScenario) async {
        await shutdown(scenario)
        scenario.topologyFactSource.end()
        try? await scenario.topologyFacts.finish()
        try? await scenario.discoveryFacts.finish()
    }

    private func makeRepositoryWithLinkedWorktree(
        repositoryPath: URL,
        linkedWorktreePath: URL,
        branch: String
    ) async throws {
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        _ = try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["init"])
        _ = try await FilesystemTestGitRepo.runGit(
            at: repositoryPath, args: ["symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try await FilesystemTestGitRepo.runGit(
            at: repositoryPath, args: ["config", "user.email", "tests@example.com"])
        _ = try await FilesystemTestGitRepo.runGit(
            at: repositoryPath, args: ["config", "user.name", "Agent Studio Tests"])
        _ = try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["config", "commit.gpgsign", "false"])
        try "initial\n".write(
            to: repositoryPath.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["add", "tracked.txt"])
        _ = try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: ["commit", "-m", "Initial"])
        _ = try await FilesystemTestGitRepo.runGit(
            at: repositoryPath,
            args: ["worktree", "add", "-b", branch, linkedWorktreePath.path, "main"]
        )
    }

    private func makeWorkspaceSurfaceCoordinator(
        store: WorkspaceStore,
        bus: EventBus<RuntimeEnvelope>
    ) -> WorkspaceSurfaceCoordinator {
        WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: HarnessSurfaceManager(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: bus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: AgentStudioGitStatusPhysicalGate(),
            filesystemSource: RecordingFilesystemSourceHarness(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }

    private func watchedFolderTopologyFacts(
        bus: EventBus<RuntimeEnvelope>,
        watchedPathID: UUID
    ) async -> FactRecorder<UUID, WatchedFolderReconciledFact> {
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        return EventBusFactSource.attach(
            subscription: subscription,
            vocabulary: FactVocabulary<UUID, WatchedFolderReconciledFact>(
                describeScope: { $0.uuidString },
                describeFact: { "watchedFolderReconciled(sequence:\($0.sequence))" },
                isClosing: { _, _ in false }
            ),
            replayWasTruncated: {
                if case .possiblyTruncated = subscription.replayStatus { return true }
                return false
            },
            classify: { envelope in
                guard case .system(let system) = envelope,
                    case .topology(.watchedFolderReconciled(let observation)) = system.event,
                    observation.registration.sourceID.rootID == watchedPathID
                else { return nil }
                return (
                    watchedPathID,
                    WatchedFolderReconciledFact(
                        sequence: system.seq,
                        observation: observation
                    )
                )
            }
        )
    }

    private func shutdown(
        _ scenario: WorktreeRemovalDiscoveryScenario
    ) async {
        await scenario.cacheCoordinator.shutdown()
        await scenario.surfaceCoordinator.shutdown()
        await scenario.filesystem.shutdown()
    }
}

@MainActor
private struct WorktreeRemovalDiscoveryScenario {
    let watchedRoot: URL
    let repositoryPath: URL
    let linkedWorktreePath: URL
    let watchedPath: WatchedPath
    let filesystem: FilesystemActor
    let store: WorkspaceStore
    let surfaceCoordinator: WorkspaceSurfaceCoordinator
    let cacheCoordinator: WorkspaceCacheCoordinator
    let topologyFactSource: LocalFactSource<UUID, WorktreeTopologyDelta>
    let topologyFacts: FactRecorder<UUID, WorktreeTopologyDelta>
    let discoveryFacts: FactRecorder<UUID, WatchedFolderReconciledFact>
}

@MainActor
private struct DiscoveredLinkedWorktree {
    let worktree: Worktree
    let pane: Pane
    let tab: Tab
    let initialObservationSequence: UInt64
    let projectionCapture: RepoExplorerProjectionInputCapture
}

private struct WatchedFolderReconciledFact: Sendable {
    let sequence: UInt64
    let observation: WatchedFolderTopologyObservation
}

@MainActor
private final class WorktreeRemovalTopologyEffectRecorder: TopologyEffectHandler {
    private let watchedPathID: UUID
    private let surfaceCoordinator: WorkspaceSurfaceCoordinator
    private let factSink: @Sendable (UUID, WorktreeTopologyDelta) -> Void

    init(
        watchedPathID: UUID,
        surfaceCoordinator: WorkspaceSurfaceCoordinator,
        factSink: @escaping @Sendable (UUID, WorktreeTopologyDelta) -> Void
    ) {
        self.watchedPathID = watchedPathID
        self.surfaceCoordinator = surfaceCoordinator
        self.factSink = factSink
    }

    func topologyDidChange(_ delta: WorktreeTopologyDelta) {
        surfaceCoordinator.topologyDidChange(delta)
        factSink(watchedPathID, delta)
    }
}
