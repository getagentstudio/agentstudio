import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

struct RepoExplorerPerformanceProofPresentationSummary: Equatable, Sendable {
    let inactiveRepositoryHeaderCount: Int
    let suppressedRepositoryFactRowCount: Int
    let updatingRepositoryHeaderCount: Int
}

struct RepoExplorerMaterializedGroupHeaderPresentation: Equatable, Sendable {
    let groupID: String
    let icon: AppEntityIcon
    let title: String
    let organizationName: String?
    let colorHex: String?
    let isExpanded: Bool
    let repoIDs: [UUID]
    let semanticRepoPath: URL?
    let paneDestinations: [RepoExplorerPaneDestination]
    var presentsRepositoryActivity = false
    var repositoryActivityDisposition: RepositoryActivityDisposition = .unclassified
    var repositoryFactUpdateProgress: RepositoryFactUpdateProgress?
}

struct RepoExplorerMaterializedWorktreePresentation: Equatable, Sendable {
    let rowID: RepoExplorerRowID
    let groupID: String
    let repo: RepoPresentationItem
    let worktree: Worktree
    let checkoutTitle: String
    let isMainCheckout: Bool
    let checkoutColorHex: String
    let placementText: String
    let branchStatus: GitBranchStatus
    let branchName: String
    let bridgeCommandResolution: BridgePaneCommandResolution
    let paneDestinations: [RepoExplorerPaneDestination]
    var showsRepositoryFactStatus = true

    /// Equality covers only values consumed by the materialized row. The full
    /// source models are retained for rendering actions, but dormant metadata
    /// must not turn into a native table update.
    static func == (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.rowID == rhs.rowID
            && lhs.groupID == rhs.groupID
            && lhs.repo.id == rhs.repo.id
            && lhs.worktree.id == rhs.worktree.id
            && lhs.worktree.path == rhs.worktree.path
            && lhs.worktree.isMainWorktree == rhs.worktree.isMainWorktree
            && lhs.checkoutTitle == rhs.checkoutTitle
            && lhs.isMainCheckout == rhs.isMainCheckout
            && lhs.checkoutColorHex == rhs.checkoutColorHex
            && lhs.placementText == rhs.placementText
            && lhs.branchStatus == rhs.branchStatus
            && lhs.branchName == rhs.branchName
            && lhs.bridgeCommandResolution == rhs.bridgeCommandResolution
            && lhs.paneDestinations == rhs.paneDestinations
            && lhs.showsRepositoryFactStatus == rhs.showsRepositoryFactStatus
    }
}

struct RepoExplorerUnassociatedPanePresentation: Equatable, Sendable {
    var variant: RepoExplorerPaneRowVariant = .init(lines: [])
    let destination: RepoExplorerUnassociatedPaneDestination
    let primaryText: String
    let secondaryLine: RepoExplorerPaneSecondaryLine?
    let recencyText: String
    let recencyTier: RepoExplorerPaneRecencyTier
    let isActive: Bool
    let isDrawerPane: Bool
}

enum RepoExplorerMaterializedRowPresentation: Equatable, Sendable {
    case activitySubgroup(RepoExplorerActivityBucket, isFirstInGroup: Bool)
    case sectionHeader(kind: RepoExplorerSidebarSectionKind, isFirstRow: Bool)
    case loadingSectionHeader(
        kind: RepoExplorerSidebarSectionKind,
        state: RepoExplorerLoadingSectionState
    )
    case loadingRepository(
        section: RepoExplorerSidebarSectionKind,
        repoID: UUID,
        name: String,
        isStatusUnavailable: Bool
    )
    case groupHeader(RepoExplorerMaterializedGroupHeaderPresentation)
    case worktree(RepoExplorerMaterializedWorktreePresentation)
    case pane(RepoExplorerProjectedPaneRow)
    case unassociatedPane(RepoExplorerUnassociatedPanePresentation)
    case topologyFault(RepoExplorerTopologyFault)
    case unresolved(RepoExplorerRowID)
}

struct RepoExplorerRowContentRevision: Equatable, Sendable {
    let presentation: RepoExplorerMaterializedRowPresentation
}

enum RepoExplorerWorktreeStatusPresentation {
    static func showsPendingIndicator(_ branchStatus: GitBranchStatus) -> Bool {
        branchStatus.pullRequestIsLoading && !branchStatus.pullRequestDataUnavailable
    }

