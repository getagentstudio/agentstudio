import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

final class HarnessSurfaceManager: WorkspaceSurfaceManaging {
    private(set) var retainedUndoPaneIDs = Set<UUID>()
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) { retainedUndoPaneIDs.formUnion(paneIDs) }
    private(set) var retiredActivePaneIDs = Set<UUID>()
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) { retiredActivePaneIDs.formUnion(paneIDs) }

    private(set) var releasedUndoPaneIDs = Set<UUID>()
    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) { releasedUndoPaneIDs.formUnion(paneIDs) }

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config _: Ghostty.SurfaceConfiguration,
        metadata _: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.operationFailed("mock"))
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        _ = surfaceId
        _ = paneId
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        _ = surfaceId
        _ = reason
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {
        _ = surfaceId
    }
}

actor RecordingFilesystemSourceHarness: WorkspaceFilesystemSourceManaging {
    private var registeredRoots: [UUID: URL] = [:]
    private var activityByWorktreeId: [UUID: Bool] = [:]
    private var activePaneWorktreeId: UUID?
    private var topologyAssertionGeneration: UInt64?
    private var registerLog: [(worktreeId: UUID, repoId: UUID, rootPath: URL)] = []
    private var unregisterLog: [UUID] = []

    func start() async {}

    func shutdown() async {}

    func register(worktreeId: UUID, repoId: UUID, rootPath: URL) async {
        registeredRoots[worktreeId] = rootPath
        registerLog.append((worktreeId: worktreeId, repoId: repoId, rootPath: rootPath))
    }

    func unregister(worktreeId: UUID) async {
        registeredRoots.removeValue(forKey: worktreeId)
        unregisterLog.append(worktreeId)
        activityByWorktreeId.removeValue(forKey: worktreeId)
        if activePaneWorktreeId == worktreeId {
            activePaneWorktreeId = nil
        }
    }

    func assertTopology(_ assertion: FilesystemTopologyAssertion) async {
        guard topologyAssertionGeneration.map({ assertion.generation >= $0 }) ?? true else { return }
        topologyAssertionGeneration = assertion.generation
        let desiredWorktreeIds = Set(assertion.contextsByWorktreeId.keys)
        registeredRoots = assertion.contextsByWorktreeId.mapValues(\.rootPath)
        activityByWorktreeId = activityByWorktreeId.filter { desiredWorktreeIds.contains($0.key) }
        if let activePaneWorktreeId, !desiredWorktreeIds.contains(activePaneWorktreeId) {
            self.activePaneWorktreeId = nil
        }
    }

    func setActivity(worktreeId: UUID, isActiveInApp: Bool) async {
        activityByWorktreeId[worktreeId] = isActiveInApp
    }

    func setActivePaneWorktree(worktreeId: UUID?) async {
        activePaneWorktreeId = worktreeId
    }

    func snapshot() -> FilesystemSourceHarnessSnapshot {
        FilesystemSourceHarnessSnapshot(
            registeredRoots: registeredRoots,
            activityByWorktreeId: activityByWorktreeId,
            activePaneWorktreeId: activePaneWorktreeId,
            registerLog: registerLog,
            unregisterLog: unregisterLog
        )
    }
}

struct FilesystemSourceHarnessSnapshot: Sendable {
    let registeredRoots: [UUID: URL]
    let activityByWorktreeId: [UUID: Bool]
    let activePaneWorktreeId: UUID?
    let registerLog: [(worktreeId: UUID, repoId: UUID, rootPath: URL)]
    let unregisterLog: [UUID]
}

