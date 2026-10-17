import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

enum RepoExplorerScopedProjectionChange: Equatable, Hashable, Sendable {
    case repo(UUID)
    case repositoryActivity(UUID)
    case worktreeFact(UUID)
    case pane(UUID)
    case tab(UUID)
}

struct RepoExplorerProjectionRequest: Equatable, Sendable {
    let generation: Int
    let snapshot: RepoExplorerSnapshot
    let collapsedGroupIds: Set<String>
    let isFiltering: Bool
    let trigger: AppPolicies.SidebarProjection.Trigger
    let worktreeEnrichmentSnapshot: [UUID: WorktreeEnrichment]
    let pullRequestFactsSnapshot: [RepoBranchKey: PullRequestFacts]
    let paneRowFactsByPaneId: [UUID: RepoExplorerPaneRowFacts]
    let tabGroupFactsByTabId: [UUID: RepoExplorerTabGroupFacts]
    /// Repos whose pull request data has resolved to a terminal absence (no remote, or provider
    /// failures past the forge honesty threshold). This is independent of
    /// `pullRequestFactsSnapshot`: a repo can transition into this set with zero change to its
    /// (empty) facts snapshot, so every equality/admission check below must compare this field
    /// explicitly — otherwise that transition compares equal and silently skips re-projection.
    let unavailablePullRequestRepoIds: Set<UUID>
    let loadingPullRequestRepoIds: Set<UUID>
    let localActivityHydrationDisposition: RepositoryLocalActivityHydrationDisposition
    let repositoryLocalActivityByStableKey: [String: RepositoryLocalActivity]
    let repositoryFactUpdateProgressByRepoId: [UUID: RepositoryFactUpdateProgress]
    let activityReferenceDate: Date

    init(
        generation: Int,
        snapshot: RepoExplorerSnapshot,
        collapsedGroupIds: Set<String>,
        isFiltering: Bool,
        trigger: AppPolicies.SidebarProjection.Trigger,
        worktreeEnrichmentSnapshot: [UUID: WorktreeEnrichment] = [:],
        pullRequestFactsSnapshot: [RepoBranchKey: PullRequestFacts] = [:],
        paneRowFactsByPaneId: [UUID: RepoExplorerPaneRowFacts] = [:],
        tabGroupFactsByTabId: [UUID: RepoExplorerTabGroupFacts] = [:],
        unavailablePullRequestRepoIds: Set<UUID> = [],
        loadingPullRequestRepoIds: Set<UUID> = [],
        localActivityHydrationDisposition: RepositoryLocalActivityHydrationDisposition = .pending,
        repositoryLocalActivityByStableKey: [String: RepositoryLocalActivity] = [:],
        repositoryFactUpdateProgressByRepoId: [UUID: RepositoryFactUpdateProgress] = [:],
        activityReferenceDate: Date = .distantPast
    ) {
        self.generation = generation
        self.snapshot = snapshot
        self.collapsedGroupIds = collapsedGroupIds
        self.isFiltering = isFiltering
        self.trigger = trigger
        self.worktreeEnrichmentSnapshot = worktreeEnrichmentSnapshot
        self.pullRequestFactsSnapshot = pullRequestFactsSnapshot
        self.paneRowFactsByPaneId = paneRowFactsByPaneId
        self.tabGroupFactsByTabId = tabGroupFactsByTabId
        self.unavailablePullRequestRepoIds = unavailablePullRequestRepoIds
        self.loadingPullRequestRepoIds = loadingPullRequestRepoIds
        self.localActivityHydrationDisposition = localActivityHydrationDisposition
        self.repositoryLocalActivityByStableKey = repositoryLocalActivityByStableKey
        self.repositoryFactUpdateProgressByRepoId = repositoryFactUpdateProgressByRepoId
        self.activityReferenceDate = activityReferenceDate
    }

