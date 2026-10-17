import AgentStudioCore
import AgentStudioSharedComponents
import Foundation

enum RepoExplorerProjectedPaneDestination: Equatable, Sendable {
    case associated(RepoExplorerPaneDestination)
    case unassociated(RepoExplorerUnassociatedPaneDestination)

    var paneId: UUID {
        switch self {
        case .associated(let destination): destination.paneId
        case .unassociated(let destination): destination.paneId
        }
    }

    var repoId: UUID? {
        guard case .associated(let destination) = self else { return nil }
        return destination.repoId
    }

    var worktreeId: UUID? {
        guard case .associated(let destination) = self else { return nil }
        return destination.worktreeId
    }

    var worktreeLabel: String? {
        guard case .associated(let destination) = self else { return nil }
        return destination.worktreeLabel
    }

    var tabId: UUID {
        switch self {
        case .associated(let destination): destination.tabId
        case .unassociated(let destination): destination.tabId
        }
    }

    var tabIndex: Int {
        switch self {
        case .associated(let destination): destination.tabIndex
        case .unassociated(let destination): destination.tabIndex
        }
    }

    var paneIndexInTab: Int {
        switch self {
        case .associated(let destination): destination.paneIndexInTab
        case .unassociated(let destination): destination.paneIndexInTab
        }
    }

    var isActiveInTab: Bool {
        switch self {
        case .associated(let destination): destination.isActiveInTab
        case .unassociated(let destination): destination.isActiveInTab
        }
    }

    var associatedDestination: RepoExplorerPaneDestination? {
        guard case .associated(let destination) = self else { return nil }
        return destination
    }

    func label(paneDisplayLabel: String) -> String {
        switch self {
        case .associated(let destination):
            destination.label(paneDisplayLabel: paneDisplayLabel)
        case .unassociated(let destination):
            destination.label(paneDisplayLabel: paneDisplayLabel)
        }
    }
}

enum RepoExplorerProjectedPaneMembershipOwner: Equatable, Sendable {
    case association
    case tab
}

typealias RepoExplorerDrawerRail = DrawerRailSegment

enum RepoExplorerPaneDisplayVariant: Equatable, Sendable {
    case compact
    case expanded
}

struct RepoExplorerProjectedPaneRow: Equatable, Sendable {
    let groupId: String
    let membershipOwner: RepoExplorerProjectedPaneMembershipOwner
    let destination: RepoExplorerProjectedPaneDestination
    let rowId: String
    let primaryText: String
    let secondaryLine: RepoExplorerPaneSecondaryLine?
    let branchContextText: String?
    let branchStatus: GitBranchStatus?
    let recencyText: String
    let recencyTier: RepoExplorerPaneRecencyTier
    let isActive: Bool
    let isDrawerPane: Bool
    var messageChip: PaneMessageChipModel?
    var isPinned = false
    var activitySubgroup: RepoExplorerActivityBucket?
    var variants: RepoExplorerPaneRowVariants?
    var drawerRail: RepoExplorerDrawerRail = .none
    var displayVariant: RepoExplorerPaneDisplayVariant = .compact
    var drawerOwnerPaneID: UUID?

    var secondaryText: String? { secondaryLine?.text }
    var anchorIdentity: UUID { destination.paneId }
    var repoId: UUID? { destination.repoId }
    var worktreeId: UUID? { destination.worktreeId }

    init(
        groupId: String,
        repoId: UUID,
        destination: RepoExplorerPaneDestination,
        membershipOwner: RepoExplorerProjectedPaneMembershipOwner = .association,
        rowId: String,
        primaryText: String = "",
        secondaryLine: RepoExplorerPaneSecondaryLine? = nil,
        branchContextText: String? = nil,
        branchStatus: GitBranchStatus? = nil,
        recencyText: String = "Now",
        recencyTier: RepoExplorerPaneRecencyTier = .strongBlue,
        isActive: Bool = false,
        isDrawerPane: Bool = false
    ) {
        self.groupId = groupId
        self.membershipOwner = membershipOwner
        precondition(repoId == destination.repoId)
        self.destination = .associated(destination)
        self.rowId = rowId
        self.primaryText = primaryText
        self.secondaryLine = secondaryLine
        self.branchContextText = branchContextText
        self.branchStatus = branchStatus
        self.recencyText = recencyText
        self.recencyTier = recencyTier
        self.isActive = isActive
        self.isDrawerPane = isDrawerPane
        variants = nil
    }

    init(
        groupId: String,
        destination: RepoExplorerUnassociatedPaneDestination,
        rowId: String,
        primaryText: String = "",
        secondaryLine: RepoExplorerPaneSecondaryLine? = nil,
        recencyText: String = "Now",
        recencyTier: RepoExplorerPaneRecencyTier = .strongBlue,
        isActive: Bool = false,
        isDrawerPane: Bool = false
    ) {
        self.groupId = groupId
        self.membershipOwner = .tab
        self.destination = .unassociated(destination)
        self.rowId = rowId
        self.primaryText = primaryText
        self.secondaryLine = secondaryLine
        self.branchContextText = nil
        self.branchStatus = nil
        self.recencyText = recencyText
        self.recencyTier = recencyTier
        self.isActive = isActive
        self.isDrawerPane = isDrawerPane
        variants = nil
    }
}
