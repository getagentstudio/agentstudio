import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@testable import AgentStudioRepoExplorer

enum RepoExplorerNavigationTestRow {
    case section(RepoExplorerSidebarSectionKind)
    case loadingSection(RepoExplorerSidebarSectionKind)
    case loadingRepository(section: RepoExplorerSidebarSectionKind, repositoryID: UUID)
    case activity(groupID: String, bucket: RepoExplorerActivityBucket)
    case group(id: String, expanded: Bool)
    case worktree(groupID: String, repositoryID: UUID, worktreeID: UUID)
    case associatedPane(RepoExplorerNavigationAssociatedPaneTestRow)
    case tabPane(groupID: String, paneID: UUID, tabID: UUID)
    case unassociatedPane(paneID: UUID, tabID: UUID)
    case topologyFault
    case unresolved(rowID: RepoExplorerRowID)
}

struct RepoExplorerNavigationAssociatedPaneTestRow {
    let groupID: String
    let repositoryID: UUID
    let worktreeID: UUID
    let paneID: UUID
    let tabID: UUID
}

func navigationSnapshot(
    _ testRows: [RepoExplorerNavigationTestRow]
) -> RepoExplorerMaterializationSnapshot {
    RepoExplorerMaterializationSnapshot(rows: testRows.map(navigationMaterializedRow))
}

func navigationMaterializedRow(
    _ testRow: RepoExplorerNavigationTestRow
) -> RepoExplorerMaterializedRow {
    switch testRow {
    case .section(let section):
        return navigationMaterializedRow(
            id: .sectionHeader(section),
            presentation: .sectionHeader(kind: section, isFirstRow: false)
        )
    case .loadingSection(let section):
        return navigationMaterializedRow(
            id: .loadingSectionHeader(section),
            presentation: .loadingSectionHeader(kind: section, state: .scanning)
        )
    case .loadingRepository(let section, let repositoryID):
        return navigationMaterializedRow(
            id: .loadingRepository(section: section, repoID: repositoryID),
            presentation: .loadingRepository(
                section: section,
                repoID: repositoryID,
                name: "Loading repository",
                isStatusUnavailable: false
            ),
            representedRepositoryID: repositoryID
        )
    case .activity(let groupID, let bucket):
        return navigationMaterializedRow(
            id: .activitySubgroup(groupID: groupID, bucket: bucket),
            presentation: .activitySubgroup(bucket, isFirstInGroup: true)
        )
    case .group(let groupID, let expanded):
        return navigationGroupRow(groupID: groupID, expanded: expanded)
    case .worktree(let groupID, let repositoryID, let worktreeID):
        return navigationWorktreeRow(
            groupID: groupID,
            repositoryID: repositoryID,
            worktreeID: worktreeID
        )
    case .associatedPane(let pane):
        return navigationAssociatedPaneRow(pane)
    case .tabPane(let groupID, let paneID, let tabID):
        return navigationTabPaneRow(groupID: groupID, paneID: paneID, tabID: tabID)
    case .unassociatedPane(let paneID, let tabID):
        return navigationUnassociatedPaneRow(paneID: paneID, tabID: tabID)
    case .topologyFault:
        return navigationMaterializedRow(
            id: .topologyFault,
            presentation: .topologyFault(.duplicateWorktreeIdentities([]))
        )
    case .unresolved(let unresolvedRowID):
        return navigationMaterializedRow(
            id: unresolvedRowID,
            presentation: .unresolved(unresolvedRowID)
        )
    }
}

func navigationGroupRow(
    groupID: String,
    expanded: Bool
) -> RepoExplorerMaterializedRow {
    navigationMaterializedRow(
        id: .group(groupID: groupID),
        presentation: .groupHeader(
            RepoExplorerMaterializedGroupHeaderPresentation(
                groupID: groupID,
                icon: .repo,
                title: groupID,
                organizationName: nil,
                colorHex: nil,
                isExpanded: expanded,
                repoIDs: [],
                semanticRepoPath: nil,
                paneDestinations: []
            )
        )
    )
}

func navigationWorktreeRow(
    groupID: String,
    repositoryID: UUID,
    worktreeID: UUID
) -> RepoExplorerMaterializedRow {
    let rowID = RepoExplorerRowID.worktree(
        groupID: groupID,
        repoID: repositoryID,
        worktreeID: worktreeID
    )
    let worktree = Worktree(
        id: worktreeID,
        repoId: repositoryID,
        name: "main",
        path: URL(filePath: "/tmp/navigation-index-worktree"),
        isMainWorktree: true
    )
    let repository = RepoPresentationItem(
        id: repositoryID,
        name: "navigation-index",
        repoPath: worktree.path,
        stableKey: "navigation-index",
        worktrees: [worktree]
    )
    return navigationMaterializedRow(
        id: rowID,
        presentation: .worktree(
            RepoExplorerMaterializedWorktreePresentation(
                rowID: rowID,
                groupID: groupID,
                repo: repository,
                worktree: worktree,
                checkoutTitle: "navigation-index",
                isMainCheckout: true,
                checkoutColorHex: "#F5C451",
                placementText: "",
                branchStatus: .unknown,
                branchName: "main",
                bridgeCommandResolution: .create,
                paneDestinations: []
            )
        ),
        representedRepositoryID: repositoryID,
        representedWorktreeID: worktreeID
    )
}

