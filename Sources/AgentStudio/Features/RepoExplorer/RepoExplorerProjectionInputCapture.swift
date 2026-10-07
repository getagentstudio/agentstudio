import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// MainActor source capture owned by the Repo Explorer projection adapter.
///
/// This type reads canonical owners and produces immutable projection work. It
/// does not schedule, admit, execute, or publish projection work; those state
/// transitions remain in `RepoExplorerProjectionAdapter`.
@MainActor
final class RepoExplorerProjectionInputCapture {
    let store: WorkspaceStore
    let preferences: RepoExplorerSidebarPrefsAtom
    let repoCache: RepoCacheAtom
    let sidebarState: WorkspaceSidebarState
    let sidebarCache: SidebarCacheState
    let coreAtoms: CoreAtoms
    let bridgeAttendanceSnapshot: BridgeAttendanceSnapshot
    let latestPaneMessageSnapshot: LatestPaneMessageSnapshot
    let sessionStatusForPane: RepoExplorerSessionStatusReader
    let contextDisplayForPane: RepoExplorerContextDisplayReader
    let continuousNow: @Sendable () -> ContinuousClock.Instant
    let wallNow: @Sendable () -> Date

    private var paneDisplayTitleCache = RepoExplorerPaneDisplayTitleCache()
    private(set) var fullCaptureCount = 0
    var presentationCaptureCount = 0
    var scopedCaptureCount = 0
    private(set) var paneFactCaptureCount = 0

    var isRepoSurfaceVisible: Bool {
        sidebarState.sidebarSurface != .inbox
    }

    init(
        store: WorkspaceStore,
        preferences: RepoExplorerSidebarPrefsAtom,
        repoCache: RepoCacheAtom,
        sidebarState: WorkspaceSidebarState,
        sidebarCache: SidebarCacheState,
        coreAtoms: CoreAtoms,
        bridgeAttendanceSnapshot: @escaping BridgeAttendanceSnapshot,
        latestPaneMessageSnapshot: @escaping LatestPaneMessageSnapshot,
        sessionStatusForPane: @escaping RepoExplorerSessionStatusReader = { _ in nil },
        contextDisplayForPane: @escaping RepoExplorerContextDisplayReader = { _ in nil },
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        wallNow: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.preferences = preferences
        self.repoCache = repoCache
        self.sidebarState = sidebarState
        self.sidebarCache = sidebarCache
        self.coreAtoms = coreAtoms
        self.bridgeAttendanceSnapshot = bridgeAttendanceSnapshot
        self.latestPaneMessageSnapshot = latestPaneMessageSnapshot
        self.sessionStatusForPane = sessionStatusForPane
        self.contextDisplayForPane = contextDisplayForPane
        self.continuousNow = continuousNow
        self.wallNow = wallNow
    }

    static func observeRepoEnrichmentInputs(
        repositoryIDs: [UUID],
        repoCache: RepoCacheAtom
    ) -> Int {
        for repositoryID in repositoryIDs {
            _ = repoCache.repoEnrichment(for: repositoryID)
        }
        return repositoryIDs.count
    }