    static func reservesStatusLine(_ branchStatus: GitBranchStatus) -> Bool {
        branchStatus.pullRequestIsLoading && branchStatus.prCount == nil
            && !branchStatus.pullRequestDataUnavailable
            || (branchStatus.prCount ?? 0) > 0 && !branchStatus.pullRequestDataUnavailable
            || SidebarGitStatusChips.diffDetail(branchStatus: branchStatus) != nil
            || SidebarGitStatusChips.showsSync(branchStatus: branchStatus)
    }

    static func showsPendingIndicatorInMetadataLine(_ branchStatus: GitBranchStatus) -> Bool {
        showsPendingIndicator(branchStatus) && !reservesStatusLine(branchStatus)
    }
}

enum RepoExplorerRowLayoutClass: Equatable, Sendable {
    case sectionHeader
    case loadingSectionHeader
    case loadingRepository
    case groupHeader
    case worktree
    case pane
    case fault
}

struct RepoExplorerRowLayoutMetrics: Equatable, Sendable {
    let primaryLineHeight: CGFloat
    let metadataLineHeight: CGFloat
    let chipLineHeight: CGFloat
    let contentSpacing: CGFloat
    let verticalInset: CGFloat
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let minimumHeight: CGFloat
    let fallbackHeight: CGFloat
}

struct RepoExplorerRowLayout: Equatable, Sendable {
    let rowClass: RepoExplorerRowLayoutClass
    let metrics: RepoExplorerRowLayoutMetrics
    let requiresVisibleWidthMeasurement: Bool

    private struct Facts {
        let rowClass: RepoExplorerRowLayoutClass
        let primaryLineHeight: CGFloat
        var leadingInset: CGFloat = 0
        var trailingInset: CGFloat = 0
        var metadataLineHeight = AppStyles.Shell.Sidebar.nativeMetadataTextLineHeight
        var metadataLineCount: CGFloat = 0
        var chipLineCount: CGFloat = 0
        var verticalInset: CGFloat = 0
        var additionalVerticalPadding: CGFloat = 0
        var requiresVisibleWidthMeasurement = false
    }

    static func make(for presentation: RepoExplorerMaterializedRowPresentation) -> Self {
        let facts = facts(for: presentation)
        return Self(
            rowClass: facts.rowClass,
            metrics: metrics(facts),
            requiresVisibleWidthMeasurement: facts.requiresVisibleWidthMeasurement
        )
    }