final class ControllableWatchedFolderScanSchedulerResults: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedPathIDs: [UUID] = []
    private var returnsPartialResults = false
    private var resultsByWatchedPathID: [UUID: [RepoScanner.RepoScanGroup]] = [:]

    var requestedWatchedPathIDs: [UUID] { lock.withLock { requestedPathIDs } }

    func setResults(_ resultsByWatchedPath: [WatchedPath: [RepoScanner.RepoScanGroup]], partial: Bool = false) {
        lock.withLock {
            returnsPartialResults = partial
            resultsByWatchedPathID = Dictionary(
                uniqueKeysWithValues: resultsByWatchedPath.map { watchedPath, groups in
                    (
                        watchedPath.id,
                        groups.map { group in
                            RepoScanner.RepoScanGroup(
                                clonePath: group.clonePath.standardizedFileURL,
                                linkedWorktreePaths: group.linkedWorktreePaths.map(\.standardizedFileURL)
                            )
                        }
                    )
                }
            )
        }
    }

    func makeScheduler() -> WatchedFolderScanScheduler {
        do {
            return try WatchedFolderScanScheduler(
                maximumConcurrentScans: 1,
                now: { .zero },
                validationExecutor: RepoScannerValidationExecutor(
                    validationClient: HarnessUnusedRepoDiscoveryReadClient()
                ),
                sessionFactory: { request, _ in
                    self.makeSession(for: request)
                }
            )
        } catch {
            preconditionFailure("invalid topology harness scheduler configuration: \(error)")
        }
    }

    private func makeSession(
        for request: WatchedFolderScanRequest
    ) -> WatchedFolderScannerSessionPort {
        lock.withLock { requestedPathIDs.append(request.sourceID.rootID) }
        let result = authoritativeResult(for: request.sourceID.rootID)
        return WatchedFolderScannerSessionPort(
            id: RepoScannerSessionID(rawValue: UUIDv7.generate()),
            advanceOneQuantum: { .finished(result) },
            cancel: { .alreadyFinished },
            consumeValidationCompletion: { _ in .rejected(.sessionFinished) }
        )
    }

    private func authoritativeResult(for watchedPathID: UUID) -> RepoScannerResult {
        let (configuredGroups, partial) = lock.withLock {
            (resultsByWatchedPathID[watchedPathID], returnsPartialResults)
        }
        guard let groups = configuredGroups else {
            Issue.record(
                "topology harness has no configured result for watched path \(watchedPathID)"
            )
            return .failed(
                FailedRepoScan(
                    reason: .scannerServiceFailed(
                        detail: "missing controlled watched-folder result"
                    ),
                    counts: RepoScannerEvidenceCounts(
                        directoryVisitCount: 0,
                        directoryTraversalFailureCount: 0,
                        entryMetadataFailureCount: 0,
                        gitCandidateCount: 0,
                        validationSuccessCount: 0,
                        validationAuthoritativeNegativeCount: 0,
                        validationTimeoutCount: 0,
                        validationCancellationCount: 0,
                        validationFailureCount: 1,
                        scannerServiceInvocationCount: 1
                    ),
                    serviceMetrics: .zero
                )
            )
        }
        let verifiedEntries = groups.flatMap { group in
            let repositoryKey = group.clonePath.standardizedFileURL.path
            return [
                RepoScanner.ResolvedGitEntry(
                    path: group.clonePath,
                    kind: .cloneRoot,
                    repositoryKey: repositoryKey
                )
            ]
                + group.linkedWorktreePaths.map { linkedWorktreePath in
                    RepoScanner.ResolvedGitEntry(
                        path: linkedWorktreePath,
                        kind: .linkedWorktree(parentClonePath: group.clonePath),
                        repositoryKey: repositoryKey
                    )
                }
        }
        let counts = RepoScannerEvidenceCounts(
            directoryVisitCount: 0, directoryTraversalFailureCount: 0, entryMetadataFailureCount: 0,
            gitCandidateCount: verifiedEntries.count, validationSuccessCount: verifiedEntries.count,
            validationAuthoritativeNegativeCount: 0, validationTimeoutCount: 0,
            validationCancellationCount: 0, validationFailureCount: partial ? 1 : 0, scannerServiceInvocationCount: 1
        )
        if partial {
            return .partial(
                PartialRepoScan(
                    verifiedEntries: verifiedEntries,
                    failures: .init(first: .scannerServiceFailed(detail: "controlled partial scan"), remaining: []),
                    counts: counts, serviceMetrics: .zero
                ))
        }
        return .completeAuthoritative(
            CompleteRepoScan(
                verifiedEntries: verifiedEntries, counts: counts, serviceMetrics: .zero
            ))
    }

}

private struct HarnessUnusedRepoDiscoveryReadClient: RepoDiscoveryReadClient {
    func validateDiscoveryCandidate(at candidateURL: URL) async -> GitRepositoryDiscoveryOutcome {
        .failure(.serviceFailed(detail: "unexpected harness validation request for \(candidateURL.path)"))
    }
}

