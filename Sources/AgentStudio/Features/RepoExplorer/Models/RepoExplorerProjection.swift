import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

enum RepoExplorerProjection {
    static func project(
        _ snapshot: RepoExplorerSnapshot,
        paneRowFactsByPaneId: [UUID: RepoExplorerPaneRowFacts] = [:],
        tabGroupFactsByTabId: [UUID: RepoExplorerTabGroupFacts] = [:],
        branchNameByWorktreeId: [UUID: String] = [:],
        branchStatusByWorktreeId: [UUID: GitBranchStatus] = [:]
    ) -> RepoExplorerSidebarProjection {
        projectCancellable(
            snapshot,
            paneRowFactsByPaneId: paneRowFactsByPaneId,
            tabGroupFactsByTabId: tabGroupFactsByTabId,
            branchNameByWorktreeId: branchNameByWorktreeId,
            branchStatusByWorktreeId: branchStatusByWorktreeId,
            cancellationCheck: {}
        )
    }

    static func projectCancellable(
        _ snapshot: RepoExplorerSnapshot,
        paneRowFactsByPaneId: [UUID: RepoExplorerPaneRowFacts] = [:],
        tabGroupFactsByTabId: [UUID: RepoExplorerTabGroupFacts] = [:],
        branchNameByWorktreeId: [UUID: String] = [:],
        branchStatusByWorktreeId: [UUID: GitBranchStatus] = [:],
        cancellationCheck: () throws -> Void
    ) rethrows -> RepoExplorerSidebarProjection {
        try cancellationCheck()
        if let degradedProjection = degradedProjectionIfTopologyFault(in: snapshot.repos) {
            return degradedProjection
        }
        let query = RepoExplorerFilter.normalizedQuery(snapshot.query)
        let resolvedRepos = resolvedRepos(snapshot.repos, enrichmentByRepoId: snapshot.repoEnrichmentSnapshotByRepoId)
        let filteredResolvedRepos = RepoExplorerFilter.filter(repos: resolvedRepos, query: query)
        let filteredLoadingRepos = filterLoadingRepos(
            unresolvedRepos(snapshot.repos, enrichmentByRepoId: snapshot.repoEnrichmentSnapshotByRepoId),
            query: query,
            sortOrder: .ascending
        )
        let repoMetadataById = RepoPresentationColoring.buildRepoMetadata(
            repos: filteredResolvedRepos,
            repoEnrichmentByRepoId: snapshot.repoEnrichmentSnapshotByRepoId
        )
        let checkoutColorHexByRepoId = checkoutColorHexByRepoId(
            repos: filteredResolvedRepos,
            metadataByRepoId: repoMetadataById
        )
        let paneDestinationsByWorktreeId = try paneDestinationsByWorktreeId(
            repos: snapshot.repos,
            locationsByWorktreeId: snapshot.paneLocationsByWorktreeId,
            paneRowFactsByPaneId: paneRowFactsByPaneId,
            cancellationCheck: cancellationCheck
        )
        let paneDestinationsByRepoId = paneDestinationsByRepoId(
            repos: snapshot.repos,
            destinationsByWorktreeId: paneDestinationsByWorktreeId
        )
        let unassociatedPaneDestinations = unassociatedPaneDestinations(snapshot)
        let paneBranchFacts = RepoExplorerPaneBranchProjectionFacts(
            namesByWorktreeId: branchNameByWorktreeId,
            statusesByWorktreeId: branchStatusByWorktreeId
        )
        let organizationInput = RepoExplorerOrganizationInput(
            snapshot: snapshot,
            eligibleRepositories: snapshot.surface == .panes
                ? RepoExplorerFilter.filter(repos: snapshot.repos, query: query)
                : filteredResolvedRepos,
            loadingRepos: filteredLoadingRepos,
            metadataByRepoId: repoMetadataById,
            checkoutColors: checkoutColorHexByRepoId,
            destinationsByWorktreeId: paneDestinationsByWorktreeId,
            destinationsByRepoId: paneDestinationsByRepoId,
            unassociatedDestinations: unassociatedPaneDestinations,
            paneFacts: paneRowFactsByPaneId,
            tabFacts: tabGroupFactsByTabId,
            branchFacts: paneBranchFacts
        )
        let organization =
            snapshot.surface == .panes
            ? organizedPanesByActivity(organizationInput)
            : organizedContent(organizationInput)
        let sections = organization.sections
        let orderedResolvedGroups = sections.flatMap(\.resolvedGroups)
        let orderedLoadingRepos = sections.flatMap(\.loadingRepos)

        return .ready(
            RepoExplorerSidebarContent(
                sections: sections,
                resolvedGroups: orderedResolvedGroups,
                worktreeRowsByGroupId: organization.worktreeRows,
                paneRowsByGroupId: organization.paneRows,
                paneDestinationsByWorktreeId: paneDestinationsByWorktreeId,
                paneDestinationsByRepoId: paneDestinationsByRepoId,
                loadingRepos: orderedLoadingRepos,
                emptyState: emptyState(
                    snapshot: snapshot,
                    resolvedGroups: orderedResolvedGroups,
                    loadingRepos: orderedLoadingRepos,
                    hasUnassociatedPanes: false
                )
            )
        )
    }