    private static func facts(for presentation: RepoExplorerMaterializedRowPresentation) -> Facts {
        switch presentation {
        case .activitySubgroup(_, let isFirstInGroup):
            return activitySubgroupFacts(isFirstInGroup: isFirstInGroup)
        case .sectionHeader(_, let isFirstRow):
            var facts = Facts(
                rowClass: .sectionHeader,
                primaryLineHeight: AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
            )
            facts.additionalVerticalPadding =
                (isFirstRow ? 0 : AppStyles.Components.SectionSubheading.topPadding)
                + AppStyles.Shell.Sidebar.nativeSectionHeaderBottomPadding
            return facts
        case .loadingSectionHeader:
            var facts = Facts(
                rowClass: .loadingSectionHeader,
                primaryLineHeight: AppStyles.Shell.Sidebar.nativeLoadingSectionContentHeight
            )
            facts.metadataLineHeight = AppStyles.Shell.Sidebar.nativeLoadingCaptionLineHeight
            facts.additionalVerticalPadding =
                AppStyles.General.Spacing.standard + AppStyles.General.Spacing.tight
            return facts
        case .loadingRepository(_, _, _, let isStatusUnavailable):
            var facts = Facts(
                rowClass: .loadingRepository,
                primaryLineHeight: AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
            )
            facts.leadingInset = AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
            facts.trailingInset = AppStyles.General.Spacing.loose
            facts.metadataLineHeight = AppStyles.Shell.Sidebar.nativeLoadingCaptionLineHeight
            facts.metadataLineCount = isStatusUnavailable ? 1 : 0
            facts.verticalInset = AppStyles.Shell.Sidebar.nativeRowVerticalInset
            return facts
        case .groupHeader:
            var facts = Facts(
                rowClass: .groupHeader,
                primaryLineHeight: AppStyles.Shell.Sidebar.nativeGroupTitleLineHeight
            )
            facts.verticalInset = AppStyles.Shell.Sidebar.groupRowVerticalPadding
            facts.additionalVerticalPadding =
                AppStyles.Shell.Sidebar.nativeGroupHeaderTopPadding
                + AppStyles.Shell.Sidebar.nativeGroupHeaderBottomPadding
            return facts
        case .worktree(let worktree):
            var facts = Facts(
                rowClass: .worktree,
                primaryLineHeight:
                    worktree.isMainCheckout
                    ? AppStyles.Shell.Sidebar.nativeInlineControlLineHeight
                    : AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
            )
            facts.leadingInset = AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
            facts.metadataLineCount =
                (worktree.branchName.isEmpty ? 0 : 1)
                + (worktree.placementText.isEmpty ? 0 : 1)
            facts.chipLineCount =
                RepoExplorerWorktreeStatusPresentation.reservesStatusLine(
                    worktree.branchStatus
                ) ? 1 : 0
            facts.verticalInset = AppStyles.Shell.Sidebar.nativeRowVerticalInset
            return facts
        case .pane(let pane):
            var facts = Facts(
                rowClass: .pane,
                primaryLineHeight: AppStyles.Shell.Sidebar.nativeInlineControlLineHeight
            )
            facts.leadingInset = AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
            let displayedVariant =
                pane.displayVariant == .expanded
                ? pane.variants?.expanded : pane.variants?.compact
            facts.metadataLineCount =
                displayedVariant.map { CGFloat(max(0, $0.lines.count - 1)) }
                ?? (pane.secondaryLine == nil ? 0 : 1) + (pane.branchContextText == nil ? 0 : 1)
            facts.chipLineCount = displayedVariant?.showsChipLine == true ? 1 : 0
            facts.verticalInset = AppStyles.Shell.Sidebar.nativeRowVerticalInset
            return facts
        case .unassociatedPane(let pane):
            var facts = Facts(
                rowClass: .pane,
                primaryLineHeight: AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
            )
            facts.leadingInset = AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
            facts.metadataLineCount = CGFloat(max(0, pane.variant.lines.count - 1))
            facts.chipLineCount = pane.variant.showsChipLine ? 1 : 0
            facts.verticalInset = AppStyles.Shell.Sidebar.nativeRowVerticalInset
            return facts
        case .topologyFault, .unresolved:
            var facts = Facts(
                rowClass: .fault,
                primaryLineHeight: AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
            )
            facts.leadingInset = AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
            facts.trailingInset = AppStyles.General.Spacing.standard
            facts.metadataLineCount = 2
            facts.verticalInset = AppStyles.Shell.Sidebar.nativeRowVerticalInset
            facts.requiresVisibleWidthMeasurement = true
            return facts
        }
    }

    private static func activitySubgroupFacts(isFirstInGroup: Bool) -> Facts {
        var facts = Facts(
            rowClass: .sectionHeader, primaryLineHeight: AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight)
        facts.leadingInset =
            AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
            + AppStyles.Shell.Sidebar.rowHorizontalInset
        facts.additionalVerticalPadding =
            (isFirstInGroup
                ? AppStyles.Shell.Sidebar.nativeFirstSubgroupTopPadding
                : AppStyles.Shell.Sidebar.nativeSubsequentSubgroupTopPadding)
            + AppStyles.Shell.Sidebar.nativeSubgroupBottomPadding
        return facts
    }

    private static func metrics(_ facts: Facts) -> RepoExplorerRowLayoutMetrics {
        let chipLineHeight = AppStyles.Shell.Sidebar.chipLineHeight
        let contentSpacing = AppStyles.Shell.Sidebar.rowContentSpacing
        let fallbackChildSpacingCount = facts.metadataLineCount + facts.chipLineCount
        let fallbackHeight =
            facts.primaryLineHeight
            + facts.metadataLineHeight * facts.metadataLineCount
            + chipLineHeight * facts.chipLineCount
            + contentSpacing * fallbackChildSpacingCount
            + facts.verticalInset * 2
            + facts.additionalVerticalPadding

        return RepoExplorerRowLayoutMetrics(
            primaryLineHeight: facts.primaryLineHeight,
            metadataLineHeight: facts.metadataLineHeight,
            chipLineHeight: chipLineHeight,
            contentSpacing: contentSpacing,
            verticalInset: facts.verticalInset,
            leadingInset: facts.leadingInset,
            trailingInset: facts.trailingInset,
            minimumHeight: fallbackHeight,
            fallbackHeight: fallbackHeight
        )
    }
}

