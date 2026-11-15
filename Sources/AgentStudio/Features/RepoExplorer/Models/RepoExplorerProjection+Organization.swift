import AgentStudioCore
import Foundation

/// Runs inside the existing detached projection. Membership is established before
/// grouping; leaf sorting can therefore never move an item between sections.
struct RepoExplorerOrganizedContent {
    var sections: [RepoExplorerSidebarSection] = []
    var worktreeRows: [String: [RepoExplorerProjectedWorktreeRow]] = [:]
    var paneRows: [String: [RepoExplorerProjectedPaneRow]] = [:]
}

struct RepoExplorerOrganizationInput {
    let snapshot: RepoExplorerSnapshot
    let eligibleRepositories: [RepoPresentationItem]
    let loadingRepos: [RepoPresentationItem]
    let metadataByRepoId: [UUID: RepoIdentityMetadata]
    let checkoutColors: [UUID: String]
    let destinationsByWorktreeId: [UUID: [RepoExplorerPaneDestination]]
    let destinationsByRepoId: [UUID: [RepoExplorerPaneDestination]]
    let unassociatedDestinations: [RepoExplorerUnassociatedPaneDestination]
    let paneFacts: [UUID: RepoExplorerPaneRowFacts]
    let tabFacts: [UUID: RepoExplorerTabGroupFacts]
    let branchFacts: RepoExplorerPaneBranchProjectionFacts
}

extension RepoExplorerProjection {
    static func organizedContent(_ input: RepoExplorerOrganizationInput) -> RepoExplorerOrganizedContent {
        let snapshot = input.snapshot
        let eligibleRepositories = input.eligibleRepositories
        let paneFacts = input.paneFacts
        let tabFacts = input.tabFacts
        let branchFacts = input.branchFacts
        if snapshot.surface == .repos {
            return organizedRepositories(input)
        }
        let reposById = Dictionary(uniqueKeysWithValues: eligibleRepositories.map { ($0.id, $0) })
        let destinations = organizationPaneDestinations(input)
        var result = RepoExplorerOrganizedContent()
        for sectionKind in [RepoExplorerSidebarSectionKind.pinnedPanes, .panes] {
            let members = destinations.filter { destination in
                let isPinned = snapshot.showsPinned && paneFacts[destination.paneId]?.isPinned == true
                return isPinned == (sectionKind == .pinnedPanes)
            }
            guard !members.isEmpty else { continue }
            let destinationsByID = Dictionary(uniqueKeysWithValues: members.map { ($0.paneId, $0) })
            let organizationInput = RepoExplorerPaneOrganizationInput(
                members: members.map { destination in
                    let title =
                        paneFacts[destination.paneId]?.sidebarTerminalTitle
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return RepoExplorerPaneOrganizationMember(
                        paneID: destination.paneId,
                        repositoryID: destination.repoId,
                        repositoryName: destination.repoId.flatMap { reposById[$0]?.name },
                        tabID: destination.tabId,
                        tabOrder: destination.tabIndex,
                        normalizedTitle: title.isEmpty ? "zsh" : title,
                        isPinned: paneFacts[destination.paneId]?.isPinned == true,
                        activityAt: paneFacts[destination.paneId]?.activityAt
                    )
                },
                preferences: .init(
                    groupingMode: snapshot.groupingMode, subgroupMode: snapshot.subgroupMode,
                    sortField: snapshot.sortField, sortOrder: snapshot.sortOrder,
                    referenceDate: snapshot.referenceDate, calendar: snapshot.calendar
                )
            )
            var groups: [RepoPresentationGroup] = []
            for group in RepoExplorerPaneOrganizationPolicy.orderedGroups(organizationInput) {
                let key: String
                let title: String
                switch group.identity {
                case .repository(let repositoryID, let repositoryName):
                    key = repositoryID?.uuidString ?? "unassociated"
                    title = repositoryName
                case .tab(let tabID, let tabOrder):
                    key = tabID.uuidString
                    title = tabFacts[tabID]?.displayTitle ?? "Tab \(tabOrder + 1)"
                case .activity(let bucket):
                    key = String(bucket.rawValue)
                    title = bucket.title
                }
                let groupId = "panes:\(sectionKind.rawValue):\(snapshot.groupingMode.rawValue):\(key)"
                let memberRepoIds = Set(group.members.compactMap(\.repositoryID))
                groups.append(
                    RepoPresentationGroup(
                        id: groupId, repoTitle: title, organizationName: nil,
                        repos: eligibleRepositories.filter { memberRepoIds.contains($0.id) }
                    ))
                result.paneRows[groupId] = group.members.compactMap { member in
                    guard let destination = destinationsByID[member.paneID] else { return nil }
                    var row = tabPaneRow(
                        groupId: groupId, destination: destination, reposById: reposById,
                        paneFacts: paneFacts[destination.paneId], branchFacts: branchFacts,
                        snapshot: snapshot
                    )
                    row.isPinned = member.isPinned
                    if snapshot.subgroupMode == .activity && snapshot.groupingMode != .activity {
                        row.activitySubgroup = activityBucket(destination.paneId, snapshot: snapshot, facts: paneFacts)
                    }
                    return row
                }
            }
            result.sections.append(.init(kind: sectionKind, resolvedGroups: groups, loadingRepos: []))
        }
        return result
    }