@MainActor
struct GitTopologyPipelineHarness {
    let bus: EventBus<RuntimeEnvelope>
    let workspaceStore: WorkspaceStore
    let repoCache: RepoCacheAtom
    let coordinator: WorkspaceCacheCoordinator
    let workspaceSurfaceCoordinator: WorkspaceSurfaceCoordinator
    let discoveryActor: FilesystemActor
    let scanResults: ControllableWatchedFolderScanSchedulerResults
    let fseventClient: ControllableFSEventStreamClient
    let filesystemSource: RecordingFilesystemSourceHarness
    let tempDir: URL

    static func make() async -> Self {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "git-topology-harness-\(UUID().uuidString)")
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let scanResults = ControllableWatchedFolderScanSchedulerResults()
        let fseventClient = ControllableFSEventStreamClient()
        let discoveryActor = FilesystemActor(
            bus: bus,
            fseventStreamClient: fseventClient,
            watchedFolderScanScheduler: scanResults.makeScheduler(),
            debounceWindow: .zero,
            maxFlushLatency: .zero
        )
        let filesystemSource = RecordingFilesystemSourceHarness()
        let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let workspaceSurfaceCoordinator = WorkspaceSurfaceCoordinator(
            store: workspaceStore,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: workspaceStore),
            surfaceManager: HarnessSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: bus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: filesystemSource,
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            topologyEffectHandler: workspaceSurfaceCoordinator,
            validateSourceObservations: { observation in
                await discoveryActor.areCurrentWatchedFolderObservations(observation)
            },
            scopeSyncHandler: { change in
                switch change {
                case .updateRepositoryScanBaseline(let repositories, let revision):
                    await discoveryActor.updateRepositoryScanBaseline(repositories, membershipRevision: revision)
                case .updateWatchedFolders(let paths, let repositories, let revision):
                    _ = await discoveryActor.refreshWatchedFolders(
                        paths, restoring: repositories, membershipRevision: revision)
                case .registerForgeRepo, .unregisterForgeRepo, .refreshForgeRepo:
                    break
                }
            }
        )
        await coordinator.startConsuming()

        return Self(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            coordinator: coordinator,
            workspaceSurfaceCoordinator: workspaceSurfaceCoordinator,
            discoveryActor: discoveryActor,
            scanResults: scanResults,
            fseventClient: fseventClient,
            filesystemSource: filesystemSource,
            tempDir: tempDir
        )
    }

    func shutdown() async {
        await coordinator.shutdown()
        await workspaceSurfaceCoordinator.shutdown()
        await discoveryActor.shutdown()
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    func refreshWatchedFolders(_ watchedPaths: [WatchedPath]) async -> WatchedFolderRefreshSummary {
        for watchedPath in watchedPaths {
            do {
                try FileManager.default.createDirectory(
                    at: watchedPath.path,
                    withIntermediateDirectories: true
                )
            } catch {
                preconditionFailure(
                    "topology harness could not create watched root \(watchedPath.path.path): \(error)"
                )
            }
        }
        let topology = workspaceStore.repositoryTopologyAtom
        if case .prepared(let replacement) = RepositoryTopologyReplacement.prepare(
            repositories: topology.repos,
            watchedPaths: watchedPaths,
            unavailableRepositoryIDs: topology.unavailableRepoIds,
            stableIdentity: .derived(repositories: topology.repos, watchedPaths: watchedPaths),
            absenceRecords: topology.absenceRecords
        ) {
            topology.replaceTopology(replacement)
        }
        return await discoveryActor.refreshWatchedFolders(
            watchedPaths, restoring: workspaceStore.repos, membershipRevision: topology.worktreePathIndexGeneration
        )
    }

    func postTopology(_ event: TopologyEvent, source: SystemSource = .builtin(.filesystemWatcher)) async {
        _ = await bus.post(
            RuntimeEnvelopeHarness.topologyEnvelope(
                event: event,
                source: source
            )
        )
    }

    func filesystemSnapshot() async -> FilesystemSourceHarnessSnapshot {
        await filesystemSource.snapshot()
    }
}

@MainActor
struct GitEnrichmentPipelineHarness {
    private static let cacheApplyTickCadence = Duration.milliseconds(25)