    func captureRequest(
        query: String,
        referenceDate: Date,
        trigger: AppPolicies.SidebarProjection.Trigger
    ) -> RepoExplorerProjectionRequest {
        fullCaptureCount += 1
        let repos = sidebarRepos()
        let worktreeEnrichmentSnapshot = Self.worktreeEnrichmentSnapshot(
            for: repos.flatMap(\.worktrees).map(\.id),
            repoCache: repoCache
        )
        let surface = sidebarState.sidebarSurface
        let groupingMode = preferences.groupingMode(for: surface)
        let repositoryIDs = Set(repos.map(\.id))
        let repositoryActivityInputs = captureRepositoryActivityInputs(
            for: repos,
            surface: surface
        )
        let snapshot = makeSidebarSnapshot(
            repos: repos,
            repoEnrichmentByRepoId: Dictionary(
                uniqueKeysWithValues: repos.compactMap { repo in
                    repoCache.repoEnrichment(for: repo.id).map { (repo.id, $0) }
                }
            ),
            surface: surface,
            groupingMode: groupingMode,
            subgroupMode: preferences.subgroupMode(for: surface),
            sortField: preferences.sortField(for: surface),
            showsPinned: preferences.showsPinned(for: surface),
            showsDrawerPanes: preferences.showsDrawerPanes,
            referenceDate: referenceDate,
            referenceInstant: surface == .panes ? continuousNow() : nil,
            calendar: .current,
            sortOrder: preferences.sortDirection(for: surface),
            query: query
        )
        return RepoExplorerProjectionRequest(
            generation: 0,
            snapshot: snapshot,
            collapsedGroupIds: Set(sidebarCache.collapsedGroups.map(\.rawValue)),
            isFiltering: !query.isEmpty,
            trigger: trigger,
            worktreeEnrichmentSnapshot: worktreeEnrichmentSnapshot,
            pullRequestFactsSnapshot: Self.pullRequestFactsSnapshot(
                for: worktreeEnrichmentSnapshot,
                repoCache: repoCache
            ),
            paneRowFactsByPaneId: paneRowFactsByPaneId(for: snapshot),
            tabGroupFactsByTabId: groupingMode == .tab ? tabGroupFactsByTabId() : [:],
            unavailablePullRequestRepoIds: repositoryIDs.filter {
                repoCache.isPullRequestDataUnavailable(forRepository: $0)
            },
            loadingPullRequestRepoIds: repositoryIDs.filter {
                repoCache.isPullRequestLoading(forRepository: $0)
            },
            localActivityHydrationDisposition: repositoryActivityInputs.hydrationDisposition,
            repositoryLocalActivityByStableKey: repositoryActivityInputs.activityByStableKey,
            repositoryFactUpdateProgressByRepoId: Dictionary(
                uniqueKeysWithValues: repos.compactMap { repository in
                    repoCache.repositoryFactUpdateProgress(for: repository.id).map {
                        (repository.id, $0)
                    }
                }
            ),
            activityReferenceDate: referenceDate
        )
    }

    func capturePresentationRequest(
        previous: RepoExplorerProjectionRequest,
        query: String,
        referenceDate: Date
    ) -> RepoExplorerProjectionRequest {
        presentationCaptureCount += 1
        let surface = sidebarState.sidebarSurface
        let groupingMode = preferences.groupingMode(for: surface)
        let subgroupMode = preferences.subgroupMode(for: surface)
        let sortField = preferences.sortField(for: surface)
        let sortOrder = preferences.sortDirection(for: surface)
        let showsPinned = preferences.showsPinned(for: surface)
        let showsDrawerPanes = preferences.showsDrawerPanes
        let presentationDemandChanged =
            surface != previous.snapshot.surface
            || groupingMode != previous.snapshot.groupingMode
            || subgroupMode != previous.snapshot.subgroupMode
            || sortField != previous.snapshot.sortField
        let repositoryActivityInputs =
            presentationDemandChanged
            ? captureRepositoryActivityInputs(
                for: previous.snapshot.repos,
                surface: surface
            )
            : (
                hydrationDisposition: previous.localActivityHydrationDisposition,
                activityByStableKey: previous.repositoryLocalActivityByStableKey
            )
        let paneFacts: [UUID: RepoExplorerPaneRowFacts]
        let tabFacts: [UUID: RepoExplorerTabGroupFacts]
        let nextSnapshot = previous.snapshot.replacing(
            surface: surface,
            groupingMode: groupingMode,
            subgroupMode: subgroupMode,
            sortField: sortField,
            showsPinned: showsPinned,
            showsDrawerPanes: showsDrawerPanes,
            referenceDate: referenceDate,
            referenceInstant: surface == .panes ? continuousNow() : nil,
            calendar: .current,
            sortOrder: sortOrder,
            query: query
        )
        if presentationDemandChanged {
            let tabIDs = demandedTabIDs(in: nextSnapshot)
            paneFacts = paneRowFactsByPaneId(for: nextSnapshot)
            tabFacts =
                surface == .panes && groupingMode == .tab
                ? Dictionary(
                    uniqueKeysWithValues: tabIDs.compactMap { tabID in
                        captureTabFact(tabID: tabID).map { (tabID, $0) }
                    }
                )
                : [:]
        } else {
            paneFacts = previous.paneRowFactsByPaneId
            tabFacts = previous.tabGroupFactsByTabId
        }
        return previous.replacing(
            snapshot: nextSnapshot,
            collapsedGroupIds: Set(sidebarCache.collapsedGroups.map(\.rawValue)),
            isFiltering: !query.isEmpty,
            paneRowFactsByPaneId: paneFacts,
            tabGroupFactsByTabId: tabFacts,
            localActivityHydrationDisposition: repositoryActivityInputs.hydrationDisposition,
            repositoryLocalActivityByStableKey: repositoryActivityInputs.activityByStableKey,
            activityReferenceDate: referenceDate
        )
    }

