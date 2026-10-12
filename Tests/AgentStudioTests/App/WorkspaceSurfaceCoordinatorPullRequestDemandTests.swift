import Foundation
import GhosttyKit
import Observation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

private final class RepositoryFactDemandObservationCounter: @unchecked Sendable {
    private(set) var invalidationCount = 0

    func record() {
        invalidationCount += 1
    }
}

@MainActor
@Suite("WorkspaceSurfaceCoordinator pull request demand", .serialized, .timeLimit(.minutes(1)))
struct WorkspaceSurfaceCoordinatorPullRequestDemandTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("repository fact demand observes only semantic pane inputs")
    func repositoryFactDemandObservationIsNarrow() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let repository = store.addRepo(at: URL(fileURLWithPath: "/tmp/repository-demand-observation"))
            let worktree = try #require(repository.worktrees.first)
            let associatedPane = store.createPane(
                launchDirectory: worktree.path,
                facets: PaneContextFacets(
                    repoId: repository.id,
                    worktreeId: worktree.id,
                    cwd: worktree.path
                )
            )
            let unassociatedPane = store.createPane(
                launchDirectory: URL(fileURLWithPath: "/tmp/repository-demand-unassociated")
            )
            let tab = Tab(paneId: associatedPane.id)
            store.appendTab(tab)
            let unrelatedDrawerPane = try #require(
                store.paneAtom.addDrawerPane(
                    to: unassociatedPane.id,
                    parentFallbackCWD: unassociatedPane.metadata.launchDirectory,
                    zmxSessionID: .generateUUIDv7()
                )
            )
            _ = try #require(
                store.paneAtom.addDrawerPane(
                    to: associatedPane.id,
                    parentFallbackCWD: associatedPane.metadata.launchDirectory,
                    zmxSessionID: .generateUUIDv7()
                )
            )

            let source = PullRequestDemandRecordingFilesystemSource()
            let windowLifecycle = WindowLifecycleAtom()
            let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
            let coordinator = makePullRequestDemandCoordinator(
                store: store,
                source: source,
                windowLifecycleStore: windowLifecycle,
                gitStatusPhysicalGate: gitStatusPhysicalGate
            )

            let cwdObservation = observeRepositoryFactDemand(coordinator)
            store.paneAtom.updatePaneCWD(
                associatedPane.id,
                cwd: worktree.path.appending(path: "Sources")
            )
            #expect(cwdObservation.invalidationCount == 0)

            let contentObservation = observeRepositoryFactDemand(coordinator)
            store.paneAtom.graphAtom.updatePaneWebviewState(
                associatedPane.id,
                state: WebviewState(url: URL(string: "https://example.com/updated")!)
            )
            #expect(contentObservation.invalidationCount == 0)

            let unrelatedDrawerObservation = observeRepositoryFactDemand(coordinator)
            _ = try #require(
                store.paneAtom.detachDrawerPane(
                    unrelatedDrawerPane.id,
                    from: unassociatedPane.id
                )
            )
            #expect(unrelatedDrawerObservation.invalidationCount == 0)

            let unassociatedResidencyObservation = observeRepositoryFactDemand(coordinator)
            store.paneAtom.graphAtom.setResidency(.backgrounded, for: unassociatedPane.id)
            #expect(unassociatedResidencyObservation.invalidationCount == 0)

            let associatedResidencyObservation = observeRepositoryFactDemand(coordinator)
            store.paneAtom.graphAtom.setResidency(.backgrounded, for: associatedPane.id)
            #expect(associatedResidencyObservation.invalidationCount == 1)

            await coordinator.shutdown()
        }
    }

    private func observeRepositoryFactDemand(
        _ coordinator: WorkspaceSurfaceCoordinator
    ) -> RepositoryFactDemandObservationCounter {
        let counter = RepositoryFactDemandObservationCounter()
        withObservationTracking {
            _ = coordinator.captureRepositoryFactDemandInput()
        } onChange: {
            counter.record()
        }
        return counter
    }

    @Test("visible active tab and sidebar demand is content-distinct and clears with the window")
    func visibleDemandTracksTabSidebarAndWindow() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore()
            let firstRepo = store.addRepo(at: URL(fileURLWithPath: "/tmp/pr-demand-first"))
            let firstWorktree = try #require(firstRepo.worktrees.first)
            let firstPane = store.createPane(
                launchDirectory: firstWorktree.path,
                facets: PaneContextFacets(
                    repoId: firstRepo.id,
                    worktreeId: firstWorktree.id,
                    cwd: firstWorktree.path
                )
            )
            let firstTab = Tab(paneId: firstPane.id)
            store.appendTab(firstTab)

            let secondRepo = store.addRepo(at: URL(fileURLWithPath: "/tmp/pr-demand-second"))
            let secondWorktree = try #require(secondRepo.worktrees.first)
            let secondPane = store.createPane(
                launchDirectory: secondWorktree.path,
                facets: PaneContextFacets(
                    repoId: secondRepo.id,
                    worktreeId: secondWorktree.id,
                    cwd: secondWorktree.path
                )
            )
            let secondTab = Tab(paneId: secondPane.id)
            store.appendTab(secondTab)
            store.setActiveTab(firstTab.id)

            let source = PullRequestDemandRecordingFilesystemSource()
            let windowLifecycle = WindowLifecycleAtom()
            let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: ViewRegistry(),
                runtime: SessionRuntime(store: store),
                surfaceManager: PullRequestDemandSurfaceManager(),
                terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
                terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: EventBus<RuntimeEnvelope>(),
                gitWorkingTreeStatusProvider: AgentStudioGitWorkingTreeStatusProvider(
                    physicalGate: gitStatusPhysicalGate
                ),
                gitStatusPhysicalGate: gitStatusPhysicalGate,
                filesystemSource: source,
                windowLifecycleStore: windowLifecycle,
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
            let owningWindowId = UUIDv7.generate()
            coreAtoms.applicationEntityRecency.hydrate([])
            coreAtoms.sidebarVisibleWorktreesRuntime.setVisibleWorktreeIds([])
            coordinator.bindPullRequestDemand(toOwningWindowId: owningWindowId)
            #expect(await source.waitForLastSnapshot([]))

            windowLifecycle.recordWindowRegistered(owningWindowId)
            windowLifecycle.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: owningWindowId
            )
            #expect(await source.waitForLastSnapshot([firstWorktree.id, secondWorktree.id]))

            let snapshotCountBeforeViewportChange = await source.snapshotCount
            let viewportOnlyWorktreeId = UUIDv7.generate()
            coreAtoms.sidebarVisibleWorktreesRuntime.setVisibleWorktreeIds([viewportOnlyWorktreeId])
            await Task.yield()
            #expect(await source.snapshotCount == snapshotCountBeforeViewportChange)

            store.setActiveTab(secondTab.id)
            #expect(
                await source.waitForLastSnapshot([firstWorktree.id, secondWorktree.id])
            )

            await source.suspendNextSnapshot([])
            windowLifecycle.recordWindowPresentation(
                WindowPresentationFacts(isVisible: false, isMiniaturized: false, isOccluded: true),
                for: owningWindowId
            )
            #expect(await source.waitForLastSnapshot([]))
            let settlementTask = Task { @MainActor in
                await coordinator.settleRepositoryFactDemandAdmissionForPerformanceProof()
            }
            await Task.yield()
            #expect(await source.repositoryFactDemandAdmissionSettlementCount == 0)
            await source.releaseSuspendedSnapshot()
            await settlementTask.value
            #expect(await source.repositoryFactDemandAdmissionSettlementCount == 1)

            coreAtoms.sidebarVisibleWorktreesRuntime.setVisibleWorktreeIds([])
            await coordinator.shutdown()
        }
    }

    @Test("backgrounded canonical pane does not create visible repository fact demand")
    func backgroundedCanonicalPaneIsExcludedFromVisibleDemand() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore()
            let visibleRepository = store.addRepo(
                at: URL(fileURLWithPath: "/tmp/repository-demand-visible-pane")
            )
            let visibleWorktree = try #require(visibleRepository.worktrees.first)
            let visiblePane = store.createPane(
                launchDirectory: visibleWorktree.path,
                facets: PaneContextFacets(
                    repoId: visibleRepository.id,
                    worktreeId: visibleWorktree.id,
                    cwd: visibleWorktree.path
                )
            )
            let backgroundedRepository = store.addRepo(
                at: URL(fileURLWithPath: "/tmp/repository-demand-backgrounded-pane")
            )
            let backgroundedWorktree = try #require(backgroundedRepository.worktrees.first)
            let backgroundedPane = store.createPane(
                launchDirectory: backgroundedWorktree.path,
                facets: PaneContextFacets(
                    repoId: backgroundedRepository.id,
                    worktreeId: backgroundedWorktree.id,
                    cwd: backgroundedWorktree.path
                )
            )
            let tab = Tab(paneId: visiblePane.id)
            store.appendTab(tab)
            #expect(
                store.insertPane(
                    backgroundedPane.id,
                    inTab: tab.id,
                    at: visiblePane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
            store.setActivePane(backgroundedPane.id, inTab: tab.id)
            #expect(store.mutationCoordinator.backgroundPane(backgroundedPane.id))
            #expect(store.tab(tab.id)?.activePaneId == backgroundedPane.id)
            coreAtoms.workspaceSidebarState.setSidebarCollapsed(true)

            let source = PullRequestDemandRecordingFilesystemSource()
            let windowLifecycle = WindowLifecycleAtom()
            let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
            let coordinator = makePullRequestDemandCoordinator(
                store: store,
                source: source,
                windowLifecycleStore: windowLifecycle,
                gitStatusPhysicalGate: gitStatusPhysicalGate
            )
            let owningWindowId = UUIDv7.generate()
            windowLifecycle.recordWindowRegistered(owningWindowId)
            windowLifecycle.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: owningWindowId
            )

            coordinator.bindPullRequestDemand(toOwningWindowId: owningWindowId)
            await coordinator.settleRepositoryFactDemandAdmissionForPerformanceProof()

            let demand = try #require(await source.lastFactDemandSnapshot)
            #expect(demand.activePaneWorktreeId == visibleWorktree.id)
            #expect(demand.visibleActiveTabWorktreeIds == [visibleWorktree.id])
            #expect(demand.openWorktreeIds == [visibleWorktree.id])
            #expect(demand.warmRepositoryIds == [visibleRepository.id])
            #expect(demand.localGitAttentionWorktreeIds == [visibleWorktree.id])
            #expect(demand.forgeDemandedWorktreeIds == [visibleWorktree.id])

            #expect(
                store.mutationCoordinator.reactivatePane(
                    backgroundedPane.id,
                    inTab: tab.id,
                    at: visiblePane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
            for _ in 0..<400
            where await source.lastFactDemandSnapshot?.openWorktreeIds
                != [visibleWorktree.id, backgroundedWorktree.id]
            {
                await Task.yield()
            }
            let reactivatedDemand = try #require(await source.lastFactDemandSnapshot)
            #expect(reactivatedDemand.openWorktreeIds == [visibleWorktree.id, backgroundedWorktree.id])
            #expect(
                reactivatedDemand.warmRepositoryIds
                    == [visibleRepository.id, backgroundedRepository.id]
            )

            await coordinator.shutdown()
        }
    }

    @Test("repository fact demand classifies activity through sealed topology identity")
    func repositoryFactDemandUsesSealedTopologyIdentity() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            // Arrange
            let store = WorkspaceStore()
            let repository = store.addRepo(at: URL(fileURLWithPath: "/tmp/pr-demand-sealed-identity"))
            let worktree = try #require(repository.worktrees.first)
            let repositoryStableKey = "1111222233334444"
            let topologyPreparation = RepositoryTopologyReplacement.prepare(
                repositories: store.repositoryTopologyAtom.repos,
                watchedPaths: store.repositoryTopologyAtom.watchedPaths,
                unavailableRepositoryIDs: [],
                stableIdentity: RepositoryTopologyStableIdentity(
                    repositoryStableKeysByID: [repository.id: repositoryStableKey],
                    worktreeStableKeysByID: [worktree.id: repositoryStableKey],
                    watchedPathStableKeysByID: store.repositoryTopologyAtom.watchedPathStableKeysByID
                )
            )
            guard case .prepared(let replacement) = topologyPreparation else {
                Issue.record("expected supplied stable identity to prepare")
                return
            }
            store.repositoryTopologyAtom.replaceTopology(replacement)

            let referenceDate = Date()
            coreAtoms.repositoryLocalActivity.publishAuthoritative(
                RepositoryLocalActivitySnapshot(
                    activityByRepositoryStableKey: [
                        repositoryStableKey: try RepositoryLocalActivity(
                            repositoryStableKey: repositoryStableKey,
                            lastQualifyingActivityAt: referenceDate,
                            continuousCoverageStartedAt: referenceDate.addingTimeInterval(-1),
                            updatedAt: referenceDate,
                            ownedPromotionAttemptID: nil,
                            ownedPromotionStartedAt: nil,
                            ownedPromotionUnsettled: false
                        )
                    ],
                    cursorByVolumeIdentifier: [:]
                )
            )

            let source = PullRequestDemandRecordingFilesystemSource()
            let windowLifecycle = WindowLifecycleAtom()
            let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: ViewRegistry(),
                runtime: SessionRuntime(store: store),
                surfaceManager: PullRequestDemandSurfaceManager(),
                terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
                terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: EventBus<RuntimeEnvelope>(),
                gitWorkingTreeStatusProvider: AgentStudioGitWorkingTreeStatusProvider(
                    physicalGate: gitStatusPhysicalGate
                ),
                gitStatusPhysicalGate: gitStatusPhysicalGate,
                filesystemSource: source,
                windowLifecycleStore: windowLifecycle,
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
            let owningWindowId = UUIDv7.generate()
            windowLifecycle.recordWindowRegistered(owningWindowId)
            windowLifecycle.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: owningWindowId
            )

            // Act
            coordinator.bindPullRequestDemand(toOwningWindowId: owningWindowId)
            await coordinator.settleRepositoryFactDemandAdmissionForPerformanceProof()

            // Assert
            #expect(await source.lastSnapshot == [worktree.id])

            await coordinator.shutdown()
        }
    }

    @Test("same-ID stable identity replacement retargets repository fact demand")
    func sameIDStableIdentityReplacementRetargetsRepositoryFactDemand() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            // Arrange
            let store = WorkspaceStore()
            let repository = store.addRepo(
                at: URL(fileURLWithPath: "/tmp/pr-demand-replaced-stable-identity")
            )
            let worktree = try #require(repository.worktrees.first)
            let originalStableKey = "aaaaaaaaaaaaaaaa"
            let replacementStableKey = "bbbbbbbbbbbbbbbb"
            let originalPreparation = RepositoryTopologyReplacement.prepare(
                repositories: store.repositoryTopologyAtom.repos,
                watchedPaths: store.repositoryTopologyAtom.watchedPaths,
                unavailableRepositoryIDs: [],
                stableIdentity: RepositoryTopologyStableIdentity(
                    repositoryStableKeysByID: [repository.id: originalStableKey],
                    worktreeStableKeysByID: [worktree.id: originalStableKey],
                    watchedPathStableKeysByID: store.repositoryTopologyAtom.watchedPathStableKeysByID
                )
            )
            guard case .prepared(let originalReplacement) = originalPreparation else {
                Issue.record("expected original stable identity to prepare")
                return
            }
            store.repositoryTopologyAtom.replaceTopology(originalReplacement)

            let referenceDate = Date()
            coreAtoms.repositoryLocalActivity.publishAuthoritative(
                RepositoryLocalActivitySnapshot(
                    activityByRepositoryStableKey: [
                        originalStableKey: try RepositoryLocalActivity(
                            repositoryStableKey: originalStableKey,
                            lastQualifyingActivityAt: referenceDate,
                            continuousCoverageStartedAt: referenceDate.addingTimeInterval(-1),
                            updatedAt: referenceDate,
                            ownedPromotionAttemptID: nil,
                            ownedPromotionStartedAt: nil,
                            ownedPromotionUnsettled: false
                        )
                    ],
                    cursorByVolumeIdentifier: [:]
                )
            )

            let source = PullRequestDemandRecordingFilesystemSource()
            let windowLifecycle = WindowLifecycleAtom()
            let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: ViewRegistry(),
                runtime: SessionRuntime(store: store),
                surfaceManager: PullRequestDemandSurfaceManager(),
                terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
                terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: EventBus<RuntimeEnvelope>(),
                gitWorkingTreeStatusProvider: AgentStudioGitWorkingTreeStatusProvider(
                    physicalGate: gitStatusPhysicalGate
                ),
                gitStatusPhysicalGate: gitStatusPhysicalGate,
                filesystemSource: source,
                windowLifecycleStore: windowLifecycle,
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
            let owningWindowId = UUIDv7.generate()
            windowLifecycle.recordWindowRegistered(owningWindowId)
            windowLifecycle.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: owningWindowId
            )

            // Act
            coordinator.bindPullRequestDemand(toOwningWindowId: owningWindowId)

            // Assert
            #expect(await source.waitForLastSnapshot([worktree.id]))
            #expect(await source.lastFactDemandSnapshot?.warmRepositoryIds == [repository.id])

            let replacementPreparation = RepositoryTopologyReplacement.prepare(
                repositories: store.repositoryTopologyAtom.repos,
                watchedPaths: store.repositoryTopologyAtom.watchedPaths,
                unavailableRepositoryIDs: [],
                stableIdentity: RepositoryTopologyStableIdentity(
                    repositoryStableKeysByID: [repository.id: replacementStableKey],
                    worktreeStableKeysByID: [worktree.id: replacementStableKey],
                    watchedPathStableKeysByID: store.repositoryTopologyAtom.watchedPathStableKeysByID
                )
            )
            guard case .prepared(let identityReplacement) = replacementPreparation else {
                Issue.record("expected replacement stable identity to prepare")
                return
            }

            // Act
            store.repositoryTopologyAtom.replaceTopology(identityReplacement)

            // Assert
            #expect(await source.waitForLastSnapshot([]))
            #expect(await source.lastFactDemandSnapshot?.unknownRepositoryIds == [repository.id])
            #expect(await source.lastFactDemandSnapshot?.warmRepositoryIds.isEmpty == true)

            await coordinator.shutdown()
        }
    }

    private func makePullRequestDemandCoordinator(
        store: WorkspaceStore,
        source: PullRequestDemandRecordingFilesystemSource,
        windowLifecycleStore: WindowLifecycleAtom,
        gitStatusPhysicalGate: AgentStudioGitStatusPhysicalGate
    ) -> WorkspaceSurfaceCoordinator {
        WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: PullRequestDemandSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeStatusProvider: AgentStudioGitWorkingTreeStatusProvider(
                physicalGate: gitStatusPhysicalGate
            ),
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: source,
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }

}