    private static func unassociatedPaneDestinations(
        _ snapshot: RepoExplorerSnapshot
    ) -> [RepoExplorerUnassociatedPaneDestination] {
        let destinations = RepoExplorerPaneLocationProjection.unassociatedDestinations(
            from: sortedUniqueLocations(snapshot.unassociatedPaneLocations)
        )
        let query = snapshot.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return destinations }
        return destinations.filter { destination in
            let activeLabel = destination.isActiveInTab ? " active" : ""
            let searchableLabel =
                "ungrouped tab \(destination.tabIndex + 1) pane \(destination.paneIndexInTab + 1)\(activeLabel)"
            return searchableLabel.localizedCaseInsensitiveContains(query)
        }
    }

    private static func emptyState(
        snapshot: RepoExplorerSnapshot,
        resolvedGroups: [RepoPresentationGroup],
        loadingRepos: [RepoPresentationItem],
        hasUnassociatedPanes: Bool
    ) -> RepoExplorerEmptyState {
        guard resolvedGroups.isEmpty && loadingRepos.isEmpty && !hasUnassociatedPanes else { return .content }
        if !RepoExplorerFilter.normalizedQuery(snapshot.query).isEmpty {
            return .searchNoResults
        }
        return snapshot.surface == .repos ? .noRepositories : .noPanes
    }

    private static func checkoutColorHexByRepoId(
        repos: [RepoPresentationItem],
        metadataByRepoId: [UUID: RepoIdentityMetadata]
    ) -> [UUID: String] {
        let sourceGroups = RepoPresentationGrouping.buildGroups(
            repos: repos,
            metadataByRepoId: metadataByRepoId
        )
        return Dictionary(
            uniqueKeysWithValues: sourceGroups.flatMap { group in
                group.repos.map { repo in
                    (
                        repo.id,
                        RepoPresentationColoring.checkoutColorHex(
                            for: repo,
                            in: group
                        )
                    )
                }
            })
    }

    static func resolvedRepos(
        _ repos: [RepoPresentationItem],
        enrichmentByRepoId: [UUID: RepoEnrichment]
    ) -> [RepoPresentationItem] {
        repos.filter { repo in
            switch enrichmentByRepoId[repo.id] {
            case .resolvedLocal, .resolvedRemote:
                return true
            case .awaitingOrigin, .statusUnavailable, .none:
                return false
            }
        }
    }

    static func loadingRepos(
        _ repos: [RepoPresentationItem],
        enrichmentByRepoId: [UUID: RepoEnrichment]
    ) -> [RepoPresentationItem] {
        repos.filter { repo in
            switch enrichmentByRepoId[repo.id] {
            case .resolvedLocal, .resolvedRemote:
                return false
            case .awaitingOrigin, .none:
                return true
            case .statusUnavailable:
                return false
            }
        }
    }

    private static func unresolvedRepos(
        _ repos: [RepoPresentationItem],
        enrichmentByRepoId: [UUID: RepoEnrichment]
    ) -> [RepoPresentationItem] {
        loadingRepos(repos, enrichmentByRepoId: enrichmentByRepoId)
            + statusUnavailableRepos(repos, enrichmentByRepoId: enrichmentByRepoId)
    }

    static func statusUnavailableRepos(
        _ repos: [RepoPresentationItem],
        enrichmentByRepoId: [UUID: RepoEnrichment]
    ) -> [RepoPresentationItem] {
        repos.filter { repo in
            if case .statusUnavailable = enrichmentByRepoId[repo.id] { return true }
            return false
        }
    }

    private static func filterLoadingRepos(
        _ repos: [RepoPresentationItem],
        query: String,
        sortOrder: RepoExplorerSortOrder
    ) -> [RepoPresentationItem] {
        let filteredRepos: [RepoPresentationItem]
        if query.isEmpty {
            filteredRepos = repos
        } else {
            filteredRepos = repos.filter { repo in
                repo.name.localizedCaseInsensitiveContains(query)
            }
        }

        return sortedRepos(filteredRepos, sortOrder: sortOrder)
    }

    static func repoIdentityGroups(
        repos: [RepoPresentationItem],
        metadataByRepoId: [UUID: RepoIdentityMetadata],
        sortOrder: RepoExplorerSortOrder
    ) -> [RepoPresentationGroup] {
        repos.compactMap { repo -> RepoPresentationGroup? in
            guard !repo.worktrees.isEmpty else { return nil }
            let metadata = metadataByRepoId[repo.id]
            var projectedRepo = repo
            projectedRepo.worktrees = sortedWorktrees(repo.worktrees, sortOrder: sortOrder)
            return RepoPresentationGroup(
                id: "repo:\(repo.id.uuidString)",
                repoTitle: metadata?.repoName ?? repo.name,
                organizationName: metadata?.organizationName,
                repos: [projectedRepo]
            )
        }
        .sorted { lhs, rhs in
            repoGroupPrecedes(lhs, rhs, sortOrder: sortOrder)
        }
    }

    static func remoteIdentityGroups(
        repos: [RepoPresentationItem],
        metadataByRepoId: [UUID: RepoIdentityMetadata],
        sortOrder: RepoExplorerSortOrder
    ) -> [RepoPresentationGroup] {
        RepoPresentationGrouping.buildGroups(repos: repos, metadataByRepoId: metadataByRepoId)
            .map { group in
                RepoPresentationGroup(
                    id: group.id,
                    repoTitle: group.repoTitle,
                    organizationName: group.organizationName,
                    repos: group.repos.map { repo in
                        var projectedRepo = repo
                        projectedRepo.worktrees = sortedWorktrees(repo.worktrees, sortOrder: sortOrder)
                        return projectedRepo
                    }
                )
            }
            .sorted { repoGroupPrecedes($0, $1, sortOrder: sortOrder) }
    }

    static func repoGroupPrecedes(
        _ lhs: RepoPresentationGroup,
        _ rhs: RepoPresentationGroup,
        sortOrder: RepoExplorerSortOrder
    ) -> Bool {
        let leftTitle = lhs.organizationName.map { "\(lhs.repoTitle)\($0)" } ?? lhs.repoTitle
        let rightTitle = rhs.organizationName.map { "\(rhs.repoTitle)\($0)" } ?? rhs.repoTitle
        if leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedSame {
            return lhs.id < rhs.id
        }
        return compare(leftTitle, rightTitle, sortOrder: sortOrder)
    }

    private static func paneDestinationsByWorktreeId(
        repos: [RepoPresentationItem],
        locationsByWorktreeId: [UUID: [WorkspacePaneLocation]],
        paneRowFactsByPaneId: [UUID: RepoExplorerPaneRowFacts],
        cancellationCheck: () throws -> Void
    ) rethrows -> [UUID: [RepoExplorerPaneDestination]] {
        var destinationsByWorktreeId: [UUID: [RepoExplorerPaneDestination]] = [:]
        var processedWorktreeCount = 0
        for repo in repos {
            for worktree in repo.worktrees {
                if processedWorktreeCount.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                processedWorktreeCount += 1
                let destinations = sortedUniqueLocations(locationsByWorktreeId[worktree.id, default: []])
                    .map { location in
                        RepoExplorerPaneDestination(
                            paneId: location.paneId,
                            repoId: repo.id,
                            worktreeId: worktree.id,
                            worktreeLabel: worktree.name,
                            tabId: location.tabId,
                            tabIndex: location.tabIndex,
                            paneIndexInTab: location.paneIndexInTab,
                            isActiveInTab: location.isActiveInTab,
                            paneDisplayLabel: paneRowFactsByPaneId[location.paneId]?.terminalTitle
                                ?? "Pane \(location.paneIndexInTab + 1)"
                        )
                    }
                    .sorted(by: paneDestinationPrecedes)
                if !destinations.isEmpty {
                    destinationsByWorktreeId[worktree.id] = destinations
                }
            }
        }
        return destinationsByWorktreeId
    }

    private static func paneDestinationsByRepoId(
        repos: [RepoPresentationItem],
        destinationsByWorktreeId: [UUID: [RepoExplorerPaneDestination]]
    ) -> [UUID: [RepoExplorerPaneDestination]] {
        Dictionary(
            uniqueKeysWithValues: repos.compactMap { repo in
                let destinations = repo.worktrees
                    .flatMap { destinationsByWorktreeId[$0.id, default: []] }
                    .sorted(by: paneDestinationPrecedes)
                return destinations.isEmpty ? nil : (repo.id, destinations)
            }
        )
    }

    private static func paneDestinationPrecedes(
        _ lhs: RepoExplorerPaneDestination,
        _ rhs: RepoExplorerPaneDestination
    ) -> Bool {
        if lhs.tabIndex != rhs.tabIndex { return lhs.tabIndex < rhs.tabIndex }
        if lhs.paneIndexInTab != rhs.paneIndexInTab { return lhs.paneIndexInTab < rhs.paneIndexInTab }
        return lhs.paneId.uuidString < rhs.paneId.uuidString
    }

    static func panePrimaryText(
        _ destination: RepoExplorerProjectedPaneDestination,
        terminalTitle: String?,
        showsPaneNumber: Bool
    ) -> String {
        let normalizedTitle = terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity =
            normalizedTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Pane \(destination.paneIndexInTab + 1)"
        return showsPaneNumber ? "\(identity) · Pane \(destination.paneIndexInTab + 1)" : identity
    }

    /// A missing fact means branch facts have not arrived yet, so the line stays out rather than
    /// flashing "unknown branch" at launch. Git's own detached or unknown answers name the state.
    static func normalizedBranchName(_ branchName: String?) -> String? {
        guard let branchName else { return nil }
        let normalizedName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty || normalizedName == "Unknown branch" { return "unknown branch" }
        if normalizedName == "detached HEAD" { return "detached" }
        return normalizedName
    }

    static func worktreeRowsByGroupId(
        from groups: [RepoPresentationGroup],
        checkoutColorHexByRepoId: [UUID: String]
    ) -> [String: [RepoExplorerProjectedWorktreeRow]] {
        Dictionary(
            uniqueKeysWithValues: groups.map { group in
                let rows = group.repos.flatMap { repo in
                    repo.worktrees.map { worktree in
                        RepoExplorerProjectedWorktreeRow(
                            groupId: group.id,
                            repo: repo,
                            worktree: worktree,
                            rowId: rowId(
                                groupId: group.id,
                                repoId: repo.id,
                                worktreeId: worktree.id,
                                location: nil
                            ),
                            checkoutColorHex: checkoutColorHexByRepoId[repo.id]
                                ?? RepoPresentationColoring.checkoutColorHex(
                                    for: repo,
                                    in: group
                                ),
                            placementContext: nil
                        )
                    }
                }
                return (group.id, rows)
            })
    }

    private static func rowId(
        groupId: String,
        repoId: UUID,
        worktreeId: UUID,
        location: WorkspacePaneLocation?
    ) -> String {
        let placementToken = location.map { "pane:\($0.paneId.uuidString)" } ?? "inactive"
        return "worktree:\(groupId):\(repoId.uuidString):\(worktreeId.uuidString):\(placementToken)"
    }

    static func sortedRepos(
        _ repos: [RepoPresentationItem],
        sortOrder: RepoExplorerSortOrder
    ) -> [RepoPresentationItem] {
        repos.sorted { lhs, rhs in
            compare(lhs.name, rhs.name, sortOrder: sortOrder)
        }
    }

    private static func sortedWorktrees(
        _ worktrees: [Worktree],
        sortOrder: RepoExplorerSortOrder
    ) -> [Worktree] {
        worktrees.sorted { lhs, rhs in
            if lhs.isMainWorktree != rhs.isMainWorktree {
                return lhs.isMainWorktree
            }
            return compare(lhs.name, rhs.name, sortOrder: sortOrder)
        }
    }

    private static func compare(
        _ lhs: String,
        _ rhs: String,
        sortOrder: RepoExplorerSortOrder
    ) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        switch sortOrder {
        case .ascending:
            return comparison == .orderedAscending
        case .descending:
            return comparison == .orderedDescending
        }
    }

    private static func sortedUniqueLocations(_ locations: [WorkspacePaneLocation]) -> [WorkspacePaneLocation] {
        var seenPaneIds = Set<UUID>()
        return
            locations
            .sorted { lhs, rhs in
                if lhs.tabIndex != rhs.tabIndex {
                    return lhs.tabIndex > rhs.tabIndex
                }
                if lhs.paneIndexInTab != rhs.paneIndexInTab {
                    return lhs.paneIndexInTab > rhs.paneIndexInTab
                }
                return lhs.paneId.uuidString < rhs.paneId.uuidString
            }
            .filter { seenPaneIds.insert($0.paneId).inserted }
    }

}
