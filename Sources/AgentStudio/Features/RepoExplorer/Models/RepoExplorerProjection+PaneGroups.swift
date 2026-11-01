import AgentStudioCore
import Foundation

struct RepoExplorerPaneBranchProjectionFacts {
    let namesByWorktreeId: [UUID: String]
    let statusesByWorktreeId: [UUID: GitBranchStatus]
}

extension RepoExplorerProjection {
    static func degradedProjectionIfTopologyFault(
        in repos: [RepoPresentationItem]
    ) -> RepoExplorerSidebarProjection? {
        var detector = RepoExplorerTopologyFaultDetector()
        for repo in repos {
            detector.observe(repo)
        }
        return detector.fault.map(RepoExplorerSidebarProjection.degraded)
    }

    static func tabPaneRow(
        groupId: String,
        destination: RepoExplorerProjectedPaneDestination,
        reposById: [UUID: RepoPresentationItem],
        paneFacts: RepoExplorerPaneRowFacts?,
        branchFacts: RepoExplorerPaneBranchProjectionFacts,
        snapshot: RepoExplorerSnapshot
    ) -> RepoExplorerProjectedPaneRow {
        var row: RepoExplorerProjectedPaneRow
        switch destination {
        case .associated(let associatedDestination):
            row = RepoExplorerProjectedPaneRow(
                groupId: groupId,
                repoId: associatedDestination.repoId,
                destination: associatedDestination,
                membershipOwner: .tab,
                rowId: "pane-row:\(groupId):\(destination.paneId.uuidString)",
                primaryText: panePrimaryText(
                    destination, terminalTitle: paneFacts?.sidebarTerminalTitle,
                    showsPaneNumber: snapshot.groupingMode == .tab),
                secondaryLine: paneFacts?.secondaryLine ?? .terminalOutput(paneFacts?.sidebarTerminalTitle ?? "zsh"),
                branchContextText: normalizedBranchName(
                    branchFacts.namesByWorktreeId[associatedDestination.worktreeId]
                ).map { branchName in
                    let repoName = reposById[associatedDestination.repoId]?.name ?? "Repository"
                    return "\(repoName) · \(branchName)"
                },
                branchStatus: branchFacts.statusesByWorktreeId[associatedDestination.worktreeId],
                recencyText: paneFacts?.recencyText ?? "Now",
                recencyTier: paneFacts?.recencyTier ?? .strongBlue,
                isActive: paneFacts?.isActive ?? false,
                isDrawerPane: paneFacts?.isDrawerPane ?? false
            )
        case .unassociated(let unassociatedDestination):
            row = RepoExplorerProjectedPaneRow(
                groupId: groupId,
                destination: unassociatedDestination,
                rowId: "pane-row:\(groupId):\(destination.paneId.uuidString)",
                primaryText: panePrimaryText(
                    destination, terminalTitle: paneFacts?.sidebarTerminalTitle,
                    showsPaneNumber: snapshot.groupingMode == .tab),
                secondaryLine: paneFacts?.secondaryLine ?? .terminalOutput(paneFacts?.sidebarTerminalTitle ?? "zsh"),
                recencyText: paneFacts?.recencyText ?? "Now",
                recencyTier: paneFacts?.recencyTier ?? .strongBlue,
                isActive: paneFacts?.isActive ?? false,
                isDrawerPane: paneFacts?.isDrawerPane ?? false
            )
        }
        row.variants = RepoExplorerPaneRowVariants.make(
            title: row.primaryText, branchContext: row.branchContextText, note: paneFacts?.secondaryLine?.text,
            isDrawer: row.isDrawerPane, branchStatus: row.branchStatus, isActive: row.isActive,
            recencyText: row.recencyText, recencyTier: row.recencyTier,
            agentLine: paneFacts?.contextDisplay?.agentLine, sessionPresentation: paneFacts?.sessionPresentation,
            counts: (row.isDrawerPane ? paneFacts?.contextDisplay?.own : paneFacts?.contextDisplay?.includingDrawers)?
                .kinds ?? .zero,
            activityDate: paneFacts?.activityAt, now: snapshot.referenceDate)
        return row
    }
}