    func captureScoped(
        _ invalidation: RepoExplorerInputInvalidation,
        previous: RepoExplorerProjectionRequest,
        referenceDate: Date
    ) -> RepoExplorerScopedCapture? {
        scopedCaptureCount += 1
        switch invalidation {
        case .structural, .presentation, .activityHydration:
            return nil
        case .stableIdentity:
            return captureStableIdentityChanges(
                previous: previous,
                referenceDate: referenceDate
            )
        case .repositoryActivity(let repositoryID):
            return captureRepositoryActivity(
                repositoryID,
                previous: previous,
                referenceDate: referenceDate
            )
        case .repository(let repositoryID):
            return captureRepositoryChange(
                repositoryID,
                previous: previous,
                referenceDate: referenceDate
            )
        case .worktree(let worktreeID):
            return captureWorktreeChange(worktreeID, previous: previous)
        case .pane(let paneID):
            return capturePaneChanges([paneID], previous: previous, referenceDate: referenceDate)
        case .tab(let tabID):
            guard previous.snapshot.groupingMode == .tab,
                let fact = captureTabFact(tabID: tabID),
                previous.tabGroupFactsByTabId[tabID] != fact
            else { return unchangedScopedCapture(previous) }
            var tabFacts = previous.tabGroupFactsByTabId
            tabFacts[tabID] = fact
            return RepoExplorerScopedCapture(
                request: previous.replacing(tabGroupFactsByTabId: tabFacts),
                changes: [.tab(tabID)],
                requiresFullProjection: false
            )
        case .attention:
            let previousFocusedPaneIDs = Set(
                previous.paneRowFactsByPaneId.compactMap { paneID, facts in facts.isActive ? paneID : nil }
            )
            let nextFocusedPaneID = focusedPaneID()
            let affectedPaneIDs = previousFocusedPaneIDs.union(nextFocusedPaneID.map { [$0] } ?? [])
            return capturePaneChanges(
                affectedPaneIDs,
                previous: previous,
                referenceDate: referenceDate
            )
        }
    }

    func repositoryIDsWithChangedStableIdentity(
        in previous: RepoExplorerProjectionRequest
    ) -> Set<UUID> {
        Set(
            previous.snapshot.repos.compactMap { previousRepository in
                guard
                    let stableKey = store.repositoryTopologyAtom.repositoryStableKey(
                        for: previousRepository.id
                    )
                else { return previousRepository.id }
                guard stableKey == previousRepository.stableKey else { return previousRepository.id }
                let worktreeIdentityChanged = previousRepository.worktrees.contains { worktree in
                    store.repositoryTopologyAtom.worktreeStableKey(for: worktree.id)
                        != previousRepository.worktreeStableKeysByID[worktree.id]
                }
                return worktreeIdentityChanged ? previousRepository.id : nil
            })
    }

    private func captureStableIdentityChanges(
        previous: RepoExplorerProjectionRequest,
        referenceDate: Date
    ) -> RepoExplorerScopedCapture? {
        let changedRepositoryIDs = repositoryIDsWithChangedStableIdentity(in: previous)
        guard !changedRepositoryIDs.isEmpty else { return unchangedScopedCapture(previous) }

        var request = previous
        if previous.snapshot.surface == .repos {
            var activityByRepositoryStableKey = previous.repositoryLocalActivityByStableKey
            let previousStableKeysByRepositoryID = Dictionary(
                uniqueKeysWithValues: previous.snapshot.repos.map { ($0.id, $0.stableKey) }
            )
            for repositoryID in changedRepositoryIDs {
                guard let previousStableKey = previousStableKeysByRepositoryID[repositoryID] else { return nil }
                activityByRepositoryStableKey[previousStableKey] = nil
            }
            for repositoryID in changedRepositoryIDs {
                guard
                    let stableKey = store.repositoryTopologyAtom.repositoryStableKey(
                        for: repositoryID
                    )
                else { return nil }
                activityByRepositoryStableKey[stableKey] =
                    coreAtoms.repositoryLocalActivity.activity(for: stableKey)
            }
            request = previous.replacing(
                repositoryLocalActivityByStableKey: activityByRepositoryStableKey,
                activityReferenceDate: referenceDate
            )
        }
        var changes = Set<RepoExplorerScopedProjectionChange>()
        var requiresFullProjection = false
        var requiresObservationRetarget = false
        for repositoryID in changedRepositoryIDs {
            guard
                let capture = captureRepositoryChange(
                    repositoryID,
                    previous: request,
                    referenceDate: referenceDate,
                    retargetRepositoryActivityIdentity: false
                )
            else { return nil }
            request = capture.request
            changes.formUnion(capture.changes)
            requiresFullProjection = requiresFullProjection || capture.requiresFullProjection
            requiresObservationRetarget =
                requiresObservationRetarget || capture.requiresObservationRetarget
        }
        return RepoExplorerScopedCapture(
            request: request,
            changes: changes,
            requiresFullProjection: requiresFullProjection,
            requiresObservationRetarget: requiresObservationRetarget
        )
    }