    func generated(
        generation: Int,
        trigger: AppPolicies.SidebarProjection.Trigger
    ) -> Self {
        Self(
            generation: generation,
            snapshot: snapshot,
            collapsedGroupIds: collapsedGroupIds,
            isFiltering: isFiltering,
            trigger: trigger,
            worktreeEnrichmentSnapshot: worktreeEnrichmentSnapshot,
            pullRequestFactsSnapshot: pullRequestFactsSnapshot,
            paneRowFactsByPaneId: paneRowFactsByPaneId,
            tabGroupFactsByTabId: tabGroupFactsByTabId,
            unavailablePullRequestRepoIds: unavailablePullRequestRepoIds,
            loadingPullRequestRepoIds: loadingPullRequestRepoIds,
            localActivityHydrationDisposition: localActivityHydrationDisposition,
            repositoryLocalActivityByStableKey: repositoryLocalActivityByStableKey,
            repositoryFactUpdateProgressByRepoId: repositoryFactUpdateProgressByRepoId,
            activityReferenceDate: activityReferenceDate
        )
    }

    func replacing(
        snapshot: RepoExplorerSnapshot? = nil,
        collapsedGroupIds: Set<String>? = nil,
        isFiltering: Bool? = nil,
        worktreeEnrichmentSnapshot: [UUID: WorktreeEnrichment]? = nil,
        pullRequestFactsSnapshot: [RepoBranchKey: PullRequestFacts]? = nil,
        paneRowFactsByPaneId: [UUID: RepoExplorerPaneRowFacts]? = nil,
        tabGroupFactsByTabId: [UUID: RepoExplorerTabGroupFacts]? = nil,
        unavailablePullRequestRepoIds: Set<UUID>? = nil,
        loadingPullRequestRepoIds: Set<UUID>? = nil,
        localActivityHydrationDisposition: RepositoryLocalActivityHydrationDisposition? = nil,
        repositoryLocalActivityByStableKey: [String: RepositoryLocalActivity]? = nil,
        repositoryFactUpdateProgressByRepoId: [UUID: RepositoryFactUpdateProgress]? = nil,
        activityReferenceDate: Date? = nil
    ) -> Self {
        Self(
            generation: generation,
            snapshot: snapshot ?? self.snapshot,
            collapsedGroupIds: collapsedGroupIds ?? self.collapsedGroupIds,
            isFiltering: isFiltering ?? self.isFiltering,
            trigger: trigger,
            worktreeEnrichmentSnapshot: worktreeEnrichmentSnapshot ?? self.worktreeEnrichmentSnapshot,
            pullRequestFactsSnapshot: pullRequestFactsSnapshot ?? self.pullRequestFactsSnapshot,
            paneRowFactsByPaneId: paneRowFactsByPaneId ?? self.paneRowFactsByPaneId,
            tabGroupFactsByTabId: tabGroupFactsByTabId ?? self.tabGroupFactsByTabId,
            unavailablePullRequestRepoIds: unavailablePullRequestRepoIds
                ?? self.unavailablePullRequestRepoIds,
            loadingPullRequestRepoIds: loadingPullRequestRepoIds ?? self.loadingPullRequestRepoIds,
            localActivityHydrationDisposition: localActivityHydrationDisposition
                ?? self.localActivityHydrationDisposition,
            repositoryLocalActivityByStableKey: repositoryLocalActivityByStableKey
                ?? self.repositoryLocalActivityByStableKey,
            repositoryFactUpdateProgressByRepoId: repositoryFactUpdateProgressByRepoId
                ?? self.repositoryFactUpdateProgressByRepoId,
            activityReferenceDate: activityReferenceDate ?? self.activityReferenceDate
        )
    }