struct RepoExplorerMaterializedRow: Equatable, Sendable {
    let id: RepoExplorerRowID
    let contentRevision: RepoExplorerRowContentRevision
    let layout: RepoExplorerRowLayout
    let representedRepoID: UUID?
    let representedWorktreeID: UUID?
    let expandedPaneLayout: RepoExplorerRowLayout?

    init(
        id: RepoExplorerRowID,
        contentRevision: RepoExplorerRowContentRevision,
        layout: RepoExplorerRowLayout,
        representedRepoID: UUID?,
        representedWorktreeID: UUID?,
        expandedPaneLayout: RepoExplorerRowLayout? = nil
    ) {
        self.id = id
        self.contentRevision = contentRevision
        self.layout = layout
        self.representedRepoID = representedRepoID
        self.representedWorktreeID = representedWorktreeID
        self.expandedPaneLayout = expandedPaneLayout
    }

    var presentation: RepoExplorerMaterializedRowPresentation {
        contentRevision.presentation
    }

    func displayingPaneVariant(_ variant: RepoExplorerPaneDisplayVariant) -> Self {
        guard case .pane(var pane) = presentation, pane.variants != nil else { return self }
        pane.displayVariant = variant
        let displayedPresentation = RepoExplorerMaterializedRowPresentation.pane(pane)
        return Self(
            id: id,
            contentRevision: RepoExplorerRowContentRevision(presentation: displayedPresentation),
            layout: expandedPaneLayout ?? layout,
            representedRepoID: representedRepoID,
            representedWorktreeID: representedWorktreeID,
            expandedPaneLayout: expandedPaneLayout
        )
    }
}

struct RepoExplorerMaterializationInputs: Sendable {
    let snapshot: RepoExplorerSnapshot
    let projection: RepoExplorerSidebarProjection
    let branchStatusByWorktreeID: [UUID: GitBranchStatus]
    let branchNameByWorktreeID: [UUID: String]
    let bridgeCommandResolutionByWorktreeID: [UUID: BridgePaneCommandResolution]
    let paneRowFactsByPaneID: [UUID: RepoExplorerPaneRowFacts]
    let repositoryActivityDispositionByRepoID: [UUID: RepositoryActivityDisposition]
    let repositoryFactUpdateProgressByRepoID: [UUID: RepositoryFactUpdateProgress]

    init(
        snapshot: RepoExplorerSnapshot,
        projection: RepoExplorerSidebarProjection,
        branchStatusByWorktreeID: [UUID: GitBranchStatus],
        branchNameByWorktreeID: [UUID: String],
        bridgeCommandResolutionByWorktreeID: [UUID: BridgePaneCommandResolution],
        paneRowFactsByPaneID: [UUID: RepoExplorerPaneRowFacts],
        repositoryActivityDispositionByRepoID: [UUID: RepositoryActivityDisposition] = [:],
        repositoryFactUpdateProgressByRepoID: [UUID: RepositoryFactUpdateProgress] = [:]
    ) {
        self.snapshot = snapshot
        self.projection = projection
        self.branchStatusByWorktreeID = branchStatusByWorktreeID
        self.branchNameByWorktreeID = branchNameByWorktreeID
        self.bridgeCommandResolutionByWorktreeID = bridgeCommandResolutionByWorktreeID
        self.paneRowFactsByPaneID = paneRowFactsByPaneID
        self.repositoryActivityDispositionByRepoID = repositoryActivityDispositionByRepoID
        self.repositoryFactUpdateProgressByRepoID = repositoryFactUpdateProgressByRepoID
    }
}

struct RepoExplorerMaterializationSnapshot: Equatable, Sendable {
    let rows: [RepoExplorerMaterializedRow]
    let navigationIndex: RepoExplorerNavigationIndex
    let fallbackContentHeight: CGFloat
    let rowIndexByID: [RepoExplorerRowID: Int]
    let rowIDsByWorktreeID: [UUID: [RepoExplorerRowID]]
    let rowIDsByPaneID: [UUID: [RepoExplorerRowID]]
    let rowIDsByRepoID: [UUID: [RepoExplorerRowID]]
    let performanceProofPresentationSummary: RepoExplorerPerformanceProofPresentationSummary

    static let empty = Self(rows: [])