    private func captureRepositoryActivity(
        _ repositoryID: UUID,
        previous: RepoExplorerProjectionRequest,
        referenceDate: Date
    ) -> RepoExplorerScopedCapture? {
        guard previous.snapshot.surface == .repos,
            let repositoryStableKey = store.repositoryTopologyAtom.repositoryStableKey(
                for: repositoryID
            )
        else { return unchangedScopedCapture(previous) }
        var activityByRepositoryStableKey = previous.repositoryLocalActivityByStableKey
        activityByRepositoryStableKey[repositoryStableKey] =
            coreAtoms.repositoryLocalActivity.activity(for: repositoryStableKey)
        return RepoExplorerScopedCapture(
            request: previous.replacing(
                repositoryLocalActivityByStableKey: activityByRepositoryStableKey,
                activityReferenceDate: referenceDate
            ),
            changes: [.repositoryActivity(repositoryID)],
            requiresFullProjection: false
        )
    }

    private func captureRepositoryActivityInputs(
        for repositories: [RepoPresentationItem],
        surface: SidebarSurface
    ) -> (
        hydrationDisposition: RepositoryLocalActivityHydrationDisposition,
        activityByStableKey: [String: RepositoryLocalActivity]
    ) {
        guard surface == .repos else { return (.pending, [:]) }
        let repositoryLocalActivity = coreAtoms.repositoryLocalActivity
        return (
            repositoryLocalActivity.hydrationDisposition,
            Dictionary(
                uniqueKeysWithValues: repositories.compactMap { repository in
                    repositoryLocalActivity.activity(for: repository.stableKey).map {
                        (repository.stableKey, $0)
                    }
                }
            )
        )
    }

    private func captureRepositoryChange(
        _ repositoryID: UUID,
        previous: RepoExplorerProjectionRequest,
        referenceDate: Date,
        retargetRepositoryActivityIdentity: Bool = true
    ) -> RepoExplorerScopedCapture? {
        guard let repositoryIndex = previous.snapshot.repos.firstIndex(where: { $0.id == repositoryID }),
            !store.repositoryTopologyAtom.isRepoUnavailable(repositoryID),
            let repository = store.repositoryTopologyAtom.repo(repositoryID),
            let stableKey = store.repositoryTopologyAtom.repositoryStableKey(for: repositoryID)
        else { return nil }
        let previousRepository = previous.snapshot.repos[repositoryIndex]
        let updatedRepository = RepoPresentationItem(
            repo: repository,
            stableKey: stableKey,
            worktreeStableKeysByID: store.repositoryTopologyAtom.worktreeStableKeysByID
        )
        guard previousRepository.worktrees.map(\.id) == updatedRepository.worktrees.map(\.id) else { return nil }

        var repositories = previous.snapshot.repos
        repositories[repositoryIndex] = updatedRepository
        var repoEnrichment = previous.snapshot.repoEnrichmentSnapshotByRepoId
        let previousRepoEnrichment = repoEnrichment[repositoryID]
        repoEnrichment[repositoryID] = repoCache.repoEnrichment(for: repositoryID)
        let repositoryActivityIdentityChanged =
            previous.snapshot.surface == .repos
            && previousRepository.stableKey != updatedRepository.stableKey
        var activityByRepositoryStableKey = previous.repositoryLocalActivityByStableKey
        if repositoryActivityIdentityChanged, retargetRepositoryActivityIdentity {
            activityByRepositoryStableKey[previousRepository.stableKey] = nil
            activityByRepositoryStableKey[updatedRepository.stableKey] =
                coreAtoms.repositoryLocalActivity.activity(for: updatedRepository.stableKey)
        }
        let request = captureRepositoryRuntimeFacts(
            repositoryID,
            worktreeIDs: updatedRepository.worktrees.map(\.id),
            previous: previous.replacing(
                snapshot: previous.snapshot.replacing(
                    repos: repositories,
                    repoEnrichmentByRepoId: repoEnrichment
                ),
                repositoryLocalActivityByStableKey: activityByRepositoryStableKey,
                activityReferenceDate: repositoryActivityIdentityChanged
                    ? referenceDate
                    : previous.activityReferenceDate
            )
        )
        let repositoryPresentationChanged = previousRepository != updatedRepository
        let repoEnrichmentChanged = previousRepoEnrichment != repoEnrichment[repositoryID]
        let progressChanged =
            previous.repositoryFactUpdateProgressByRepoId[repositoryID]
            != request.repositoryFactUpdateProgressByRepoId[repositoryID]
        let worktreeChanges = Set(
            updatedRepository.worktrees.map { RepoExplorerScopedProjectionChange.worktreeFact($0.id) })
        var changes = worktreeChanges.union(
            repositoryPresentationChanged || progressChanged ? [.repo(repositoryID)] : []
        )
        if repositoryActivityIdentityChanged {
            changes.insert(.repositoryActivity(repositoryID))
        }
        return RepoExplorerScopedCapture(
            request: request,
            changes: changes,
            requiresFullProjection: repoEnrichmentChanged,
            requiresObservationRetarget: repositoryActivityIdentityChanged
        )
    }

