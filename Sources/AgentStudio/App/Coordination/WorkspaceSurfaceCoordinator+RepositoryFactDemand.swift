import AgentStudioCore
import Foundation
import Observation

@MainActor
extension WorkspaceSurfaceCoordinator {
    func bindPullRequestDemand(toOwningWindowId windowId: UUID) {
        repositoryFactDemandOwningWindowId = windowId
        restartRepositoryFactDemandObservation()
    }

    func stopRepositoryFactDemandObservation() {
        repositoryFactDemandObservationGeneration &+= 1
    }

    func settleRepositoryFactDemandAdmissionForPerformanceProof() async {
        repositoryFactDemandCoordinator.accept(captureRepositoryFactDemandInput())
        await repositoryFactDemandCoordinator.waitUntilIdle()
        await filesystemSource.waitForRepositoryFactDemandAdmission()
    }

    func gitLogicalDebtSnapshotForPerformanceProof() async -> GitLogicalDebtSnapshot? {
        guard let pipeline = filesystemSource as? FilesystemGitPipeline else { return nil }
        return await pipeline.gitLogicalDebtSnapshot()
    }

    private func restartRepositoryFactDemandObservation() {
        repositoryFactDemandObservationGeneration &+= 1
        observeRepositoryFactDemand(generation: repositoryFactDemandObservationGeneration)
    }