func navigationAssociatedPaneRow(
    _ pane: RepoExplorerNavigationAssociatedPaneTestRow
) -> RepoExplorerMaterializedRow {
    let rowID = RepoExplorerRowID.associatedPane(
        groupID: pane.groupID,
        repoID: pane.repositoryID,
        worktreeID: pane.worktreeID,
        paneID: pane.paneID
    )
    return navigationMaterializedRow(
        id: rowID,
        presentation: .pane(
            RepoExplorerProjectedPaneRow(
                groupId: pane.groupID,
                repoId: pane.repositoryID,
                destination: RepoExplorerPaneDestination(
                    paneId: pane.paneID,
                    repoId: pane.repositoryID,
                    worktreeId: pane.worktreeID,
                    worktreeLabel: "main",
                    tabId: pane.tabID,
                    tabIndex: 0,
                    paneIndexInTab: 0,
                    isActiveInTab: true
                ),
                rowId: "associated:\(pane.paneID.uuidString)"
            )
        ),
        representedRepositoryID: pane.repositoryID,
        representedWorktreeID: pane.worktreeID
    )
}

func navigationTabPaneRow(
    groupID: String,
    paneID: UUID,
    tabID: UUID
) -> RepoExplorerMaterializedRow {
    navigationMaterializedRow(
        id: .tabPane(groupID: groupID, paneID: paneID),
        presentation: .pane(
            RepoExplorerProjectedPaneRow(
                groupId: groupID,
                destination: navigationUnassociatedDestination(paneID: paneID, tabID: tabID),
                rowId: "tab:\(paneID.uuidString)"
            )
        )
    )
}

func navigationDrawerPaneRow(
    groupID: String,
    paneID: UUID,
    tabID: UUID,
    ownerPaneID: UUID
) -> RepoExplorerMaterializedRow {
    var pane = RepoExplorerProjectedPaneRow(
        groupId: groupID,
        destination: navigationUnassociatedDestination(paneID: paneID, tabID: tabID),
        rowId: "drawer:\(paneID.uuidString)",
        isDrawerPane: true
    )
    pane.drawerOwnerPaneID = ownerPaneID
    return navigationMaterializedRow(
        id: .tabPane(groupID: groupID, paneID: paneID),
        presentation: .pane(pane)
    )
}

func navigationUnassociatedPaneRow(
    paneID: UUID,
    tabID: UUID
) -> RepoExplorerMaterializedRow {
    let destination = navigationUnassociatedDestination(paneID: paneID, tabID: tabID)
    return navigationMaterializedRow(
        id: .unassociatedPane(paneID: paneID),
        presentation: .unassociatedPane(
            RepoExplorerUnassociatedPanePresentation(
                variant: RepoExplorerPaneRowVariants.make(
                    title: "Unassociated pane", isActive: true, recencyText: "Now", recencyTier: .strongBlue,
                    activityDate: Date(timeIntervalSince1970: 0),
                    now: Date(timeIntervalSince1970: 0)
                ).compact,
                destination: destination,
                primaryText: "Unassociated pane",
                secondaryLine: nil,
                recencyText: "Now",
                recencyTier: .strongBlue,
                isActive: true,
                isDrawerPane: false
            )
        )
    )
}

func navigationRichPaneRow(
    paneID: UUID,
    tabID: UUID
) -> RepoExplorerMaterializedRow {
    let repositoryID = UUIDv7.generate()
    let worktreeID = UUIDv7.generate()
    let rowID = RepoExplorerRowID.associatedPane(
        groupID: "rich-pane-group",
        repoID: repositoryID,
        worktreeID: worktreeID,
        paneID: paneID
    )
    let destination = RepoExplorerPaneDestination(
        paneId: paneID,
        repoId: repositoryID,
        worktreeId: worktreeID,
        worktreeLabel: "main",
        tabId: tabID,
        tabIndex: 0,
        paneIndexInTab: 0,
        isActiveInTab: true
    )
    var presentation = RepoExplorerProjectedPaneRow(
        groupId: "rich-pane-group",
        repoId: repositoryID,
        destination: destination,
        rowId: "associated:\(paneID.uuidString)",
        primaryText: "Previewable pane title",
        secondaryLine: .note("Review output"),
        branchContextText: "agent-studio · feature/sidebar",
        branchStatus: GitBranchStatus(
            isDirty: true,
            syncState: .ahead(2),
            prCount: 3,
            linesAdded: 12,
            linesDeleted: 4,
            untrackedFileCount: 1
        ),
        recencyText: "Now",
        recencyTier: .strongBlue,
        isActive: true,
        isDrawerPane: true
    )
    presentation.variants = .make(
        title: presentation.primaryText, branchContext: presentation.branchContextText,
        note: presentation.secondaryLine?.text, isDrawer: presentation.isDrawerPane,
        branchStatus: presentation.branchStatus, isActive: presentation.isActive,
        recencyText: presentation.recencyText, recencyTier: presentation.recencyTier,
        activityDate: Date(timeIntervalSince1970: 0),
        now: Date(timeIntervalSince1970: 0))
    return navigationMaterializedRow(
        id: rowID,
        presentation: .pane(presentation),
        representedRepositoryID: repositoryID,
        representedWorktreeID: worktreeID
    )
}

func navigationUnassociatedDestination(
    paneID: UUID,
    tabID: UUID
) -> RepoExplorerUnassociatedPaneDestination {
    RepoExplorerUnassociatedPaneDestination(
        paneId: paneID,
        tabId: tabID,
        tabIndex: 0,
        paneIndexInTab: 0,
        isActiveInTab: true
    )
}

func navigationMaterializedRow(
    id: RepoExplorerRowID,
    presentation: RepoExplorerMaterializedRowPresentation,
    representedRepositoryID: UUID? = nil,
    representedWorktreeID: UUID? = nil
) -> RepoExplorerMaterializedRow {
    RepoExplorerMaterializedRow(
        id: id,
        contentRevision: RepoExplorerRowContentRevision(presentation: presentation),
        layout: RepoExplorerRowLayout.make(for: presentation),
        representedRepoID: representedRepositoryID,
        representedWorktreeID: representedWorktreeID
    )
}