    func scopedChange(from previous: Self) -> RepoExplorerScopedProjectionChange? {
        guard snapshot.groupingMode == .repo,
            previous.snapshot.groupingMode == snapshot.groupingMode,
            previous.snapshot.sortOrder == snapshot.sortOrder,
            previous.snapshot.query == snapshot.query,
            previous.snapshot.repoEnrichmentSnapshotByRepoId == snapshot.repoEnrichmentSnapshotByRepoId,
            previous.snapshot.paneLocationsByWorktreeId == snapshot.paneLocationsByWorktreeId,
            previous.snapshot.unassociatedPaneLocations == snapshot.unassociatedPaneLocations,
            previous.snapshot.bridgePaneCommandCandidatesByWorktreeId
                == snapshot.bridgePaneCommandCandidatesByWorktreeId,
            previous.collapsedGroupIds == collapsedGroupIds,
            previous.isFiltering == isFiltering,
            previous.unavailablePullRequestRepoIds == unavailablePullRequestRepoIds,
            previous.loadingPullRequestRepoIds == loadingPullRequestRepoIds,
            previous.pullRequestFactsSnapshot == pullRequestFactsSnapshot
                && previous.paneRowFactsByPaneId == paneRowFactsByPaneId
                && previous.tabGroupFactsByTabId == tabGroupFactsByTabId
                && previous.localActivityHydrationDisposition == localActivityHydrationDisposition
                && previous.repositoryLocalActivityByStableKey == repositoryLocalActivityByStableKey
                && previous.activityReferenceDate == activityReferenceDate
        else { return nil }

        let changedProgressRepositoryIDs = Set(previous.repositoryFactUpdateProgressByRepoId.keys)
            .union(repositoryFactUpdateProgressByRepoId.keys)
            .filter {
                previous.repositoryFactUpdateProgressByRepoId[$0]
                    != repositoryFactUpdateProgressByRepoId[$0]
            }
        if changedProgressRepositoryIDs.count == 1,
            let repositoryID = changedProgressRepositoryIDs.first
        {
            return .repo(repositoryID)
        }
        guard changedProgressRepositoryIDs.isEmpty else { return nil }

        if previous.snapshot.repos == snapshot.repos {
            let changedWorktreeIds = Set(previous.worktreeEnrichmentSnapshot.keys)
                .union(worktreeEnrichmentSnapshot.keys)
                .filter {
                    previous.worktreeEnrichmentSnapshot[$0] != worktreeEnrichmentSnapshot[$0]
                }
            return changedWorktreeIds.count == 1
                ? changedWorktreeIds.first.map(RepoExplorerScopedProjectionChange.worktreeFact)
                : nil
        }

        return nil
    }

    func hasMembershipChange(from previous: Self) -> Bool {
        snapshot.repos.map(\.id) != previous.snapshot.repos.map(\.id)
            || snapshot.repos.flatMap(\.worktrees).map(\.id)
                != previous.snapshot.repos.flatMap(\.worktrees).map(\.id)
    }

}

struct RepoExplorerPreparedPresentationDeadline: Equatable, Sendable {
    let deadline: Date
    let paneIDs: Set<UUID>
    let repositoryIDs: Set<UUID>
    let referenceInstant: ContinuousClock.Instant?
    let referenceDate: Date?

    init(
        deadline: Date,
        paneIDs: Set<UUID>,
        repositoryIDs: Set<UUID>,
        referenceInstant: ContinuousClock.Instant? = nil,
        referenceDate: Date? = nil
    ) {
        self.deadline = deadline
        self.paneIDs = paneIDs
        self.repositoryIDs = repositoryIDs
        self.referenceInstant = referenceInstant
        self.referenceDate = referenceDate
    }

    static func prepare(
        sidebarTransitionsByPaneID: [UUID: Date],
        repositoryTransitionsByRepositoryID: [UUID: Date],
        referenceInstant: ContinuousClock.Instant? = nil,
        referenceDate: Date? = nil
    ) -> Self? {
        guard
            let deadline = sidebarTransitionsByPaneID.values.min()
                .map({ sidebarDeadline in
                    min(sidebarDeadline, repositoryTransitionsByRepositoryID.values.min() ?? sidebarDeadline)
                })
                ?? repositoryTransitionsByRepositoryID.values.min()
        else { return nil }
        return Self(
            deadline: deadline,
            paneIDs: Set(
                sidebarTransitionsByPaneID.compactMap { paneID, transition in
                    transition == deadline ? paneID : nil
                }
            ),
            repositoryIDs: Set(
                repositoryTransitionsByRepositoryID.compactMap { repositoryID, transition in
                    transition == deadline ? repositoryID : nil
                }
            ),
            referenceInstant: referenceInstant,
            referenceDate: referenceDate
        )
    }
}