    private func captureWorktreeChange(
        _ worktreeID: UUID,
        previous: RepoExplorerProjectionRequest
    ) -> RepoExplorerScopedCapture? {
        guard
            let repository = previous.snapshot.repos.first(where: { repo in
                repo.worktrees.contains(where: { $0.id == worktreeID })
            })
        else { return nil }
        let request = captureRepositoryRuntimeFacts(
            repository.id,
            worktreeIDs: [worktreeID],
            previous: previous
        )
        return RepoExplorerScopedCapture(
            request: request,
            changes: request == previous ? [] : [.worktreeFact(worktreeID)],
            requiresFullProjection: false
        )
    }

    private func captureRepositoryRuntimeFacts(
        _ repositoryID: UUID,
        worktreeIDs: [UUID],
        previous: RepoExplorerProjectionRequest
    ) -> RepoExplorerProjectionRequest {
        var worktreeEnrichment = previous.worktreeEnrichmentSnapshot
        for worktreeID in worktreeIDs {
            worktreeEnrichment[worktreeID] = repoCache.worktreeEnrichment(for: worktreeID)
        }
        var pullRequestFacts = previous.pullRequestFactsSnapshot.filter { $0.key.repoId != repositoryID }
        for enrichment in worktreeEnrichment.values where enrichment.repoId == repositoryID {
            guard let branchKey = RepoBranchKey(repoId: repositoryID, branch: enrichment.branch),
                let facts = repoCache.pullRequestFacts(for: branchKey)
            else { continue }
            pullRequestFacts[branchKey] = facts
        }
        var unavailableRepositories = previous.unavailablePullRequestRepoIds
        var loadingRepositories = previous.loadingPullRequestRepoIds
        var progressByRepositoryID = previous.repositoryFactUpdateProgressByRepoId
        if repoCache.isPullRequestDataUnavailable(forRepository: repositoryID) {
            unavailableRepositories.insert(repositoryID)
        } else {
            unavailableRepositories.remove(repositoryID)
        }
        if repoCache.isPullRequestLoading(forRepository: repositoryID) {
            loadingRepositories.insert(repositoryID)
        } else {
            loadingRepositories.remove(repositoryID)
        }
        progressByRepositoryID[repositoryID] = repoCache.repositoryFactUpdateProgress(for: repositoryID)
        return previous.replacing(
            worktreeEnrichmentSnapshot: worktreeEnrichment,
            pullRequestFactsSnapshot: pullRequestFacts,
            unavailablePullRequestRepoIds: unavailableRepositories,
            loadingPullRequestRepoIds: loadingRepositories,
            repositoryFactUpdateProgressByRepoId: progressByRepositoryID
        )
    }