    private func observeRepositoryFactDemand(generation: UInt64) {
        let input = withObservationTracking {
            captureRepositoryFactDemandInput()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self,
                    self.repositoryFactDemandObservationGeneration == generation
                else { return }
                self.observeRepositoryFactDemand(generation: generation)
            }
        }
        repositoryFactDemandCoordinator.accept(input)
    }

    func captureRepositoryFactDemandInput() -> RepositoryFactDemandInput {
        let paneGraph = store.paneAtom.graphAtom
        let topology = store.repositoryTopologyAtom
        let repositoryLocalActivity = atom(\.repositoryLocalActivity)
        let associationByPaneId = Dictionary(
            uniqueKeysWithValues: paneGraph.repositoryAssociationPaneIds.compactMap { paneId in
                paneGraph.repositoryAssociation(for: paneId).map { (paneId, $0) }
            }
        )
        let openWorktreeIds = paneGraph.activeRepositoryAssociationWorktreeIDs(
            in: associationByPaneId
        )
        let membershipWorktreeIds = topology.repositoryMembershipWorktreeIds
        let repositoryIdByWorktreeId = Dictionary(
            uniqueKeysWithValues: membershipWorktreeIds.compactMap { worktreeId in
                topology.repositoryId(containing: worktreeId).map { (worktreeId, $0) }
            }
        )
        let windowPresentation = repositoryFactDemandWindowPresentation()
        let sidebarIsAttended =
            windowPresentation == .visible
            && !atom(\.workspaceSidebarState).sidebarCollapsed
        let activePaneWorktreeId = store.tabLayoutAtom.activeTabId
            .flatMap { activeTabID in
                effectiveActivePaneID(
                    forTab: activeTabID,
                    paneGraph: paneGraph
                )
            }
            .flatMap { associationByPaneId[$0]?.worktreeId }
        let repositoryIDs = topology.repositoryIdsInOrder
        var worktreeStableKeysByRepositoryID: [UUID: [UUID: String]] = [:]
        for worktreeID in membershipWorktreeIds {
            guard
                let repositoryID = repositoryIdByWorktreeId[worktreeID],
                let worktreeStableKey = topology.worktreeStableKey(for: worktreeID)
            else { continue }
            worktreeStableKeysByRepositoryID[repositoryID, default: [:]][worktreeID] = worktreeStableKey
        }
        let activityTopology: [RepositoryActivityTopology] = repositoryIDs.compactMap { repositoryID in
            guard let repositoryStableKey = topology.repositoryStableKey(for: repositoryID) else { return nil }
            return RepositoryActivityTopology(
                repositoryID: repositoryID,
                repositoryStableKey: repositoryStableKey,
                worktreeStableKeysByID: worktreeStableKeysByRepositoryID[repositoryID] ?? [:]
            )
        }
        let repositoryLocalActivityByStableKey = Dictionary(
            uniqueKeysWithValues: activityTopology.compactMap { repository in
                repositoryLocalActivity.activity(for: repository.repositoryStableKey).map {
                    (repository.repositoryStableKey, $0)
                }
            }
        )

        return RepositoryFactDemandInput(
            activePaneWorktreeId: activePaneWorktreeId,
            sidebarAttendedWorktreeIds: sidebarIsAttended ? membershipWorktreeIds : [],
            visibleActiveTabWorktreeIds: visibleActiveTabWorktreeIds(
                windowPresentation: windowPresentation,
                associationByPaneId: associationByPaneId
            ),
            openWorktreeIds: openWorktreeIds,
            repositoryIdByWorktreeId: repositoryIdByWorktreeId,
            activityTopology: activityTopology,
            localActivityHydrationDisposition: repositoryLocalActivity.hydrationDisposition,
            repositoryLocalActivityByStableKey: repositoryLocalActivityByStableKey
        )
    }

    private func repositoryFactDemandWindowPresentation() -> PullRequestDemandProjection.WindowPresentation {
        let windowFacts =
            repositoryFactDemandOwningWindowId
            .flatMap(windowLifecycleStore.presentationFacts(for:))
            ?? .hidden
        if !windowFacts.isVisible { return .hidden }
        if windowFacts.isMiniaturized { return .miniaturized }
        if windowFacts.isOccluded { return .occluded }
        return .visible
    }

    private func visibleActiveTabWorktreeIds(
        windowPresentation: PullRequestDemandProjection.WindowPresentation,
        associationByPaneId: [UUID: PaneRepositoryAssociation]
    ) -> Set<UUID> {
        guard let activeTabId = store.tabLayoutAtom.activeTabId,
            let activeLayout = store.tabLayoutAtom.canonicalActiveLayout(forTab: activeTabId)
        else { return [] }
        let paneGraph = store.paneAtom.graphAtom
        var activeLayoutPaneIds = Set<UUID>(
            activeLayout.paneIds.compactMap { paneID in
                guard associationByPaneId[paneID]?.worktreeId != nil,
                    paneGraph.paneResidency(paneID)?.isActive == true
                else { return nil }
                return paneID
            }
        )
        var relevantPaneIds = activeLayoutPaneIds
        let expandedDrawer: PullRequestDemandProjection.ExpandedDrawer? = {
            guard let drawerID = store.paneAtom.expandedDrawerID,
                let parentPaneID = paneGraph.parentPaneID(containingDrawer: drawerID),
                activeLayout.contains(parentPaneID),
                paneGraph.paneResidency(parentPaneID)?.isActive == true,
                let drawerLayout = store.tabLayoutAtom.canonicalActiveDrawerLayout(
                    drawerID: drawerID,
                    forTab: activeTabId
                )
            else { return nil }
            let activeDrawerPaneIDs = Set<UUID>(
                drawerLayout.layout.paneIds.compactMap { paneID in
                    guard associationByPaneId[paneID]?.worktreeId != nil,
                        paneGraph.paneResidency(paneID)?.isActive == true
                    else { return nil }
                    return paneID
                }
            )
            activeLayoutPaneIds.insert(parentPaneID)
            relevantPaneIds.formUnion(activeDrawerPaneIDs)
            return PullRequestDemandProjection.ExpandedDrawer(
                parentPaneId: parentPaneID,
                paneIds: activeDrawerPaneIDs,
                minimizedPaneIds: drawerLayout.minimizedPaneIDs.intersection(activeDrawerPaneIDs)
            )
        }()
        let zoom = store.panePresentationAtom.zoomPresentation(forTab: activeTabId).map { presentation in
            let companionWorktreeId: UUID? = {
                guard case .retainedVisible(let companionPaneId) = presentation.viewerPresentation,
                    let companion = store.panePresentationAtom.zoomCompanion(
                        forSourcePane: presentation.sourcePaneId
                    ),
                    companion.owningTabId == activeTabId,
                    companion.companionPaneId == companionPaneId
                else { return nil }
                return companion.resolvedWorktreeId
            }()
            return PullRequestDemandProjection.Zoom(
                sourcePaneId: presentation.sourcePaneId,
                visibleCompanionWorktreeId: companionWorktreeId
            )
        }
        let worktreeIdByPaneId = [UUID: UUID](
            uniqueKeysWithValues: relevantPaneIds.compactMap { paneId in
                associationByPaneId[paneId]?.worktreeId.map { (paneId, $0) }
            }
        )
        return PullRequestDemandProjection.worktreeIds(
            from: .init(
                windowPresentation: windowPresentation,
                sidebarWorktreeIds: [],
                activeLayoutPaneIds: activeLayoutPaneIds,
                minimizedLayoutPaneIds: store.tabLayoutAtom
                    .canonicalActiveMinimizedPaneIDs(forTab: activeTabId)
                    .intersection(activeLayoutPaneIds),
                isManagementLayerActive: atom(\.managementLayer).isActive,
                expandedDrawer: expandedDrawer,
                zoom: zoom,
                worktreeIdByPaneId: worktreeIdByPaneId
            )
        )
    }

    private func effectiveActivePaneID(
        forTab tabID: UUID,
        paneGraph: WorkspacePaneGraphAtom
    ) -> UUID? {
        guard let layout = store.tabLayoutAtom.canonicalActiveLayout(forTab: tabID) else {
            return nil
        }
        if let preferredPaneID = store.tabLayoutAtom.activePaneID(forTab: tabID),
            paneGraph.paneResidency(preferredPaneID)?.isActive == true
        {
            return preferredPaneID
        }
        return layout.paneIds.first { paneGraph.paneResidency($0)?.isActive == true }
    }
}