struct RepoExplorerProjectionResult: Equatable, Sendable {
    let generation: Int
    let snapshot: RepoExplorerSnapshot
    let collapsedGroupIds: Set<String>
    let isFiltering: Bool
    let trigger: AppPolicies.SidebarProjection.Trigger
    let projection: RepoExplorerSidebarProjection
    let rowIndex: RepoExplorerRowIndex
    let materializationSnapshot: RepoExplorerMaterializationSnapshot
    let workerDuration: Duration
    let projectionDuration: Duration
    let rowIndexDuration: Duration
    let branchStatusByWorktreeId: [UUID: GitBranchStatus]
    let branchNameByWorktreeId: [UUID: String]
    let bridgeCommandResolutionByWorktreeId: [UUID: BridgePaneCommandResolution]
    let paneRowFactsByPaneId: [UUID: RepoExplorerPaneRowFacts]
    let tabGroupFactsByTabId: [UUID: RepoExplorerTabGroupFacts]
    let repositoryActivityDispositionByRepoId: [UUID: RepositoryActivityDisposition]
    let repositoryActivityTransitionAtByRepoId: [UUID: Date]
    let sidebarPresentationTransitionAtByPaneId: [UUID: Date]
    let preparedPresentationDeadline: RepoExplorerPreparedPresentationDeadline?
    let semanticBaselineSequence: UInt64?

    static let empty: Self = {
        let snapshot = RepoExplorerSnapshot(
            repos: [],
            repoEnrichmentByRepoId: [:],
            groupingMode: .repo,
            sortOrder: .default,
            query: ""
        )
        let projection = RepoExplorerSidebarProjection(
            sections: [],
            resolvedGroups: [],
            loadingRepos: [],
            showsNoResults: false
        )
        return Self(
            generation: 0,
            snapshot: snapshot,
            collapsedGroupIds: [],
            isFiltering: false,
            trigger: .startupDiagnostic,
            projection: projection,
            rowIndex: RepoExplorerRowIndex(
                projection: projection,
                collapsedGroupIds: [],
                isFiltering: false
            ),
            materializationSnapshot: .empty,
            workerDuration: .zero,
            projectionDuration: .zero,
            rowIndexDuration: .zero,
            branchStatusByWorktreeId: [:],
            branchNameByWorktreeId: [:],
            bridgeCommandResolutionByWorktreeId: [:],
            paneRowFactsByPaneId: [:],
            tabGroupFactsByTabId: [:],
            repositoryActivityDispositionByRepoId: [:],
            repositoryActivityTransitionAtByRepoId: [:],
            sidebarPresentationTransitionAtByPaneId: [:],
            preparedPresentationDeadline: nil,
            semanticBaselineSequence: nil
        )
    }()
}