    init(rows: [RepoExplorerMaterializedRow]) {
        var rowIndexByID: [RepoExplorerRowID: Int] = [:]
        var rowIDsByWorktreeID: [UUID: [RepoExplorerRowID]] = [:]
        var rowIDsByPaneID: [UUID: [RepoExplorerRowID]] = [:]
        var rowIDsByRepoID: [UUID: [RepoExplorerRowID]] = [:]
        var inactiveRepositoryHeaderCount = 0
        var suppressedRepositoryFactRowCount = 0
        var updatingRepositoryHeaderCount = 0
        rowIndexByID.reserveCapacity(rows.count)

        for (index, row) in rows.enumerated() {
            precondition(rowIndexByID.updateValue(index, forKey: row.id) == nil)
            if case .pane(let pane) = row.presentation {
                rowIDsByPaneID[pane.destination.paneId, default: []].append(row.id)
            }
            if let worktreeID = row.representedWorktreeID {
                rowIDsByWorktreeID[worktreeID, default: []].append(row.id)
            }
            if let repoID = row.representedRepoID {
                rowIDsByRepoID[repoID, default: []].append(row.id)
            }
            if case .groupHeader(let group) = row.presentation {
                for repoID in group.repoIDs {
                    rowIDsByRepoID[repoID, default: []].append(row.id)
                }
                if group.presentsRepositoryActivity,
                    group.repositoryActivityDisposition == .locallyInactive
                {
                    inactiveRepositoryHeaderCount += 1
                }
                if group.repositoryFactUpdateProgress?.isLoading == true {
                    updatingRepositoryHeaderCount += 1
                }
            }
            if case .worktree(let worktree) = row.presentation,
                !worktree.showsRepositoryFactStatus
            {
                suppressedRepositoryFactRowCount += 1
            }
        }

        self.rows = rows
        navigationIndex = RepoExplorerNavigationIndex(rows: rows)
        fallbackContentHeight = rows.reduce(into: 0) { totalHeight, row in
            totalHeight += row.layout.metrics.fallbackHeight
        }
        self.rowIndexByID = rowIndexByID
        self.rowIDsByWorktreeID = rowIDsByWorktreeID
        self.rowIDsByPaneID = rowIDsByPaneID
        self.rowIDsByRepoID = rowIDsByRepoID
        performanceProofPresentationSummary = RepoExplorerPerformanceProofPresentationSummary(
            inactiveRepositoryHeaderCount: inactiveRepositoryHeaderCount,
            suppressedRepositoryFactRowCount: suppressedRepositoryFactRowCount,
            updatingRepositoryHeaderCount: updatingRepositoryHeaderCount
        )
    }

    func row(id: RepoExplorerRowID) -> RepoExplorerMaterializedRow? {
        rowIndexByID[id].map { rows[$0] }
    }

    func groupHeader(repoID: UUID) -> RepoExplorerMaterializedGroupHeaderPresentation? {
        rows.lazy.compactMap { row in
            guard case .groupHeader(let group) = row.presentation,
                group.repoIDs == [repoID]
            else { return nil }
            return group
        }.first
    }

    func replacingRepositoryActivityDisposition(
        repositoryID: UUID,
        disposition: RepositoryActivityDisposition
    ) -> Self {
        guard
            let rowID = rowIDsByRepoID[repositoryID]?.first(where: { rowID in
                guard let row = row(id: rowID), case .groupHeader(let groupHeader) = row.presentation
                else { return false }
                return groupHeader.repoIDs == [repositoryID]
            }),
            let rowIndex = rowIndexByID[rowID],
            case .groupHeader(var groupHeader) = rows[rowIndex].presentation,
            groupHeader.repositoryActivityDisposition != disposition
        else { return self }

        groupHeader.repositoryActivityDisposition = disposition
        var updatedRows = rows
        let previousRow = rows[rowIndex]
        updatedRows[rowIndex] = RepoExplorerMaterializedRow(
            id: previousRow.id,
            contentRevision: RepoExplorerRowContentRevision(
                presentation: .groupHeader(groupHeader)
            ),
            layout: previousRow.layout,
            representedRepoID: previousRow.representedRepoID,
            representedWorktreeID: previousRow.representedWorktreeID
        )
        return Self(rows: updatedRows)
    }

