import AgentStudioCore
import Foundation

struct RepoExplorerPinnedActivityMember: Sendable {
    let paneID: UUID
    let activityTime: PaneActivityTime?
    let isDrawer: Bool
    let ownerPaneID: UUID?
}

struct RepoExplorerActivityOrderedGroup {
    let key: String
    let title: String
    let paneIDs: [UUID]
    let railByPaneID: [UUID: RepoExplorerDrawerRail]
}

/// Panes has one fixed activity organization; Repos keeps its existing policy.
extension RepoExplorerProjection {
    static func organizedPanesByActivity(
        _ input: RepoExplorerOrganizationInput
    ) -> RepoExplorerOrganizedContent {
        let repositoriesByID = Dictionary(uniqueKeysWithValues: input.eligibleRepositories.map { ($0.id, $0) })
        let associated = input.eligibleRepositories.flatMap { repository in
            repository.worktrees.flatMap { worktree in
                input.destinationsByWorktreeId[worktree.id, default: []].map {
                    RepoExplorerProjectedPaneDestination.associated($0)
                }
            }
        }
        var seenPaneIDs: Set<UUID> = []
        let destinations = (associated + input.unassociatedDestinations.map { .unassociated($0) })
            .filter { seenPaneIDs.insert($0.paneId).inserted }
        let activityByPaneID = Dictionary(
            uniqueKeysWithValues: destinations.map { ($0.paneId, activity(for: $0, input: input)) }
        )
        let destinationsByID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.paneId, $0) })
        var organized = RepoExplorerOrganizedContent()

        for sectionKind in [RepoExplorerSidebarSectionKind.pinnedPanes, .panes] {
            let sectionDestinations = destinations.filter { destination in
                let isPinned = input.snapshot.showsPinned && input.paneFacts[destination.paneId]?.isPinned == true
                return isPinned == (sectionKind == .pinnedPanes)
            }
            guard !sectionDestinations.isEmpty else { continue }
            let orderedGroups: [RepoExplorerActivityOrderedGroup] =
                if sectionKind == .pinnedPanes {
                    orderedPinnedPaneGroups(
                        sectionDestinations.map { destination in
                            let facts = input.paneFacts[destination.paneId]
                            return RepoExplorerPinnedActivityMember(
                                paneID: destination.paneId,
                                activityTime: facts?.paneActivityTime,
                                isDrawer: facts?.isDrawerPane == true,
                                ownerPaneID: facts?.drawerOwnerPaneID
                            )
                        },
                        showsDrawers: input.snapshot.showsDrawerPanes,
                        referenceInstant: input.snapshot.referenceInstant,
                        wallNow: input.snapshot.referenceDate,
                        calendar: input.snapshot.calendar
                    )
                } else {
                    orderedUnpinnedPaneGroups(
                        sectionDestinations,
                        facts: input.paneFacts,
                        activityByPaneID: activityByPaneID,
                        showsDrawers: input.snapshot.showsDrawerPanes
                    )
                }
            var groups: [RepoPresentationGroup] = []
            for orderedGroup in orderedGroups {
                let groupID = "panes:\(sectionKind.rawValue):activity:\(orderedGroup.key)"
                let repositoryIDs = Set(orderedGroup.paneIDs.compactMap { destinationsByID[$0]?.repoId })
                groups.append(
                    RepoPresentationGroup(
                        id: groupID,
                        repoTitle: orderedGroup.title,
                        organizationName: nil,
                        repos: input.eligibleRepositories.filter { repositoryIDs.contains($0.id) }
                    )
                )
                organized.paneRows[groupID] = orderedGroup.paneIDs.compactMap { paneID in
                    guard let destination = destinationsByID[paneID] else { return nil }
                    var row = paneRow(
                        destination,
                        groupID: groupID,
                        repositoriesByID: repositoriesByID,
                        facts: input.paneFacts[destination.paneId],
                        branchFacts: input.branchFacts
                    )
                    row.drawerRail = orderedGroup.railByPaneID[paneID] ?? .none
                    return row
                }
            }
            if !groups.isEmpty {
                organized.sections.append(.init(kind: sectionKind, resolvedGroups: groups, loadingRepos: []))
            }
        }
        return organized
    }

    private static func activity(
        for destination: RepoExplorerProjectedPaneDestination,
        input: RepoExplorerOrganizationInput
    ) -> RepoExplorerPaneActivityProjection {
        let time = input.paneFacts[destination.paneId]?.paneActivityTime
        return RepoExplorerPaneActivityProjection.make(
            time: input.snapshot.referenceInstant == nil ? nil : time,
            referenceInstant: input.snapshot.referenceInstant ?? time?.orderingInstant ?? ContinuousClock.now,
            wallNow: input.snapshot.referenceDate,
            calendar: input.snapshot.calendar
        )
    }

    nonisolated package static func activityPrecedes(
        lhsPaneID: UUID,
        lhsTime: PaneActivityTime?,
        rhsPaneID: UUID,
        rhsTime: PaneActivityTime?
    ) -> Bool {
        let left = lhsTime?.orderingInstant
        let right = rhsTime?.orderingInstant
        if left != right {
            if let left, let right { return left > right }
            return left != nil
        }
        return lhsPaneID.uuidString < rhsPaneID.uuidString
    }

    static func orderedPinnedPaneGroups(
        _ members: [RepoExplorerPinnedActivityMember],
        showsDrawers: Bool,
        referenceInstant: ContinuousClock.Instant?,
        wallNow: Date,
        calendar: Calendar
    ) -> [RepoExplorerActivityOrderedGroup] {
        let visible = members.filter { showsDrawers || !$0.isDrawer }
        let memberByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.paneID, $0) })
        let visibleIDs = Set(memberByID.keys)
        let bucketByID = Dictionary(
            uniqueKeysWithValues: visible.map { member in
                let groupingID =
                    member.isDrawer && visibleIDs.contains(member.ownerPaneID ?? member.paneID)
                    ? member.ownerPaneID ?? member.paneID : member.paneID
                let time = memberByID[groupingID]?.activityTime
                let activity = RepoExplorerPaneActivityProjection.make(
                    time: referenceInstant == nil ? nil : time,
                    referenceInstant: referenceInstant ?? time?.orderingInstant ?? ContinuousClock.now,
                    wallNow: wallNow,
                    calendar: calendar
                )
                return (member.paneID, activity.pinnedBucket)
            })
        return RepoExplorerPinnedActivityBucket.allCases.compactMap { bucket in
            let sorted = visible.filter { bucketByID[$0.paneID] == bucket }.sorted { lhs, rhs in
                activityPrecedes(
                    lhsPaneID: lhs.paneID, lhsTime: lhs.activityTime,
                    rhsPaneID: rhs.paneID, rhsTime: rhs.activityTime
                )
            }
            guard !sorted.isEmpty else { return nil }
            let arrangement = arrangeDrawerMembers(
                sorted.map(\.paneID),
                ownerByPaneID: Dictionary(
                    uniqueKeysWithValues: sorted.compactMap { member in
                        member.isDrawer ? member.ownerPaneID.map { (member.paneID, $0) } : nil
                    })
            )
            return RepoExplorerActivityOrderedGroup(
                key: String(bucket.rawValue), title: bucket.title,
                paneIDs: arrangement.paneIDs, railByPaneID: arrangement.railByPaneID
            )
        }
    }

    private static func orderedUnpinnedPaneGroups(
        _ destinations: [RepoExplorerProjectedPaneDestination],
        facts: [UUID: RepoExplorerPaneRowFacts],
        activityByPaneID: [UUID: RepoExplorerPaneActivityProjection],
        showsDrawers: Bool
    ) -> [RepoExplorerActivityOrderedGroup] {
        let visible = destinations.filter { showsDrawers || facts[$0.paneId]?.isDrawerPane != true }
        let visibleIDs = Set(visible.map(\.paneId))
        return RepoExplorerActivityBucket.allCases.compactMap { bucket in
            let sorted = visible.filter { destination in
                let fact = facts[destination.paneId]
                let groupingID =
                    fact?.isDrawerPane == true && visibleIDs.contains(fact?.drawerOwnerPaneID ?? destination.paneId)
                    ? fact?.drawerOwnerPaneID ?? destination.paneId : destination.paneId
                return activityByPaneID[groupingID]?.unpinnedBucket == bucket
            }.sorted { lhs, rhs in
                activityPrecedes(
                    lhsPaneID: lhs.paneId, lhsTime: facts[lhs.paneId]?.paneActivityTime,
                    rhsPaneID: rhs.paneId, rhsTime: facts[rhs.paneId]?.paneActivityTime
                )
            }
            guard !sorted.isEmpty else { return nil }
            let arrangement = arrangeDrawerMembers(
                sorted.map(\.paneId),
                ownerByPaneID: Dictionary(
                    uniqueKeysWithValues: sorted.compactMap { destination in
                        let fact = facts[destination.paneId]
                        return fact?.isDrawerPane == true
                            ? fact?.drawerOwnerPaneID.map { (destination.paneId, $0) } : nil
                    })
            )
            return RepoExplorerActivityOrderedGroup(
                key: String(bucket.rawValue), title: bucket.title,
                paneIDs: arrangement.paneIDs, railByPaneID: arrangement.railByPaneID
            )
        }
    }

    private static func arrangeDrawerMembers(
        _ sortedPaneIDs: [UUID],
        ownerByPaneID: [UUID: UUID]
    ) -> (paneIDs: [UUID], railByPaneID: [UUID: RepoExplorerDrawerRail]) {
        let memberIDs = Set(sortedPaneIDs)
        let attachedDrawers = sortedPaneIDs.filter { paneID in
            ownerByPaneID[paneID].map { memberIDs.contains($0) } == true
        }
        var drawersByOwnerID: [UUID: [UUID]] = [:]
        for drawerID in attachedDrawers {
            guard let ownerID = ownerByPaneID[drawerID] else { continue }
            drawersByOwnerID[ownerID, default: []].append(drawerID)
        }
        let attachedIDs = Set(attachedDrawers)
        var arranged: [UUID] = []
        var rails: [UUID: RepoExplorerDrawerRail] = [:]
        arranged.reserveCapacity(sortedPaneIDs.count)
        for paneID in sortedPaneIDs where !attachedIDs.contains(paneID) {
            arranged.append(paneID)
            let drawers = drawersByOwnerID[paneID, default: []]
            guard !drawers.isEmpty else { continue }
            rails[paneID] = .ownerWithDrawers
            for (index, drawer) in drawers.enumerated() {
                arranged.append(drawer)
                rails[drawer] = .drawer(isLast: index == drawers.count - 1)
            }
        }
        return (arranged, rails)
    }

    private static func paneRow(
        _ destination: RepoExplorerProjectedPaneDestination,
        groupID: String,
        repositoriesByID: [UUID: RepoPresentationItem],
        facts: RepoExplorerPaneRowFacts?,
        branchFacts: RepoExplorerPaneBranchProjectionFacts
    ) -> RepoExplorerProjectedPaneRow {
        let rowID = "pane-row:\(groupID):\(destination.paneId.uuidString)"
        let title = panePrimaryText(destination, terminalTitle: facts?.sidebarTerminalTitle, showsPaneNumber: false)
        let row: RepoExplorerProjectedPaneRow
        switch destination {
        case .associated(let associated):
            let branchText = normalizedBranchName(branchFacts.namesByWorktreeId[associated.worktreeId])
                .map { branchName in
                    let repositoryName = repositoriesByID[associated.repoId]?.name ?? "Repository"
                    return "\(repositoryName) · \(branchName)"
                }
            row = RepoExplorerProjectedPaneRow(
                groupId: groupID,
                repoId: associated.repoId,
                destination: associated,
                membershipOwner: .tab,
                rowId: rowID,
                primaryText: title,
                secondaryLine: facts?.secondaryLine,
                branchContextText: branchText,
                branchStatus: branchFacts.statusesByWorktreeId[associated.worktreeId],
                recencyText: facts?.recencyText ?? "—",
                recencyTier: facts?.recencyTier ?? .grey,
                isActive: facts?.isActive ?? false,
                isDrawerPane: facts?.isDrawerPane ?? false
            )
        case .unassociated(let unassociated):
            row = RepoExplorerProjectedPaneRow(
                groupId: groupID,
                destination: unassociated,
                rowId: rowID,
                primaryText: title,
                secondaryLine: facts?.secondaryLine,
                recencyText: facts?.recencyText ?? "—",
                recencyTier: facts?.recencyTier ?? .grey,
                isActive: facts?.isActive ?? false,
                isDrawerPane: facts?.isDrawerPane ?? false
            )
        }
        var pinnedRow = row
        pinnedRow.messageChip = facts?.contextDisplay.map {
            RepoExplorerPaneMessageCountProjection.make(display: $0, isDrawer: row.isDrawerPane)
        }
        pinnedRow.isPinned = facts?.isPinned ?? false
        pinnedRow.drawerOwnerPaneID = facts?.drawerOwnerPaneID
        let note: String? =
            if case .note(let text)? = facts?.secondaryLine { text } else { nil }
        pinnedRow.variants = RepoExplorerPaneRowVariants.make(
            title: title,
            branchContext: row.branchContextText,
            note: note,
            isDrawer: row.isDrawerPane,
            branchStatus: row.branchStatus,
            isActive: row.isActive,
            agentLine: facts?.contextDisplay?.agentLine,
            sessionStatus: facts?.sessionStatus,
            messageCount: pinnedRow.messageChip?.count ?? 0
        )
        return pinnedRow
    }
}