    private func capturePaneChanges(
        _ paneIDs: Set<UUID>,
        previous: RepoExplorerProjectionRequest,
        referenceDate: Date
    ) -> RepoExplorerScopedCapture {
        guard shouldCapturePaneFacts(for: previous.snapshot) else {
            return unchangedScopedCapture(previous)
        }
        var paneFacts = previous.paneRowFactsByPaneId
        var bridgeCandidates = previous.snapshot.bridgePaneCommandCandidatesByWorktreeId
        var changes = Set<RepoExplorerScopedProjectionChange>()
        for paneID in paneIDs where paneFacts[paneID] != nil {
            let nextFact = capturePaneFact(paneID: paneID, for: previous.snapshot.surface)
            if paneFacts[paneID] != nextFact {
                paneFacts[paneID] = nextFact
                changes.insert(.pane(paneID))
            }
            for (worktreeID, locations) in previous.snapshot.paneLocationsByWorktreeId
            where locations.contains(where: { $0.paneId == paneID }) {
                let nextCandidates = bridgePaneCommandCandidatesByWorktreeId(
                    paneLocationsByWorktreeId: [worktreeID: locations]
                )[worktreeID, default: []]
                if bridgeCandidates[worktreeID, default: []] != nextCandidates {
                    bridgeCandidates[worktreeID] = nextCandidates
                    changes.insert(.worktreeFact(worktreeID))
                }
            }
        }
        let referenceInstant = previous.snapshot.surface == .panes ? continuousNow() : nil
        let captureReferenceDate = referenceInstant == nil ? referenceDate : wallNow()
        return RepoExplorerScopedCapture(
            request: previous.replacing(
                snapshot: previous.snapshot.replacing(
                    referenceDate: captureReferenceDate,
                    referenceInstant: referenceInstant,
                    calendar: .current,
                    bridgePaneCommandCandidatesByWorktreeId: bridgeCandidates
                ),
                paneRowFactsByPaneId: paneFacts,
                activityReferenceDate: captureReferenceDate
            ),
            changes: changes,
            requiresFullProjection: false
        )
    }

    private func unchangedScopedCapture(
        _ previous: RepoExplorerProjectionRequest
    ) -> RepoExplorerScopedCapture {
        RepoExplorerScopedCapture(request: previous, changes: [], requiresFullProjection: false)
    }

    func demandedPaneIDs(in snapshot: RepoExplorerSnapshot) -> Set<UUID> {
        Set(
            snapshot.paneLocationsByWorktreeId.values.flatMap { $0.map(\.paneId) }
                + snapshot.unassociatedPaneLocations.map(\.paneId)
        )
    }

    func demandedTabIDs(in snapshot: RepoExplorerSnapshot) -> Set<UUID> {
        Set(
            snapshot.paneLocationsByWorktreeId.values.flatMap { $0.map(\.tabId) }
                + snapshot.unassociatedPaneLocations.map(\.tabId)
        )
    }

    static func worktreeEnrichmentSnapshot(
        for worktreeIDs: [UUID],
        repoCache: RepoCacheAtom
    ) -> [UUID: WorktreeEnrichment] {
        var enrichmentByWorktreeID: [UUID: WorktreeEnrichment] = [:]
        enrichmentByWorktreeID.reserveCapacity(worktreeIDs.count)
        for worktreeID in worktreeIDs {
            enrichmentByWorktreeID[worktreeID] = repoCache.worktreeEnrichment(for: worktreeID)
        }
        return enrichmentByWorktreeID
    }

    static func pullRequestFactsSnapshot(
        for worktreeEnrichmentSnapshot: [UUID: WorktreeEnrichment],
        repoCache: RepoCacheAtom
    ) -> [RepoBranchKey: PullRequestFacts] {
        var factsByBranch: [RepoBranchKey: PullRequestFacts] = [:]
        for enrichment in worktreeEnrichmentSnapshot.values {
            guard let key = RepoBranchKey(repoId: enrichment.repoId, branch: enrichment.branch) else { continue }
            factsByBranch[key] = repoCache.pullRequestFacts(for: key)
        }
        return factsByBranch
    }

    private func sidebarRepos() -> [RepoPresentationItem] {
        store.repositoryTopologyAtom.repositoryIdsInOrder.compactMap { repositoryID in
            guard
                !store.repositoryTopologyAtom.isRepoUnavailable(repositoryID),
                let repository = store.repositoryTopologyAtom.repo(repositoryID),
                let stableKey = store.repositoryTopologyAtom.repositoryStableKey(for: repositoryID)
            else { return nil }
            var availableRepository = repository
            availableRepository.worktrees = repository.worktrees.filter {
                !store.repositoryTopologyAtom.isWorktreeUnavailable($0.id)
            }
            return RepoPresentationItem(
                repo: availableRepository,
                stableKey: stableKey,
                worktreeStableKeysByID: store.repositoryTopologyAtom.worktreeStableKeysByID
            )
        }
    }