    static func build(
        rowIndex: RepoExplorerRowIndex,
        inputs: RepoExplorerMaterializationInputs
    ) -> Self {
        let rows = rowIndex.entries.enumerated().map { index, entry in
            let presentation = presentation(
                for: entry,
                index: index,
                rowIndex: rowIndex,
                inputs: inputs
            )
            let representedIdentities = representedIdentities(for: presentation)
            let expandedPaneLayout: RepoExplorerRowLayout?
            if case .pane(var pane) = presentation, pane.variants != nil {
                pane.displayVariant = .expanded
                expandedPaneLayout = RepoExplorerRowLayout.make(for: .pane(pane))
            } else {
                expandedPaneLayout = nil
            }
            return RepoExplorerMaterializedRow(
                id: entry.id,
                contentRevision: RepoExplorerRowContentRevision(presentation: presentation),
                layout: RepoExplorerRowLayout.make(for: presentation),
                representedRepoID: representedIdentities.repoID,
                representedWorktreeID: representedIdentities.worktreeID,
                expandedPaneLayout: expandedPaneLayout
            )
        }
        return Self(rows: rows)
    }
}

extension RepoExplorerMaterializationSnapshot {
    private static func presentation(
        for entry: RepoExplorerListEntry,
        index: Int,
        rowIndex: RepoExplorerRowIndex,
        inputs: RepoExplorerMaterializationInputs
    ) -> RepoExplorerMaterializedRowPresentation {
        switch entry {
        case .activitySubgroup(_, let bucket):
            let isFirstInGroup: Bool
            if index > 0, case .resolvedGroupHeader = rowIndex.entries[index - 1] {
                isFirstInGroup = true
            } else {
                isFirstInGroup = false
            }
            return .activitySubgroup(bucket, isFirstInGroup: isFirstInGroup)
        case .sectionHeader(let kind):
            return .sectionHeader(kind: kind, isFirstRow: index == 0)
        case .loadingSectionHeader(let kind):
            let state =
                inputs.projection.sections.first(where: { $0.kind == kind })?
                .loadingState(enrichmentByRepoId: inputs.snapshot.repoEnrichmentSnapshotByRepoId)
                ?? .scanning
            return .loadingSectionHeader(kind: kind, state: state)
        case .loadingRepoRow(let section, let repo):
            let isStatusUnavailable: Bool
            if case .statusUnavailable = inputs.snapshot.repoEnrichmentSnapshotByRepoId[repo.id] {
                isStatusUnavailable = true
            } else {
                isStatusUnavailable = false
            }
            return .loadingRepository(
                section: section,
                repoID: repo.id,
                name: repo.name,
                isStatusUnavailable: isStatusUnavailable
            )
        case .resolvedGroupHeader(let group):
            return groupHeaderPresentation(group, rowIndex: rowIndex, inputs: inputs)
        case .resolvedWorktreeRow(let groupID, let repoID, let worktreeID, let rowID):
            guard
                let context = rowIndex.resolve(
                    groupId: groupID,
                    repoId: repoID,
                    worktreeId: worktreeID,
                    rowId: rowID
                )
            else { return .unresolved(entry.id) }
            return .worktree(
                RepoExplorerMaterializedWorktreePresentation(
                    rowID: rowID,
                    groupID: groupID,
                    repo: context.repo,
                    worktree: context.worktree,
                    checkoutTitle: checkoutTitle(for: context.worktree, in: context.repo),
                    isMainCheckout: isMainCheckout(context.worktree, in: context.repo),
                    checkoutColorHex: context.checkoutColorHex,
                    placementText: context.placementContext?.displayText ?? "",
                    branchStatus: inputs.branchStatusByWorktreeID[worktreeID] ?? .unknown,
                    branchName: inputs.branchNameByWorktreeID[worktreeID] ?? "",
                    bridgeCommandResolution: inputs.bridgeCommandResolutionByWorktreeID[worktreeID]
                        ?? .create,
                    paneDestinations: inputs.projection.paneDestinationsByWorktreeId[worktreeID] ?? [],
                    showsRepositoryFactStatus: true
                )
            )
        case .resolvedPaneRow(let groupID, let identity, let rowID):
            guard
                let context = rowIndex.resolvePane(
                    groupId: groupID,
                    repoId: identity.repoId,
                    paneId: identity.paneId,
                    rowId: rowID
                )
            else { return .unresolved(entry.id) }
            return .pane(context.row)
        case .unassociatedPaneRow(let destination):
            let paneFacts = inputs.paneRowFactsByPaneID[destination.paneId]
            return .unassociatedPane(
                RepoExplorerUnassociatedPanePresentation(
                    variant: RepoExplorerPaneRowVariants.make(
                        title: paneFacts?.sidebarTerminalTitle ?? "Pane \(destination.paneIndexInTab + 1)",
                        note: paneFacts?.secondaryLine?.text, isDrawer: paneFacts?.isDrawerPane ?? false,
                        isActive: paneFacts?.isActive ?? false, recencyText: paneFacts?.recencyText ?? "—",
                        recencyTier: paneFacts?.recencyTier ?? .grey,
                        agentLine: paneFacts?.contextDisplay?.agentLine,
                        sessionPresentation: paneFacts?.sessionPresentation,
                        counts: paneFacts?.contextDisplay?.own.kinds ?? .zero,
                        activityDate: paneFacts?.activityAt, now: inputs.snapshot.referenceDate
                    ).compact,
                    destination: destination,
                    primaryText: paneFacts?.sidebarTerminalTitle ?? "Pane \(destination.paneIndexInTab + 1)",
                    secondaryLine: paneFacts?.secondaryLine,
                    recencyText: paneFacts?.recencyText ?? "—",
                    recencyTier: paneFacts?.recencyTier ?? .strongBlue,
                    isActive: paneFacts?.isActive ?? false,
                    isDrawerPane: paneFacts?.isDrawerPane ?? false
                )
            )
        case .topologyFault(let fault):
            return .topologyFault(fault)
        }
    }