actor RepoExplorerProjectionWorker {
    let presentationDeadlineDelay: AsyncDelay
    let presentationDeadlineNow: @Sendable () -> Date
    let presentationDeadlineContinuousNow: @Sendable () -> ContinuousClock.Instant
    let onPresentationDeadline: @MainActor @Sendable (Int, RepoExplorerPreparedPresentationDeadline) -> Void
    var presentationDeadlineTask: Task<Void, Never>?
    var latestPresentationDeadlineGeneration = -1

    init(
        deadlineDelay: AsyncDelay = .taskSleep,
        deadlineNow: @escaping @Sendable () -> Date = Date.init,
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        onDeadline: @escaping @MainActor @Sendable (Int, RepoExplorerPreparedPresentationDeadline) -> Void = { _, _ in }
    ) {
        presentationDeadlineDelay = deadlineDelay
        presentationDeadlineNow = deadlineNow
        presentationDeadlineContinuousNow = continuousNow
        onPresentationDeadline = onDeadline
    }

    static func project(
        _ work: RepoExplorerProjectionWork
    ) throws -> RepoExplorerProjectionResult {
        switch work {
        case .full(let fullWork):
            return try project(fullWork.targetRequest)
        case .delta(let delta):
            guard var result = delta.context.semanticBaselineResult,
                RepoExplorerProjectionStructuralTarget(result: result) == delta.structuralTarget
            else {
                return try project(delta.targetRequest)
            }
            guard
                delta.changes.allSatisfy({ change in
                    switch change {
                    case .repositoryActivity, .worktreeFact: true
                    case .repo, .pane, .tab: false
                    }
                })
            else { return try project(delta.targetRequest) }
            let repositoryActivityChanges = delta.changes.compactMap { change -> UUID? in
                guard case .repositoryActivity(let repositoryID) = change else { return nil }
                return repositoryID
            }
            .sorted { $0.uuidString < $1.uuidString }
            let worktreeChanges = delta.changes.compactMap { change -> UUID? in
                guard case .worktreeFact(let worktreeID) = change else { return nil }
                return worktreeID
            }
            .sorted { $0.uuidString < $1.uuidString }
            if !repositoryActivityChanges.isEmpty {
                guard
                    let updated = try applyScopedRepositoryActivityChanges(
                        repositoryActivityChanges,
                        request: delta.targetRequest,
                        previous: result
                    )
                else { return try project(delta.targetRequest) }
                result = updated
            }
            for worktreeID in worktreeChanges {
                try Task.checkCancellation()
                guard
                    let updated = applyScopedWorktreeFactChange(
                        worktreeId: worktreeID,
                        request: delta.targetRequest,
                        previous: result
                    )
                else {
                    return try project(delta.targetRequest)
                }
                result = updated
            }
            return result.withSemanticBaselineSequence(delta.context.semanticBaselineSequence)
        }
    }

    static func applyScopedChange(
        _ change: RepoExplorerScopedProjectionChange,
        request: RepoExplorerProjectionRequest,
        previous: RepoExplorerProjectionResult
    ) -> RepoExplorerProjectionResult? {
        switch change {
        case .repo, .pane, .tab:
            return nil
        case .repositoryActivity(let repositoryID):
            return applyScopedRepositoryActivityChange(
                repositoryID: repositoryID,
                request: request,
                previous: previous
            )
        case .worktreeFact(let worktreeId):
            return applyScopedWorktreeFactChange(
                worktreeId: worktreeId,
                request: request,
                previous: previous
            )
        }
    }

    func project(_ request: RepoExplorerProjectionRequest) async throws -> RepoExplorerProjectionResult {
        // Runs CPU-bound sidebar projection outside actor/main-actor isolation; cancellation is forwarded below.
        // swiftlint:disable:next no_task_detached
        let projectionTask = Task.detached(priority: .userInitiated) {
            try Self.project(request)
        }

        return try await withTaskCancellationHandler {
            try await projectionTask.value
        } onCancel: {
            projectionTask.cancel()
        }
    }

    static func project(
        _ request: RepoExplorerProjectionRequest
    ) throws -> RepoExplorerProjectionResult {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let workerStart = clock.now
        let branchStatusByWorktreeId = try branchStatusByWorktreeId(
            snapshot: request.snapshot,
            worktreeEnrichmentByWorktreeId: request.worktreeEnrichmentSnapshot,
            pullRequestFactsByBranch: request.pullRequestFactsSnapshot,
            loadingPullRequestRepoIds: request.loadingPullRequestRepoIds,
            unavailablePullRequestRepoIds: request.unavailablePullRequestRepoIds,
            cancellationCheck: { try Task.checkCancellation() }
        )
        let branchNameByWorktreeId = try branchNameByWorktreeId(
            snapshot: request.snapshot,
            worktreeEnrichmentByWorktreeId: request.worktreeEnrichmentSnapshot,
            cancellationCheck: { try Task.checkCancellation() }
        )
        let activity = repositoryActivityClassification(for: request)
        let paneRowFactsByPaneId = preparedPaneRowFacts(
            request.paneRowFactsByPaneId,
            snapshot: request.snapshot
        )
        let sidebarPresentationTransitionAtByPaneId = sidebarPresentationTransitions(
            paneRowFactsByPaneId,
            snapshot: request.snapshot
        )
        let preparedPresentationDeadline = RepoExplorerPreparedPresentationDeadline.prepare(
            sidebarTransitionsByPaneID: sidebarPresentationTransitionAtByPaneId,
            repositoryTransitionsByRepositoryID: activity.transitionAtByRepositoryID,
            referenceInstant: request.snapshot.surface == .panes ? request.snapshot.referenceInstant : nil,
            referenceDate: request.snapshot.surface == .panes ? request.snapshot.referenceDate : nil
        )
        let projectionStart = clock.now
        let projection = try RepoExplorerProjection.projectCancellable(
            request.snapshot,
            paneRowFactsByPaneId: paneRowFactsByPaneId,
            tabGroupFactsByTabId: request.tabGroupFactsByTabId,
            branchNameByWorktreeId: branchNameByWorktreeId,
            branchStatusByWorktreeId: branchStatusByWorktreeId,
            cancellationCheck: { try Task.checkCancellation() }
        )
        let projectionDuration = projectionStart.duration(to: clock.now)
        try Task.checkCancellation()
        let rowIndexStart = clock.now
        let rowIndex = RepoExplorerRowIndex(
            projection: projection,
            collapsedGroupIds: request.collapsedGroupIds,
            isFiltering: request.isFiltering && !RepoExplorerFilter.normalizedQuery(request.snapshot.query).isEmpty
        )
        let rowIndexDuration = rowIndexStart.duration(to: clock.now)
        try Task.checkCancellation()
        let bridgeCommandResolutionByWorktreeId = try bridgeCommandResolutionByWorktreeId(
            snapshot: request.snapshot,
            cancellationCheck: { try Task.checkCancellation() }
        )
        try Task.checkCancellation()
        let materializationSnapshot = RepoExplorerMaterializationSnapshot.build(
            rowIndex: rowIndex,
            inputs: RepoExplorerMaterializationInputs(
                snapshot: request.snapshot,
                projection: projection,
                branchStatusByWorktreeID: branchStatusByWorktreeId,
                branchNameByWorktreeID: branchNameByWorktreeId,
                bridgeCommandResolutionByWorktreeID: bridgeCommandResolutionByWorktreeId,
                paneRowFactsByPaneID: paneRowFactsByPaneId,
                repositoryActivityDispositionByRepoID: activity.dispositionByRepositoryID,
                repositoryFactUpdateProgressByRepoID: request.repositoryFactUpdateProgressByRepoId
            )
        )
        try Task.checkCancellation()
        return RepoExplorerProjectionResult(
            generation: request.generation,
            snapshot: request.snapshot,
            collapsedGroupIds: request.collapsedGroupIds,
            isFiltering: request.isFiltering,
            trigger: request.trigger,
            projection: projection,
            rowIndex: rowIndex,
            materializationSnapshot: materializationSnapshot,
            workerDuration: workerStart.duration(to: clock.now),
            projectionDuration: projectionDuration,
            rowIndexDuration: rowIndexDuration,
            branchStatusByWorktreeId: branchStatusByWorktreeId,
            branchNameByWorktreeId: branchNameByWorktreeId,
            bridgeCommandResolutionByWorktreeId: bridgeCommandResolutionByWorktreeId,
            paneRowFactsByPaneId: paneRowFactsByPaneId,
            tabGroupFactsByTabId: request.tabGroupFactsByTabId,
            repositoryActivityDispositionByRepoId: activity.dispositionByRepositoryID,
            repositoryActivityTransitionAtByRepoId: activity.transitionAtByRepositoryID,
            sidebarPresentationTransitionAtByPaneId: sidebarPresentationTransitionAtByPaneId,
            preparedPresentationDeadline: preparedPresentationDeadline,
            semanticBaselineSequence: nil
        )
    }

    private static func bridgeCommandResolutionByWorktreeId(
        snapshot: RepoExplorerSnapshot,
        cancellationCheck: () throws -> Void
    ) throws -> [UUID: BridgePaneCommandResolution] {
        var resolutionsByWorktreeId: [UUID: BridgePaneCommandResolution] = [:]
        let worktrees = snapshot.repos.flatMap(\.worktrees)
        resolutionsByWorktreeId.reserveCapacity(worktrees.count)
        for (index, worktree) in worktrees.enumerated()
        where resolutionsByWorktreeId[worktree.id] == nil {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            resolutionsByWorktreeId[worktree.id] = BridgePaneCommandResolver.resolve(
                worktreeId: worktree.id,
                candidates: snapshot.bridgePaneCommandCandidatesByWorktreeId[worktree.id, default: []]
            )
        }
        return resolutionsByWorktreeId
    }

    private static func branchStatusByWorktreeId(
        snapshot: RepoExplorerSnapshot,
        worktreeEnrichmentByWorktreeId: [UUID: WorktreeEnrichment],
        pullRequestFactsByBranch: [RepoBranchKey: PullRequestFacts],
        loadingPullRequestRepoIds: Set<UUID>,
        unavailablePullRequestRepoIds: Set<UUID>,
        cancellationCheck: () throws -> Void
    ) throws -> [UUID: GitBranchStatus] {
        let worktreeIds = snapshot.repos.flatMap(\.worktrees).map(\.id)
        var branchStatusByWorktreeId = GitBranchStatus.merge(
            worktreeEnrichmentsByWorktreeId: worktreeEnrichmentByWorktreeId,
            pullRequestFactsByBranch: pullRequestFactsByBranch,
            loadingPullRequestRepoIds: loadingPullRequestRepoIds,
            unavailablePullRequestRepoIds: unavailablePullRequestRepoIds
        )
        branchStatusByWorktreeId.reserveCapacity(max(branchStatusByWorktreeId.count, worktreeIds.count))
        for (index, worktreeId) in worktreeIds.enumerated() where branchStatusByWorktreeId[worktreeId] == nil {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            branchStatusByWorktreeId[worktreeId] = .unknown
        }
        return branchStatusByWorktreeId
    }

    private static func branchNameByWorktreeId(
        snapshot: RepoExplorerSnapshot,
        worktreeEnrichmentByWorktreeId: [UUID: WorktreeEnrichment],
        cancellationCheck: () throws -> Void
    ) throws -> [UUID: String] {
        var branchNames: [UUID: String] = [:]
        for (index, worktree) in snapshot.repos.flatMap(\.worktrees).enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            branchNames[worktree.id] = branchName(
                enrichment: worktreeEnrichmentByWorktreeId[worktree.id]
            )
        }
        return branchNames
    }

    /// Absent until the worktree's enrichment arrives, so a pane row can tell "not known yet"
    /// (no line) from git's own detached answer.
    private static func branchName(enrichment: WorktreeEnrichment?) -> String? {
        guard let enrichment else { return nil }
        let cachedBranch = enrichment.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cachedBranch.isEmpty {
            return cachedBranch
        }

        return "detached HEAD"
    }

    private static func applyScopedWorktreeFactChange(
        worktreeId: UUID,
        request: RepoExplorerProjectionRequest,
        previous: RepoExplorerProjectionResult
    ) -> RepoExplorerProjectionResult? {
        guard
            request.snapshot.repos.contains(where: { repo in
                repo.worktrees.contains(where: { $0.id == worktreeId })
            })
        else { return nil }
        var branchStatuses = previous.branchStatusByWorktreeId
        var branchNames = previous.branchNameByWorktreeId
        var bridgeCommandResolutions = previous.bridgeCommandResolutionByWorktreeId
        let enrichment = request.worktreeEnrichmentSnapshot[worktreeId]
        let pullRequestFacts =
            enrichment
            .flatMap { RepoBranchKey(repoId: $0.repoId, branch: $0.branch) }
            .flatMap { request.pullRequestFactsSnapshot[$0] }
        branchStatuses[worktreeId] = GitBranchStatus.status(
            enrichment: enrichment,
            pullRequestFacts: pullRequestFacts,
            pullRequestIsLoading: enrichment.map { request.loadingPullRequestRepoIds.contains($0.repoId) }
                ?? false,
            pullRequestDataUnavailable: enrichment.map { request.unavailablePullRequestRepoIds.contains($0.repoId) }
                ?? false
        )
        branchNames[worktreeId] = branchName(enrichment: enrichment)
        bridgeCommandResolutions[worktreeId] = BridgePaneCommandResolver.resolve(
            worktreeId: worktreeId,
            candidates: request.snapshot.bridgePaneCommandCandidatesByWorktreeId[worktreeId, default: []]
        )
        let materializationSnapshot = RepoExplorerMaterializationSnapshot.build(
            rowIndex: previous.rowIndex,
            inputs: RepoExplorerMaterializationInputs(
                snapshot: request.snapshot,
                projection: previous.projection,
                branchStatusByWorktreeID: branchStatuses,
                branchNameByWorktreeID: branchNames,
                bridgeCommandResolutionByWorktreeID: bridgeCommandResolutions,
                paneRowFactsByPaneID: request.paneRowFactsByPaneId,
                repositoryActivityDispositionByRepoID: previous.repositoryActivityDispositionByRepoId,
                repositoryFactUpdateProgressByRepoID: request.repositoryFactUpdateProgressByRepoId
            )
        )
        return RepoExplorerProjectionResult(
            generation: request.generation,
            snapshot: request.snapshot,
            collapsedGroupIds: request.collapsedGroupIds,
            isFiltering: request.isFiltering,
            trigger: request.trigger,
            projection: previous.projection,
            rowIndex: previous.rowIndex,
            materializationSnapshot: materializationSnapshot,
            workerDuration: .zero,
            projectionDuration: .zero,
            rowIndexDuration: .zero,
            branchStatusByWorktreeId: branchStatuses,
            branchNameByWorktreeId: branchNames,
            bridgeCommandResolutionByWorktreeId: bridgeCommandResolutions,
            paneRowFactsByPaneId: request.paneRowFactsByPaneId,
            tabGroupFactsByTabId: request.tabGroupFactsByTabId,
            repositoryActivityDispositionByRepoId: previous.repositoryActivityDispositionByRepoId,
            repositoryActivityTransitionAtByRepoId: previous.repositoryActivityTransitionAtByRepoId,
            sidebarPresentationTransitionAtByPaneId: previous.sidebarPresentationTransitionAtByPaneId,
            preparedPresentationDeadline: previous.preparedPresentationDeadline,
            semanticBaselineSequence: nil
        )
    }

}