    private static func organizationPaneDestinations(
        _ input: RepoExplorerOrganizationInput
    ) -> [RepoExplorerProjectedPaneDestination] {
        let associated = input.eligibleRepositories.flatMap { repo in
            repo.worktrees.flatMap { worktree in
                input.destinationsByWorktreeId[worktree.id, default: []].map {
                    RepoExplorerProjectedPaneDestination.associated($0)
                }
            }
        }
        return associated + input.unassociatedDestinations.map { .unassociated($0) }
    }

    private static func organizedRepositories(_ input: RepoExplorerOrganizationInput) -> RepoExplorerOrganizedContent {
        let snapshot = input.snapshot
        let eligibleRepositories = input.eligibleRepositories
        let loadingRepos = input.loadingRepos
        let metadataByRepoId = input.metadataByRepoId
        let checkoutColors = input.checkoutColors
        let destinationsByWorktreeId = input.destinationsByWorktreeId
        let destinationsByRepoId = input.destinationsByRepoId
        let paneFacts = input.paneFacts
        let activityByWorktreeId = destinationsByWorktreeId.compactMapValues { destinations in
            destinations.compactMap { validActivity(paneFacts[$0.paneId]?.activityAt, snapshot: snapshot) }.max()
        }
        var activitySectionByRepoId: [UUID: RepoExplorerSidebarSectionKind] = [:]
        if snapshot.groupingMode == .activity {
            let identityGroups = remoteIdentityGroups(
                repos: snapshot.repos,
                metadataByRepoId: RepoPresentationColoring.buildRepoMetadata(
                    repos: snapshot.repos, repoEnrichmentByRepoId: snapshot.repoEnrichmentSnapshotByRepoId
                ), sortOrder: .ascending
            )
            for group in identityGroups {
                let latestActivity = group.repos.flatMap(\.worktrees).compactMap { activityByWorktreeId[$0.id] }.max()
                let kind = RepoExplorerSidebarSectionKind.activitySection(
                    RepoExplorerActivityBucket.classify(
                        activityAt: latestActivity, now: snapshot.referenceDate, calendar: snapshot.calendar
                    )
                )
                for repo in group.repos { activitySectionByRepoId[repo.id] = kind }
            }
        }
        func section(for repo: RepoPresentationItem) -> RepoExplorerSidebarSectionKind {
            if snapshot.showsPinned && repo.isPinned { return .pinnedRepositories }
            if snapshot.groupingMode == .activity { return activitySectionByRepoId[repo.id] ?? .noActivityRepos }
            return destinationsByRepoId[repo.id, default: []].isEmpty ? .repositories : .openRepositories
        }
        let sectionKinds: [RepoExplorerSidebarSectionKind] =
            snapshot.groupingMode == .activity
            ? [.pinnedRepositories]
                + RepoExplorerActivityBucket.allCases.map(RepoExplorerSidebarSectionKind.activitySection)
            : [.pinnedRepositories, .openRepositories, .repositories]
        var result = RepoExplorerOrganizedContent()
        for kind in sectionKinds {
            let members = eligibleRepositories.filter { section(for: $0) == kind }
            let loading = loadingRepos.filter { section(for: $0) == kind }
            guard !members.isEmpty || !loading.isEmpty else { continue }
            let groups = remoteIdentityGroups(repos: members, metadataByRepoId: metadataByRepoId, sortOrder: .ascending)
                .map { group in
                    RepoPresentationGroup(
                        id: "repos:\(kind.rawValue):\(group.id)", repoTitle: group.repoTitle,
                        organizationName: group.organizationName, repos: group.repos
                    )
                }
            let rowsByGroup = worktreeRowsByGroupId(from: groups, checkoutColorHexByRepoId: checkoutColors)
            for (groupId, unsortedRows) in rowsByGroup {
                var rows = unsortedRows
                rows.sort { lhs, rhs in
                    RepoExplorerLeafOrdering.precedes(
                        .init(
                            name: lhs.worktree.name, activityAt: activityByWorktreeId[lhs.worktree.id],
                            identity: lhs.worktree.id),
                        .init(
                            name: rhs.worktree.name, activityAt: activityByWorktreeId[rhs.worktree.id],
                            identity: rhs.worktree.id),
                        sortField: snapshot.sortField,
                        sortOrder: snapshot.sortOrder,
                        referenceDate: snapshot.referenceDate
                    )
                }
                result.worktreeRows[groupId] = rows
            }
            result.sections.append(.init(kind: kind, resolvedGroups: groups, loadingRepos: loading))
        }
        return result
    }

    private static func activityBucket(
        _ paneId: UUID, snapshot: RepoExplorerSnapshot, facts: [UUID: RepoExplorerPaneRowFacts]
    ) -> RepoExplorerActivityBucket {
        RepoExplorerActivityBucket.classify(
            activityAt: facts[paneId]?.activityAt, now: snapshot.referenceDate, calendar: snapshot.calendar
        )
    }

    private static func validActivity(_ date: Date?, snapshot: RepoExplorerSnapshot) -> Date? {
        guard let date, date.timeIntervalSince1970.isFinite,
            snapshot.referenceDate.timeIntervalSince1970.isFinite, date <= snapshot.referenceDate
        else { return nil }
        return date
    }

}