    private static func groupHeaderPresentation(
        _ group: RepoPresentationGroup,
        rowIndex: RepoExplorerRowIndex,
        inputs: RepoExplorerMaterializationInputs
    ) -> RepoExplorerMaterializedRowPresentation {
        let semanticRepo = semanticRepo(for: group, groupingMode: inputs.snapshot.groupingMode)
        let activityRepo = inputs.snapshot.surface == .repos ? semanticRepo : nil
        let paneDestinations =
            inputs.snapshot.groupingMode != .tab && group.repos.count == 1
            ? inputs.projection.paneDestinationsByRepoId[group.repos[0].id] ?? []
            : []
        return .groupHeader(
            RepoExplorerMaterializedGroupHeaderPresentation(
                groupID: group.id,
                icon: inputs.snapshot.groupingMode == .activity
                    ? .activity
                    : (inputs.snapshot.groupingMode == .tab ? .tabGroup : .repo),
                title: group.repoTitle,
                organizationName: group.organizationName,
                colorHex: RepoPresentationColoring.sourceGroupColorHex(for: group),
                isExpanded: rowIndex.isGroupExpanded(group.id),
                repoIDs: group.repos.map(\.id),
                semanticRepoPath: semanticRepo?.repoPath,
                paneDestinations: paneDestinations,
                presentsRepositoryActivity: activityRepo != nil,
                repositoryActivityDisposition: activityRepo.map {
                    inputs.repositoryActivityDispositionByRepoID[$0.id] ?? .unclassified
                } ?? .unclassified,
                repositoryFactUpdateProgress: activityRepo.flatMap {
                    inputs.repositoryFactUpdateProgressByRepoID[$0.id]
                }
            )
        )
    }

    private static func representedIdentities(
        for presentation: RepoExplorerMaterializedRowPresentation
    ) -> (repoID: UUID?, worktreeID: UUID?) {
        switch presentation {
        case .loadingRepository(_, let repoID, _, _):
            return (repoID, nil)
        case .worktree(let worktree):
            return (worktree.repo.id, worktree.worktree.id)
        case .pane(let pane):
            return (pane.repoId, pane.worktreeId)
        case .activitySubgroup, .sectionHeader, .loadingSectionHeader, .groupHeader, .unassociatedPane,
            .topologyFault, .unresolved:
            return (nil, nil)
        }
    }

    private static func semanticRepo(
        for group: RepoPresentationGroup,
        groupingMode: RepoExplorerGroupingMode
    ) -> RepoPresentationItem? {
        guard groupingMode == .repo, group.repos.count == 1 else {
            return nil
        }
        return group.repos[0]
    }

    private static func checkoutTitle(
        for worktree: Worktree,
        in repo: RepoPresentationItem
    ) -> String {
        let folderName = worktree.path.lastPathComponent
        return folderName.isEmpty ? repo.name : folderName
    }

    private static func isMainCheckout(
        _ worktree: Worktree,
        in repo: RepoPresentationItem
    ) -> Bool {
        worktree.isMainWorktree
            || worktree.path.standardizedFileURL.path == repo.repoPath.standardizedFileURL.path
    }
}