    func makeSidebarSnapshot(
        repos: [RepoPresentationItem],
        repoEnrichmentByRepoId: [UUID: RepoEnrichment],
        surface: SidebarSurface = .repos,
        groupingMode: RepoExplorerGroupingMode,
        subgroupMode: SidebarSubgroupMode = .ungrouped,
        sortField: SidebarSortField = .name,
        showsPinned: Bool = true,
        showsDrawerPanes: Bool = true,
        referenceDate: Date = .distantPast,
        referenceInstant: ContinuousClock.Instant? = nil,
        calendar: Calendar = .current,
        sortOrder: RepoExplorerSortOrder,
        query: String
    ) -> RepoExplorerSnapshot {
        let workspaceTab = WorkspaceTabLayoutDerived(
            shellAtom: store.tabShellAtom,
            arrangementAtom: store.tabArrangementAtom
        )
        let paneLocationsByWorktreeId = coreAtoms.workspaceLookup.paneLocationsByWorktreeId(
            repositoryTopology: store.repositoryTopologyAtom,
            workspacePane: store.paneAtom,
            workspaceTab: workspaceTab,
            declaredWorktreeIDs: Set(repos.flatMap(\.worktrees).map(\.id))
        )
        let associatedPaneIDs = Set(paneLocationsByWorktreeId.values.flatMap { $0 }.map(\.paneId))
        let unassociatedPaneLocations = Self.unassociatedPaneLocations(
            repositoryTopology: store.repositoryTopologyAtom,
            workspacePane: store.paneAtom,
            workspaceTab: workspaceTab,
            associatedPaneIDs: associatedPaneIDs
        )
        return RepoExplorerSnapshot(
            repos: repos,
            repoEnrichmentByRepoId: repoEnrichmentByRepoId,
            surface: surface,
            groupingMode: groupingMode,
            subgroupMode: subgroupMode,
            sortField: sortField,
            showsPinned: showsPinned,
            showsDrawerPanes: showsDrawerPanes,
            referenceDate: referenceDate,
            referenceInstant: referenceInstant,
            calendar: calendar,
            sortOrder: sortOrder,
            query: query,
            paneLocationsByWorktreeId: paneLocationsByWorktreeId,
            unassociatedPaneLocations: unassociatedPaneLocations,
            bridgePaneCommandCandidatesByWorktreeId: bridgePaneCommandCandidatesByWorktreeId(
                paneLocationsByWorktreeId: paneLocationsByWorktreeId
            )
        )
    }

    private static func unassociatedPaneLocations(
        repositoryTopology: RepositoryTopologyAtom,
        workspacePane: WorkspacePaneAtom,
        workspaceTab: WorkspaceTabLayoutDerived,
        associatedPaneIDs: Set<UUID>
    ) -> [WorkspacePaneLocation] {
        var locations: [WorkspacePaneLocation] = []
        var seenPaneIDs = Set<UUID>()
        for (tabIndex, tab) in workspaceTab.tabs.enumerated() {
            for paneID in tab.allPaneIds {
                guard seenPaneIDs.insert(paneID).inserted, !associatedPaneIDs.contains(paneID),
                    let paneFacts = workspacePane.graphAtom.paneStructuralFacts(paneID),
                    paneFacts.residency == .active,
                    repositoryTopology.validatedAssociation(
                        repoId: paneFacts.repoID,
                        worktreeId: paneFacts.worktreeID
                    ) == nil
                else { continue }
                locations.append(
                    WorkspacePaneLocation(
                        paneId: paneID,
                        tabId: tab.id,
                        tabIndex: tabIndex,
                        paneIndexInTab: tab.activePaneIds.firstIndex(of: paneID)
                            ?? tab.allPaneIds.firstIndex(of: paneID)
                            ?? 0,
                        isActiveInTab: tab.activePaneId == paneID
                    )
                )
            }
        }
        return locations
    }

    func bridgePaneCommandCandidatesByWorktreeId(
        paneLocationsByWorktreeId: [UUID: [WorkspacePaneLocation]]
    ) -> [UUID: [BridgePaneCommandCandidate]] {
        let paneGraph = store.paneAtom.graphAtom
        let activeTabID = store.tabLayoutAtom.activeTabId
        let activePaneID = activeTabID.flatMap { store.tabLayoutAtom.tab($0)?.activePaneId }
        var candidatesByWorktreeID: [UUID: [BridgePaneCommandCandidate]] = [:]
        for (worktreeID, paneLocations) in paneLocationsByWorktreeId {
            candidatesByWorktreeID[worktreeID] = paneLocations.compactMap { location in
                guard let paneFacts = paneGraph.paneStructuralFacts(location.paneId) else { return nil }
                return BridgePaneCommandCandidate(
                    paneId: paneFacts.paneID,
                    worktreeId: worktreeID,
                    isBridgePane: paneFacts.isBridgeEligible,
                    isPaneActive: paneFacts.residency == .active,
                    isCurrentActivePane: activeTabID == location.tabId && activePaneID == paneFacts.paneID,
                    attendanceOrdinal: bridgeAttendanceSnapshot(paneFacts.paneID),
                    tabIndex: location.tabIndex,
                    paneIndexInTab: location.paneIndexInTab
                )
            }
        }
        return candidatesByWorktreeID
    }

