import AgentStudioCore
import Foundation

enum RepoExplorerObservationToken: Hashable, Sendable {
    case demand
    case presentation
    case membership
    case stableIdentity
    case repository(UUID)
    case worktree(UUID)
    case paneStructure(UUID)
    case paneActivity(UUID)
    case pane(UUID)
    case tabStructure(UUID)
    case tab(UUID)
    case attention
    case activityHydration
    case repositoryActivity(repositoryID: UUID, stableKey: String)
}

enum RepoExplorerInputInvalidation: Equatable, Sendable {
    case structural
    case presentation
    case stableIdentity
    case repository(UUID)
    case worktree(UUID)
    case pane(UUID)
    case tab(UUID)
    case attention
    case activityHydration
    case repositoryActivity(UUID)
}

struct RepoExplorerScopedCapture: Sendable {
    let request: RepoExplorerProjectionRequest
    let changes: Set<RepoExplorerScopedProjectionChange>
    let requiresFullProjection: Bool
    let requiresObservationRetarget: Bool

    init(
        request: RepoExplorerProjectionRequest,
        changes: Set<RepoExplorerScopedProjectionChange>,
        requiresFullProjection: Bool,
        requiresObservationRetarget: Bool = false
    ) {
        self.request = request
        self.changes = changes
        self.requiresFullProjection = requiresFullProjection
        self.requiresObservationRetarget = requiresObservationRetarget
    }
}

extension RepoExplorerProjectionInputCapture {
    func observe(_ token: RepoExplorerObservationToken, request: RepoExplorerProjectionRequest?) {
        switch token {
        case .demand:
            _ = sidebarState.sidebarSurface
        case .presentation:
            let surface = sidebarState.sidebarSurface
            _ = preferences.groupingMode(for: surface)
            _ = preferences.subgroupMode(for: surface)
            _ = preferences.sortField(for: surface)
            _ = preferences.sortDirection(for: surface)
            _ = preferences.showsPinned(for: surface)
            if surface == .panes {
                _ = preferences.showsDrawerPanes
            }
            _ = sidebarCache.collapsedGroups
        case .membership:
            _ = store.repositoryTopologyAtom.repositoryIdsInOrder
            _ = store.repositoryTopologyAtom.worktreePathIndexGeneration
            _ = store.paneAtom.graphAtom.paneIDs
            _ = store.tabShellAtom.orderedTabIds
        case .stableIdentity:
            _ = store.repositoryTopologyAtom.stableIdentityRevision
        case .repository(let repositoryID):
            _ = store.repositoryTopologyAtom.repo(repositoryID)
            _ = repoCache.repoEnrichment(for: repositoryID)
            _ = repoCache.isPullRequestLoading(forRepository: repositoryID)
            _ = repoCache.isPullRequestDataUnavailable(forRepository: repositoryID)
            _ = repoCache.repositoryFactUpdateProgress(for: repositoryID)
        case .worktree(let worktreeID):
            _ = store.repositoryTopologyAtom.worktree(worktreeID)
            let enrichment = repoCache.worktreeEnrichment(for: worktreeID)
            if let enrichment,
                let branchKey = RepoBranchKey(repoId: enrichment.repoId, branch: enrichment.branch)
            {
                _ = repoCache.pullRequestFacts(for: branchKey)
            }
        case .paneStructure(let paneID):
            _ = store.paneAtom.graphAtom.paneStructuralFacts(paneID)
        case .paneActivity(let paneID):
            _ = latestPaneMessageSnapshot(paneID)
        case .pane(let paneID):
            _ = store.paneAtom.pane(paneID)
            _ = latestPaneMessageSnapshot(paneID)
            _ = bridgeAttendanceSnapshot(paneID)
            if request?.snapshot.surface == .panes {
                _ = sessionStatusForPane(PaneId(existingUUID: paneID))
                _ = contextDisplayForPane(PaneId(existingUUID: paneID))
                _ = coreAtoms.paneActivityTime.value(for: paneID)
            } else {
                _ = coreAtoms.workspaceEntityRecency.recency(for: .pane(paneID: paneID))
            }
        case .tabStructure(let tabID):
            _ = store.tabArrangementAtom.arrangementState(tabID)
        case .tab(let tabID):
            guard let tab = store.tabLayoutAtom.tab(tabID) else { return }
            _ = coreAtoms.tabDisplay.displayTitle(
                for: tab,
                workspacePane: store.paneAtom,
                workspaceRepositoryTopology: store.repositoryTopologyAtom,
                repoCache: repoCache
            )
        case .attention:
            _ = KeyboardRoutingContext.current(
                windowLifecycle: coreAtoms.windowLifecycle,
                managementLayer: coreAtoms.managementLayer,
                uiState: sidebarState,
                commandBarSurface: coreAtoms.commandBarSurface,
                transientKeyboardSurface: coreAtoms.transientKeyboardSurface
            )
            _ = coreAtoms.attendedPane.attendedPaneId
        case .activityHydration:
            _ = coreAtoms.repositoryLocalActivity.hydrationDisposition
        case .repositoryActivity(_, let stableKey):
            _ = coreAtoms.repositoryLocalActivity.activity(for: stableKey)
        }
    }

    func observationTokens(for request: RepoExplorerProjectionRequest) -> Set<RepoExplorerObservationToken> {
        let structuralPaneIDs = store.tabLayoutAtom.allPaneIds
        let presentedPaneIDs = demandedPaneIDs(in: request.snapshot)
        let structuralTabIDs = demandedTabIDs(in: request.snapshot)
        var tokens: Set<RepoExplorerObservationToken> = [
            .demand, .presentation, .membership, .stableIdentity,
        ]
        tokens.formUnion(request.snapshot.repos.map { .repository($0.id) })
        tokens.formUnion(request.snapshot.repos.flatMap(\.worktrees).map { .worktree($0.id) })
        tokens.formUnion(structuralPaneIDs.map(RepoExplorerObservationToken.paneStructure))
        tokens.formUnion(structuralTabIDs.map(RepoExplorerObservationToken.tabStructure))
        if request.snapshot.surface == .repos {
            tokens.insert(.activityHydration)
            tokens.formUnion(
                request.snapshot.repos.map {
                    .repositoryActivity(repositoryID: $0.id, stableKey: $0.stableKey)
                }
            )
        }
        if request.snapshot.surface == .panes {
            tokens.formUnion(presentedPaneIDs.map(RepoExplorerObservationToken.pane))
            tokens.insert(.attention)
        } else if request.snapshot.groupingMode == .activity || request.snapshot.sortField == .activity {
            tokens.formUnion(presentedPaneIDs.map(RepoExplorerObservationToken.paneActivity))
        }
        if request.snapshot.surface == .panes && request.snapshot.groupingMode == .tab {
            tokens.formUnion(structuralTabIDs.map(RepoExplorerObservationToken.tab))
        }
        return tokens
    }

    func invalidation(for token: RepoExplorerObservationToken) -> RepoExplorerInputInvalidation {
        switch token {
        case .demand, .membership, .paneStructure, .tabStructure:
            .structural
        case .presentation:
            .presentation
        case .stableIdentity:
            .stableIdentity
        case .repository(let repositoryID):
            .repository(repositoryID)
        case .worktree(let worktreeID):
            .worktree(worktreeID)
        case .paneActivity(let paneID), .pane(let paneID):
            .pane(paneID)
        case .tab(let tabID):
            .tab(tabID)
        case .attention:
            .attention
        case .activityHydration:
            .activityHydration
        case .repositoryActivity(let repositoryID, _):
            .repositoryActivity(repositoryID)
        }
    }
}