    let bus: EventBus<RuntimeEnvelope>
    let workspaceStore: WorkspaceStore
    let repoCache: RepoCacheAtom
    let coordinator: WorkspaceCacheCoordinator
    let projector: GitWorkingDirectoryProjector
    let forgeActor: ForgeActor
    let forgeProjectionSubscriber: RecordingSubscriber<RuntimeEnvelope>
    let cacheApplyClock: TestPushClock
    let tempDir: URL

    static func make(
        gitProvider: some GitWorkingTreeStatusProvider,
        forgeProvider: some ForgeStatusProvider
    ) async -> Self {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "git-enrichment-harness-\(UUID().uuidString)")
        let bus = EventBus<RuntimeEnvelope>()
        let workspaceStore = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let cacheApplyClock = TestPushClock()
        let forgeProjectionSubscription = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "GitEnrichmentPipelineHarness.forgeProjection"
        )
        let forgeProjectionSubscriber = RecordingSubscriber(
            subscription: forgeProjectionSubscription
        )
        let coordinator = WorkspaceCacheCoordinator(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            scopeSyncHandler: { _ in },
            enrichmentApplyTickCadence: cacheApplyTickCadence,
            enrichmentApplyClock: cacheApplyClock
        )
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: gitProvider,
            coalescingWindow: .zero
        )
        let forgeActor = ForgeActor(
            bus: bus,
            statusProvider: forgeProvider,
            providerName: "stub"
        )
        await coordinator.startConsuming()
        return Self(
            bus: bus,
            workspaceStore: workspaceStore,
            repoCache: repoCache,
            coordinator: coordinator,
            projector: projector,
            forgeActor: forgeActor,
            forgeProjectionSubscriber: forgeProjectionSubscriber,
            cacheApplyClock: cacheApplyClock,
            tempDir: tempDir
        )
    }

    func start() async {
        await projector.start()
        await forgeActor.start()
    }

    @discardableResult
    func assertCanonicalProducerTopology() async -> FilesystemTopologyAssertion {
        let topology = workspaceStore.repositoryTopologyAtom
        let assertion = FilesystemTopologyAssertion(
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
        await projector.assertTopology(assertion)
        await forgeActor.assertObservationLifetimes(assertion)
        return assertion
    }

    func advanceCacheApplyTick() async {
        await cacheApplyClock.waitForPendingSleepCount(atLeast: 1)
        cacheApplyClock.advance(by: Self.cacheApplyTickCadence)
    }

    func waitForStableForgeProjection(repoId: UUID) async {
        _ = await forgeProjectionSubscriber.firstEvent { envelope in
            guard case .worktree(let worktreeEnvelope) = envelope,
                case .forge(
                    .pullRequestRepositoryProjectionChanged(
                        let eventRepoId,
                        let projection,
                        _
                    )
                ) = worktreeEnvelope.event,
                eventRepoId == repoId,
                case .stable(.ready) = projection
            else { return false }
            return true
        }
    }

    func synchronizeCacheCoordinator(repoId: UUID, worktreeId: UUID) async {
        guard let observationLifetime = workspaceStore.repositoryTopologyAtom.worktreeObservationLifetimes[worktreeId]
        else {
            Issue.record("cache ordering barrier requires a canonical worktree lifetime")
            return
        }
        _ = await bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .statusOutcome(
                            GitStatusOutcomeFact(
                                worktreeId: worktreeId,
                                repoId: repoId,
                                outcome: .completed,
                                reason: nil,
                                consecutiveFailureCount: 0
                            )
                        )
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    source: .system(.builtin(.gitWorkingDirectoryProjector)),
                    observationLifetime: .worktree(observationLifetime)
                )
            )
        )
        await assertEventuallyAsync("cache coordinator should consume its ordering barrier") {
            let diagnostics = await bus.diagnosticsSnapshot()
            return diagnostics.activeSubscribers.contains { subscriber in
                subscriber.subscriberName == "WorkspaceCacheCoordinator"
                    && subscriber.pendingDeliveryCount == 0
            }
        }
    }

    func shutdown() async {
        await coordinator.shutdown()
        await projector.shutdown()
        await forgeActor.shutdown()
        await forgeProjectionSubscriber.shutdown()
        try? FileManager.default.removeItem(at: tempDir)
    }
}
