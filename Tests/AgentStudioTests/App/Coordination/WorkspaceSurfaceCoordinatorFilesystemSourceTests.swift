import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceCoordinatorFilesystemSourceTests {
    private let expectedSourceSyncBatchSize = AppPolicies.FilesystemSourceSync.maximumWorktreeKeysPerBatch

    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("bulk source sync stages every registration in bounded stable batches")
    func bulkSourceSyncStagesEveryRegistrationInBoundedStableBatches() async throws {
        let harness = makeHarness()
        let traceDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-source-sync-batches-\(UUIDv7.generate().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: harness.tempDir)
            try? FileManager.default.removeItem(at: traceDirectory)
        }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "bulk-source-sync-repo"))
        let mainWorktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let discoveredWorktrees = (1..<105).map { index in
            Worktree(
                repoId: repo.id,
                name: "feature-\(index)",
                path: repo.repoPath.appending(path: "feature-\(index)")
            )
        }
        harness.store.reconcileDiscoveredWorktrees(
            repo.id,
            worktrees: [mainWorktree] + discoveredWorktrees
        )
        let expectedWorktrees = try #require(harness.store.repo(repo.id)?.worktrees)
        let expectedWorktreeIds = expectedWorktrees.map(\.id).sorted { $0.uuidString < $1.uuidString }

        let traceRuntime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "source-sync-batches",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 946,
            timeUnixNano: { 946 }
        )
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: traceRuntime)
        let source = OrderedRecordingFilesystemSource()
        let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: harness.store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: harness.store),
            surfaceManager: MockFilesystemCoordinatorSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: harness.bus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: source,
            filesystemProjectionIndex: FilesystemProjectionIndex(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom(),
            performanceTraceRecorder: recorder
        )
        defer { Task { await coordinator.shutdown() } }

        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
        try await recorder.drain()

        let operations = await source.operations()
        #expect(operations.compactMap(\.registeredWorktreeId) == expectedWorktreeIds)
        let sourceSnapshot = await source.snapshot()
        #expect(Set(sourceSnapshot.registeredRoots.keys) == Set(expectedWorktreeIds))
        #expect(sourceSnapshot.activityByWorktreeId.isEmpty)
        #expect(sourceSnapshot.activePaneWorktreeId == nil)

        let outputFileURL = try #require(traceRuntime.outputFileURL)
        let registrationCounts = try sourceSyncRegistrationCounts(from: outputFileURL)
        #expect(registrationCounts == [32, 32, 32, 9])
        #expect(registrationCounts.allSatisfy { $0 <= expectedSourceSyncBatchSize })
        #expect(registrationCounts.reduce(0, +) == expectedWorktreeIds.count)
    }

    @Test("filesystem source writes roots before the topology assertion")
    func filesystemSourceWritesRootsBeforeTopologyAssertion() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "source-order-repo"))
        let mainWorktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let featureWorktree = Worktree(
            repoId: repo.id,
            name: "feature",
            path: repo.repoPath.appending(path: "feature")
        )
        harness.store.reconcileDiscoveredWorktrees(repo.id, worktrees: [mainWorktree, featureWorktree])
        let reconciledFeature = try #require(
            harness.store.repo(repo.id)?.worktrees.first(where: { $0.path == featureWorktree.path })
        )

        let pane = harness.store.createPane(
            launchDirectory: mainWorktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: mainWorktree.id, cwd: mainWorktree.path)
        )
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        let source = OrderedRecordingFilesystemSource()
        let coordinator = makeCoordinator(
            store: harness.store,
            source: source,
            index: FilesystemProjectionIndex(),
            bus: harness.bus
        )
        defer { Task { await coordinator.shutdown() } }
        coordinator.syncFilesystemRootsAndActivity()

        await source.waitForOperation(.assertTopology)

        let operations = await source.operations()
        let registerOperations = operations.compactMap(\.registeredWorktreeId)
        #expect(registerOperations.first == mainWorktree.id)
        #expect(Set(registerOperations) == Set([mainWorktree.id, reconciledFeature.id]))
        let firstRegister = try #require(operations.firstIndex { $0.isRegister })
        let firstAssertTopology = try #require(operations.firstIndex { $0.isAssertTopology })
        #expect(firstRegister < firstAssertTopology)
        #expect(
            !operations.contains {
                $0.kind == .activity || $0.kind == .activePane || $0.kind == .sidebarVisibleWorktrees
            }
        )
    }

    @Test("sidebar visibility changes do not enter the filesystem-effects lane")
    func sidebarVisibilityChangesDoNotEnterFilesystemEffectsLane() async {
        await withAsyncTestCoreAtoms { coreAtoms in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let sidebarVisibleWorktreesAtom = coreAtoms.sidebarVisibleWorktreesRuntime

            let source = OrderedRecordingFilesystemSource()
            let coordinator = makeCoordinator(
                store: harness.store,
                source: source,
                index: FilesystemProjectionIndex(),
                bus: harness.bus
            )

            await source.waitForOperation(.assertTopology)
            await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
            let bootstrapFullReconciliationCount = coordinator.filesystemFullReconciliationRequestCount
            await source.resetOperations()

            let visibleWorktreeIds: Set<UUID> = [UUIDv7.generate(), UUIDv7.generate()]
            sidebarVisibleWorktreesAtom.setVisibleWorktreeIds(visibleWorktreeIds)
            await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

            #expect(await source.operations().isEmpty)
            #expect(coordinator.filesystemFullReconciliationRequestCount == bootstrapFullReconciliationCount)
            #expect(coordinator.filesystemAffectedKeyRequestCount == 0)
            await coordinator.shutdown()
        }
    }

    @Test("stale source sync result is discarded before source side effects")
    func staleSourceSyncResultIsDiscardedBeforeSourceSideEffects() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "stale-source-repo"))
        let mainWorktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let staleWorktree = Worktree(
            repoId: repo.id,
            name: "stale",
            path: repo.repoPath.appending(path: "stale")
        )
        harness.store.reconcileDiscoveredWorktrees(repo.id, worktrees: [mainWorktree, staleWorktree])
        let reconciledStale = try #require(
            harness.store.repo(repo.id)?.worktrees.first(where: { $0.path == staleWorktree.path })
        )

        let pane = harness.store.createPane(
            launchDirectory: mainWorktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: mainWorktree.id, cwd: mainWorktree.path)
        )
        harness.store.appendTab(Tab(paneId: pane.id))

        let source = OrderedRecordingFilesystemSource()
        let index = GateableFilesystemProjectionIndex()
        await index.pauseNextSourceSync()
        let coordinator = makeCoordinator(
            store: harness.store,
            source: source,
            index: index,
            bus: harness.bus
        )
        defer { Task { await coordinator.shutdown() } }

        await index.waitForPausedSourceSync()

        let latestWorktree = Worktree(
            repoId: repo.id,
            name: "latest",
            path: repo.repoPath.appending(path: "latest")
        )
        harness.store.reconcileDiscoveredWorktrees(repo.id, worktrees: [mainWorktree, latestWorktree])
        let reconciledLatest = try #require(
            harness.store.repo(repo.id)?.worktrees.first(where: { $0.path == latestWorktree.path })
        )
        coordinator.topologyDidChange(
            WorktreeTopologyDelta(
                repoId: repo.id,
                addedWorktreeIds: [reconciledLatest.id],
                removedWorktrees: [
                    RemovedWorktreeEntry(id: reconciledStale.id, path: reconciledStale.path)
                ],
                preservedWorktreeIds: [mainWorktree.id],
                didChange: true,
                traceId: nil
            )
        )

        await index.resumePausedSourceSync()
        coordinator.syncFilesystemRootsAndActivity()

        await source.waitForAssertTopology(worktreeIds: Set([mainWorktree.id, reconciledLatest.id]))

        let operations = await source.operations()
        #expect(!operations.contains(.register(worktreeId: reconciledStale.id)))
        #expect(operations.contains(.register(worktreeId: reconciledLatest.id)))
    }

    @Test("source sync commit failure requeues a fresh pass")
    func sourceSyncCommitFailureRequeuesFreshPass() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "commit-requeue-repo"))
        let worktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        harness.store.appendTab(Tab(paneId: pane.id))

        let source = OrderedRecordingFilesystemSource()
        let index = GateableFilesystemProjectionIndex()
        await index.failNextCommit()
        let coordinator = makeCoordinator(
            store: harness.store,
            source: source,
            index: index,
            bus: harness.bus
        )
        defer { Task { await coordinator.shutdown() } }

        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        let operations = await source.operations()
        let topologyAssertions = operations.compactMap(\.assertedTopologyWorktreeIds)
        #expect(topologyAssertions.count >= 2)
        #expect(topologyAssertions.last == Set([worktree.id]))
    }

    @Test("superseded source sync repairs writes applied before supersession")
    func supersededSourceSyncRepairsPartiallyAppliedWrites() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "superseded-source-repo"))
        let originalWorktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let pane = harness.store.createPane(
            launchDirectory: originalWorktree.path,
            facets: PaneContextFacets(
                repoId: repo.id,
                worktreeId: originalWorktree.id,
                cwd: originalWorktree.path
            )
        )
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        let source = OrderedRecordingFilesystemSource()
        let coordinator = makeCoordinator(
            store: harness.store,
            source: source,
            index: FilesystemProjectionIndex(),
            bus: harness.bus
        )
        defer { Task { await coordinator.shutdown() } }

        await source.waitForOperation(.assertTopology)
        await source.pauseNextUnregister()

        let relocatedWorktree = Worktree(
            id: originalWorktree.id,
            repoId: repo.id,
            name: originalWorktree.name,
            path: repo.repoPath.appending(path: "relocated"),
            isMainWorktree: true
        )
        harness.store.reconcileDiscoveredWorktrees(repo.id, worktrees: [relocatedWorktree])
        coordinator.syncFilesystemRootsAndActivity()
        await source.waitForPausedUnregister()

        harness.store.reconcileDiscoveredWorktrees(repo.id, worktrees: [originalWorktree])
        coordinator.syncFilesystemRootsAndActivity()
        await source.resumePausedUnregister()
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        let snapshot = await source.snapshot()
        #expect(snapshot.registeredRoots[originalWorktree.id] == originalWorktree.path)
        #expect(snapshot.activityByWorktreeId.isEmpty)
        #expect(snapshot.activePaneWorktreeId == nil)
    }

    @Test("stale projection result is dropped when pane context generation changes")
    func staleProjectionResultIsDroppedWhenPaneContextGenerationChanges() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "stale-projection-repo"))
        let worktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        harness.store.appendTab(Tab(paneId: pane.id))

        let source = OrderedRecordingFilesystemSource()
        let index = GateableFilesystemProjectionIndex()
        let coordinator = makeCoordinator(
            store: harness.store,
            source: source,
            index: index,
            bus: harness.bus
        )
        defer { Task { await coordinator.shutdown() } }

        await source.waitForOperation(.assertTopology)

        await index.pauseNextProjection()
        let subscriber = await harness.makeSubscriber()
        await waitForBusSubscriberCount(harness.bus, atLeast: 1)

        let envelope = RuntimeEnvelopeHarness.filesystemEnvelope(
            event: .filesChanged(
                changeset: FileChangeset(
                    worktreeId: worktree.id,
                    repoId: repo.id,
                    rootPath: worktree.path,
                    paths: ["Sources/App.swift"],
                    timestamp: ContinuousClock().now,
                    batchSeq: 10
                )
            ),
            repoId: repo.id,
            worktreeId: worktree.id
        )

        let projectionTask = Task { @MainActor in
            await coordinator.handleFilesystemEnvelopeIfNeeded(envelope)
        }
        await index.waitForPausedProjection()

        coordinator.removePaneFilesystemProjectionContext(paneId: pane.id)
        await index.resumePausedProjection()
        _ = await projectionTask.value
        await Task.yield()

        let paneEvents = RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot())
        #expect(paneEvents.isEmpty)

        await subscriber.shutdown()
    }

    @Test("newer filesystem envelope does not drop older valid projection")
    func newerFilesystemEnvelopeDoesNotDropOlderValidProjection() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "projection-order-repo"))
        let worktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        harness.store.appendTab(Tab(paneId: pane.id))

        let source = OrderedRecordingFilesystemSource()
        let index = GateableFilesystemProjectionIndex()
        let coordinator = makeCoordinator(
            store: harness.store,
            source: source,
            index: index,
            bus: harness.bus
        )
        defer { Task { await coordinator.shutdown() } }

        await source.waitForOperation(.assertTopology)
        await index.pauseNextProjection()
        let subscriber = await harness.makeSubscriber()
        await waitForBusSubscriberCount(harness.bus, atLeast: 1)

        let olderEnvelope = RuntimeEnvelopeHarness.filesystemEnvelope(
            event: .filesChanged(
                changeset: FileChangeset(
                    worktreeId: worktree.id,
                    repoId: repo.id,
                    rootPath: worktree.path,
                    paths: ["Sources/App.swift"],
                    timestamp: ContinuousClock().now,
                    batchSeq: 10
                )
            ),
            repoId: repo.id,
            worktreeId: worktree.id
        )
        let newerEnvelope = RuntimeEnvelopeHarness.filesystemEnvelope(
            event: .filesChanged(
                changeset: FileChangeset(
                    worktreeId: worktree.id,
                    repoId: repo.id,
                    rootPath: worktree.path,
                    paths: ["Sources/Model.swift"],
                    timestamp: ContinuousClock().now,
                    batchSeq: 11
                )
            ),
            repoId: repo.id,
            worktreeId: worktree.id
        )

        let olderTask = Task { @MainActor in
            await coordinator.handleFilesystemEnvelopeIfNeeded(olderEnvelope)
        }
        await index.waitForPausedProjection()
        let newerTask = Task { @MainActor in
            await coordinator.handleFilesystemEnvelopeIfNeeded(newerEnvelope)
        }
        _ = await newerTask.value
        await index.resumePausedProjection()
        _ = await olderTask.value

        await assertEventuallyAsync("both valid projections should publish", minimumTurns: 200_000) {
            let paneEvents = RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot())
            return paneEvents.count == 2
        }

        await subscriber.shutdown()
    }

    @Test("derived filesystem publication rejects a stale pane context")
    func derivedFilesystemPublicationRejectsStalePaneContext() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "publication-currentness-repo"))
        let worktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let worktreeDirectory = URL(filePath: worktree.path.path, directoryHint: .isDirectory)
        let firstPane = harness.store.createPane(
            launchDirectory: worktreeDirectory,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktreeDirectory)
        )
        let staleCwd = worktreeDirectory.appending(path: "stale", directoryHint: .isDirectory)
        let secondPane = harness.store.createPane(
            launchDirectory: worktreeDirectory,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: staleCwd)
        )
        harness.store.appendTab(Tab(paneId: firstPane.id))

        let coordinator = makeCoordinator(
            store: harness.store,
            source: OrderedRecordingFilesystemSource(),
            index: FilesystemProjectionIndex(),
            bus: harness.bus
        )
        defer { Task { await coordinator.shutdown() } }
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        let subscriber = await harness.makeSubscriber()
        await waitForBusSubscriberCount(harness.bus, atLeast: 1)
        harness.store.paneAtom.updatePaneCWD(
            secondPane.id,
            cwd: worktreeDirectory.appending(path: "current", directoryHint: .isDirectory)
        )

        let currentEnvelope = paneFilesystemEnvelope(
            pane: firstPane,
            context: PaneFilesystemContext(
                paneId: PaneId(existingUUID: firstPane.id),
                repoId: repo.id,
                cwd: worktreeDirectory,
                worktreeId: worktree.id
            ),
            sequence: 1
        )
        let staleEnvelope = paneFilesystemEnvelope(
            pane: secondPane,
            context: PaneFilesystemContext(
                paneId: PaneId(existingUUID: secondPane.id),
                repoId: repo.id,
                cwd: staleCwd,
                worktreeId: worktree.id
            ),
            sequence: 1
        )

        await coordinator.publishCurrentDerivedFilesystemEnvelopes(
            [currentEnvelope, staleEnvelope],
            source: RuntimeEnvelopeHarness.filesystemEnvelope(
                event: .filesChanged(
                    changeset: FileChangeset(
                        worktreeId: worktree.id, repoId: repo.id, rootPath: worktree.path,
                        paths: ["Sources/App.swift"], timestamp: .now, batchSeq: 1)),
                repoId: repo.id, worktreeId: worktree.id))

        await assertEventuallyAsync("only current pane context should publish") {
            await subscriber.snapshot().count == 1
        }
        let publishedPaneIds = RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot()).map(\.paneId)
        #expect(publishedPaneIds == [PaneId(existingUUID: firstPane.id)])

        await subscriber.shutdown()
    }

    @Test("shutdown retires a filesystem projection before awaiting reducer tasks")
    func shutdownRetiresFilesystemProjectionBeforeAwaitingReducerTasks() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "shutdown-projection-repo"))
        let worktree = try #require(harness.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        harness.store.appendTab(Tab(paneId: pane.id))

        let source = OrderedRecordingFilesystemSource()
        let index = GateableFilesystemProjectionIndex()
        await index.pauseNextProjection()
        let coordinator = makeCoordinator(
            store: harness.store,
            source: source,
            index: index,
            bus: harness.bus
        )
        await source.waitForOperation(.assertTopology)

        await harness.bus.post(
            RuntimeEnvelopeHarness.filesystemEnvelope(
                event: .filesChanged(
                    changeset: FileChangeset(
                        worktreeId: worktree.id,
                        repoId: repo.id,
                        rootPath: worktree.path,
                        paths: ["Sources/App.swift"],
                        timestamp: ContinuousClock().now,
                        batchSeq: 10
                    )
                ),
                repoId: repo.id,
                worktreeId: worktree.id
            )
        )
        await index.waitForPausedProjection()

        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
        }
        await index.waitForShutdown()
        await shutdownTask.value

        #expect(await index.shutdownInvocationCount() == 1)
    }

    private func makeHarness() -> FilesystemCoordinatorHarness {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-filesystem-coordinator-\(UUID().uuidString)")
        let store = WorkspaceStore()
        return FilesystemCoordinatorHarness(
            store: store,
            bus: makeTestPaneRuntimeEventBus(),
            tempDir: tempDir
        )
    }

    private func makeCoordinator(
        store: WorkspaceStore,
        source: some WorkspaceFilesystemSourceManaging,
        index: some WorkspaceFilesystemProjectionIndexing,
        bus: EventBus<RuntimeEnvelope>
    ) -> WorkspaceSurfaceCoordinator {
        let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        return WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: MockFilesystemCoordinatorSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: bus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: source,
            filesystemProjectionIndex: index,
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }

    private func sourceSyncRegistrationCounts(from traceFileURL: URL) throws -> [Int] {
        let contents = try String(contentsOf: traceFileURL, encoding: .utf8)
        return try contents.split(separator: "\n").compactMap { line in
            let data = Data(line.utf8)
            let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            guard record["body"] as? String == "performance.coordinator.write",
                let attributes = record["attributes"] as? [String: Any],
                attributes["agentstudio.performance.coordinator.phase"] as? String == "source_sync"
            else {
                return nil
            }
            return (attributes["agentstudio.performance.coordinator.registered.count"] as? NSNumber)?.intValue
        }
    }
}