    private func paneRowFactsByPaneId(
        for snapshot: RepoExplorerSnapshot
    ) -> [UUID: RepoExplorerPaneRowFacts] {
        guard shouldCapturePaneFacts(for: snapshot) else { return [:] }
        let presentedPaneIDs = demandedPaneIDs(in: snapshot)
        let facts = Dictionary(
            uniqueKeysWithValues: presentedPaneIDs.compactMap { paneID in
                capturePaneFact(paneID: paneID, for: snapshot.surface).map { (paneID, $0) }
            }
        )
        paneDisplayTitleCache.retainOnly(paneIds: presentedPaneIDs)
        return facts
    }

    private func shouldCapturePaneFacts(for snapshot: RepoExplorerSnapshot) -> Bool {
        snapshot.surface == .panes
            || snapshot.groupingMode == .activity
            || (snapshot.surface == .panes && snapshot.subgroupMode == .activity)
            || snapshot.sortField == .activity
    }

    func capturePaneFact(
        paneID: UUID,
        for surface: SidebarSurface
    ) -> RepoExplorerPaneRowFacts? {
        paneFactCaptureCount += 1
        let activityFact = latestPaneMessageSnapshot(paneID)
        guard surface == .panes else {
            return RepoExplorerPaneRowFacts(
                terminalTitle: "",
                activityAt: activityFact?.observedAt,
                latestMessageText: nil,
                recencyReferenceDate: .distantPast,
                recencyText: "",
                recencyTier: .grey,
                isActive: false
            )
        }
        guard let pane = store.paneAtom.pane(paneID) else { return nil }
        let terminalTitle = paneDisplayTitleCache.resolve(
            paneId: paneID,
            liveTitle: pane.title,
            cwd: pane.metadata.facets.cwd,
            shellExecutablePath: pane.metadata.contentType == .terminal
                ? SessionConfiguration.defaultShell()
                : nil
        )
        return RepoExplorerPaneRowFacts(
            terminalTitle: terminalTitle,
            sessionStatus: sessionStatusForPane(PaneId(existingUUID: paneID)),
            contextDisplay: contextDisplayForPane(PaneId(existingUUID: paneID)),
            activityAt: nil,
            paneActivityTime: coreAtoms.paneActivityTime.value(for: paneID),
            isPinned: pane.metadata.isPinned,
            noteText: pane.metadata.note,
            latestMessageText: activityFact?.lastOutputLine,
            recencyReferenceDate: .distantPast,
            recencyText: "",
            recencyTier: .grey,
            isActive: false,
            isDrawerPane: store.paneAtom.graphAtom.paneState(paneID)?.isDrawerChild == true,
            drawerOwnerPaneID: pane.parentPaneId
        )
    }

    func focusedPaneID() -> UUID? {
        let routingContext = KeyboardRoutingContext.current(
            windowLifecycle: coreAtoms.windowLifecycle,
            managementLayer: coreAtoms.managementLayer,
            uiState: sidebarState,
            commandBarSurface: coreAtoms.commandBarSurface,
            transientKeyboardSurface: coreAtoms.transientKeyboardSurface
        )
        return routingContext.isStableMainWindowChain
            ? coreAtoms.attendedPane.attendedPaneId
            : nil
    }

    private func tabGroupFactsByTabId() -> [UUID: RepoExplorerTabGroupFacts] {
        let workspaceTab = WorkspaceTabLayoutDerived(
            shellAtom: store.tabShellAtom,
            arrangementAtom: store.tabArrangementAtom
        )
        return Dictionary(
            uniqueKeysWithValues: workspaceTab.tabs.compactMap { tab in
                captureTabFact(tabID: tab.id).map { (tab.id, $0) }
            }
        )
    }

    func captureTabFact(tabID: UUID) -> RepoExplorerTabGroupFacts? {
        guard let tab = store.tabLayoutAtom.tab(tabID) else { return nil }
        return RepoExplorerTabGroupFacts(
            displayTitle: coreAtoms.tabDisplay.displayTitle(
                for: tab,
                workspacePane: store.paneAtom,
                workspaceRepositoryTopology: store.repositoryTopologyAtom,
                repoCache: repoCache
            )
        )
    }
}