extension RepoExplorerProjectionResult {
    fileprivate func withSemanticBaselineSequence(_ semanticBaselineSequence: UInt64) -> Self {
        Self(
            generation: generation,
            snapshot: snapshot,
            collapsedGroupIds: collapsedGroupIds,
            isFiltering: isFiltering,
            trigger: trigger,
            projection: projection,
            rowIndex: rowIndex,
            materializationSnapshot: materializationSnapshot,
            workerDuration: workerDuration,
            projectionDuration: projectionDuration,
            rowIndexDuration: rowIndexDuration,
            branchStatusByWorktreeId: branchStatusByWorktreeId,
            branchNameByWorktreeId: branchNameByWorktreeId,
            bridgeCommandResolutionByWorktreeId: bridgeCommandResolutionByWorktreeId,
            paneRowFactsByPaneId: paneRowFactsByPaneId,
            tabGroupFactsByTabId: tabGroupFactsByTabId,
            repositoryActivityDispositionByRepoId: repositoryActivityDispositionByRepoId,
            repositoryActivityTransitionAtByRepoId: repositoryActivityTransitionAtByRepoId,
            sidebarPresentationTransitionAtByPaneId: sidebarPresentationTransitionAtByPaneId,
            preparedPresentationDeadline: preparedPresentationDeadline,
            semanticBaselineSequence: semanticBaselineSequence
        )
    }
}