private actor PullRequestDemandRecordingFilesystemSource: WorkspaceFilesystemSourceManaging {
    private var demandSnapshots: [Set<UUID>] = []
    private var factDemandSnapshots: [RepositoryFactDemandSnapshot] = []
    private var snapshotWaiters: [UUID: AsyncStream<Set<UUID>>.Continuation] = [:]
    private var suspendedSnapshot: Set<UUID>?
    private var suspendedSnapshotContinuation: CheckedContinuation<Void, Never>?
    private(set) var repositoryFactDemandAdmissionSettlementCount = 0

    var snapshotCount: Int { demandSnapshots.count }
    var lastSnapshot: Set<UUID>? { demandSnapshots.last }
    var lastFactDemandSnapshot: RepositoryFactDemandSnapshot? { factDemandSnapshots.last }

    func start() async {}
    func shutdown() async {}
    func register(worktreeId: UUID, repoId: UUID, rootPath: URL) async {}
    func unregister(worktreeId: UUID) async {}
    func assertTopology(_ assertion: FilesystemTopologyAssertion) async {}
    func setActivity(worktreeId: UUID, isActiveInApp: Bool) async {}
    func setActivePaneWorktree(worktreeId: UUID?) async {}
    func setSidebarVisibleWorktrees(_ worktreeIds: Set<UUID>) async {}

    func setPullRequestDemandWorktrees(_ worktreeIds: Set<UUID>) async {
        demandSnapshots.append(worktreeIds)
        for waiter in snapshotWaiters.values {
            waiter.yield(worktreeIds)
        }
        if suspendedSnapshot == worktreeIds {
            suspendedSnapshot = nil
            await withCheckedContinuation { continuation in
                suspendedSnapshotContinuation = continuation
            }
        }
    }

    func setRepositoryFactDemand(_ snapshot: RepositoryFactDemandSnapshot) async {
        factDemandSnapshots.append(snapshot)
        await setPullRequestDemandWorktrees(snapshot.forgeDemandedWorktreeIds)
    }

    func waitForRepositoryFactDemandAdmission() async {
        repositoryFactDemandAdmissionSettlementCount += 1
    }

    func suspendNextSnapshot(_ worktreeIds: Set<UUID>) {
        suspendedSnapshot = worktreeIds
    }

    func releaseSuspendedSnapshot() {
        suspendedSnapshotContinuation?.resume()
        suspendedSnapshotContinuation = nil
    }

    func waitForLastSnapshot(_ expected: Set<UUID>) async -> Bool {
        if demandSnapshots.last == expected { return true }
        let waiterId = UUIDv7.generate()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Set<UUID>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        snapshotWaiters[waiterId] = continuation
        defer {
            snapshotWaiters.removeValue(forKey: waiterId)
            continuation.finish()
        }
        for await snapshot in stream where snapshot == expected {
            return true
        }
        return false
    }
}

@MainActor
private final class PullRequestDemandSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    private let cwdChanges = AsyncStream<SurfaceManager.SurfaceCWDChangeEvent> { continuation in
        continuation.finish()
    }

    var surfaceCWDChanges: AsyncStream<SurfaceManager.SurfaceCWDChangeEvent> { cwdChanges }

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? { nil }
    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }
    func destroy(_ surfaceId: UUID) {}
}
