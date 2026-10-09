import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct WorkspaceCacheCoordinatorDiscoveryEffectsTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("not-scanned discovery registers the new main worktree before authoritative replay")
    func notScannedDiscoveryRegistersNewMainWorktreeBeforeScannedReplay() async throws {
        try await withDiscoveryHarness { harness in
            let repoPath = URL(
                filePath: "/tmp/discovery-effects-single-\(UUIDv7.generate().uuidString)"
            )

            harness.cacheCoordinator.handleTopology(
                discoveryEnvelope(repoPath: repoPath, linkedWorktrees: .notScanned)
            )
            await harness.surfaceCoordinator.waitForFilesystemRootsAndActivitySyncIdle()

            let mainWorktree = try #require(harness.store.repos.single?.worktrees.single)
            #expect(mainWorktree.isMainWorktree)
            #expect(mainWorktree.path == repoPath.standardizedFileURL)
            let initialRegistrationIds = await harness.filesystemSource.operations().compactMap(
                \.registeredWorktreeId
            )
            #expect(initialRegistrationIds == [mainWorktree.id])
            #expect(
                await harness.filesystemSource.snapshot().registeredRoots
                    == [mainWorktree.id: repoPath.standardizedFileURL]
            )
            #expect(harness.topologyEffects.batches.count == 1)
            #expect(harness.topologyEffects.batches.single?.single?.addedWorktreeIds == [mainWorktree.id])

            harness.cacheCoordinator.handleTopology(
                discoveryEnvelope(repoPath: repoPath, linkedWorktrees: .scanned([]))
            )
            await harness.surfaceCoordinator.waitForFilesystemRootsAndActivitySyncIdle()

            let replayRegistrationIds = await harness.filesystemSource.operations().compactMap(
                \.registeredWorktreeId
            )
            #expect(replayRegistrationIds == initialRegistrationIds)
            #expect(harness.topologyEffects.batches.count == 1)
        }
    }

    @Test("batched discovery registers every new worktree once and replay emits no duplicates")
    func batchedDiscoveryRegistersCompleteNewFamiliesWithoutReplayDuplicates() async throws {
        try await withDiscoveryHarness { harness in
            let parentPath = URL(
                filePath: "/tmp/discovery-effects-batch-\(UUIDv7.generate().uuidString)"
            )
            let unscannedRepoPath = parentPath.appending(path: "unscanned")
            let scannedRepoPath = parentPath.appending(path: "scanned")
            let linkedWorktreePath = parentPath.appending(path: "scanned-linked")
            let repositories = [
                DiscoveredRepoTopologyInfo(
                    repoPath: unscannedRepoPath,
                    linkedWorktrees: .notScanned
                ),
                DiscoveredRepoTopologyInfo(
                    repoPath: scannedRepoPath,
                    linkedWorktrees: .scanned([linkedWorktreePath])
                ),
            ]
            let envelope = SystemEnvelope.test(
                event: .topology(
                    .reposDiscovered(parentPath: parentPath, repositories: repositories)
                ),
                eventId: UUIDv7.generate()
            )

            harness.cacheCoordinator.handleTopology(envelope)
            await harness.surfaceCoordinator.waitForFilesystemRootsAndActivitySyncIdle()

            let discoveredWorktrees = harness.store.repos.flatMap(\.worktrees)
            let expectedWorktreeIds = Set(discoveredWorktrees.map(\.id))
            let expectedPaths = Set(
                [unscannedRepoPath, scannedRepoPath, linkedWorktreePath].map(\.standardizedFileURL)
            )
            #expect(expectedWorktreeIds.count == 3)
            #expect(Set(discoveredWorktrees.map(\.path)) == expectedPaths)
            let initialSnapshot = await harness.filesystemSource.snapshot()
            #expect(Set(initialSnapshot.registeredRoots.keys) == expectedWorktreeIds)
            #expect(Set(initialSnapshot.registeredRoots.values) == expectedPaths)
            let initialRegistrationIds = await harness.filesystemSource.operations().compactMap(
                \.registeredWorktreeId
            )
            #expect(initialRegistrationIds.count == 3)
            #expect(Set(initialRegistrationIds) == expectedWorktreeIds)
            #expect(harness.topologyEffects.batches.count == 1)
            #expect(
                Set(harness.topologyEffects.batches.single?.flatMap(\.addedWorktreeIds) ?? [])
                    == expectedWorktreeIds
            )

            harness.cacheCoordinator.handleTopology(envelope)
            await harness.surfaceCoordinator.waitForFilesystemRootsAndActivitySyncIdle()

            let replayRegistrationIds = await harness.filesystemSource.operations().compactMap(
                \.registeredWorktreeId
            )
            #expect(replayRegistrationIds == initialRegistrationIds)
            #expect(harness.topologyEffects.batches.count == 1)
        }
    }

    private func discoveryEnvelope(
        repoPath: URL,
        linkedWorktrees: LinkedWorktreeInfo
    ) -> SystemEnvelope {
        SystemEnvelope.test(
            event: .topology(
                .repoDiscovered(
                    repoPath: repoPath,
                    parentPath: repoPath.deletingLastPathComponent(),
                    linkedWorktrees: linkedWorktrees
                )
            ),
            eventId: UUIDv7.generate()
        )
    }

    private func withDiscoveryHarness(
        operation: (DiscoveryEffectsHarness) async throws -> Void
    ) async throws {
        let harness = makeDiscoveryHarness()
        do {
            try await operation(harness)
        } catch {
            await harness.surfaceCoordinator.shutdown()
            throw error
        }
        await harness.surfaceCoordinator.shutdown()
    }

    private func makeDiscoveryHarness() -> DiscoveryEffectsHarness {
        let store = WorkspaceStore()
        let filesystemSource = OrderedRecordingFilesystemSource()
        let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let surfaceCoordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: MockFilesystemCoordinatorSurfaceManager(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: filesystemSource,
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        let topologyEffects = RecordingForwardingTopologyEffectHandler(
            downstream: surfaceCoordinator
        )
        let cacheCoordinator = WorkspaceCacheCoordinator(
            bus: EventBus<RuntimeEnvelope>(),
            workspaceStore: store,
            repoCache: RepoCacheAtom(),
            welcomeAtom: WelcomeAtom(),
            topologyEffectHandler: topologyEffects,
            scopeSyncHandler: { _ in }
        )
        return DiscoveryEffectsHarness(
            store: store,
            filesystemSource: filesystemSource,
            surfaceCoordinator: surfaceCoordinator,
            topologyEffects: topologyEffects,
            cacheCoordinator: cacheCoordinator
        )
    }
}

@MainActor
private struct DiscoveryEffectsHarness {
    let store: WorkspaceStore
    let filesystemSource: OrderedRecordingFilesystemSource
    let surfaceCoordinator: WorkspaceSurfaceCoordinator
    let topologyEffects: RecordingForwardingTopologyEffectHandler
    let cacheCoordinator: WorkspaceCacheCoordinator
}

@MainActor
private final class RecordingForwardingTopologyEffectHandler: TopologyEffectHandler {
    private(set) var batches: [[WorktreeTopologyDelta]] = []
    private let downstream: any TopologyEffectHandler

    init(downstream: any TopologyEffectHandler) {
        self.downstream = downstream
    }

    func topologyDidChange(_ delta: WorktreeTopologyDelta) {
        batches.append([delta])
        downstream.topologyDidChange(delta)
    }

    func topologyDidChange(_ deltas: [WorktreeTopologyDelta]) {
        batches.append(deltas)
        downstream.topologyDidChange(deltas)
    }
}
