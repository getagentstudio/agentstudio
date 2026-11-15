import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("RepoExplorerMaterializationSnapshotTests", .serialized)
struct RepoExplorerMaterializationSnapshotTests {
    @Test("section breathing room is above the heading, with no added gap below")
    func sectionSpacingIsAboveOnly() {
        let first = RepoExplorerRowLayout.make(for: .sectionHeader(kind: .openRepositories, isFirstRow: true))
        let later = RepoExplorerRowLayout.make(for: .sectionHeader(kind: .repositories, isFirstRow: false))
        #expect(first.metrics.fallbackHeight == AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight)
        #expect(later.metrics.fallbackHeight - first.metrics.fallbackHeight == 12)
        #expect(
            AppStyles.Shell.Sidebar.nativeSectionHeaderBottomPadding
                + AppStyles.Shell.Sidebar.nativeGroupHeaderTopPadding
                + AppStyles.Shell.Sidebar.groupRowVerticalPadding == AppStyles.Shell.Sidebar.nativeItemSpacing
        )
    }

    @Test("activity subgroup materializes as a section-style row aligned to the child icon column")
    func activitySubgroupUsesSectionStyleAndChildIconAlignment() {
        let presentation = RepoExplorerMaterializedRowPresentation.activitySubgroup(.justNow, isFirstInGroup: true)
        let layout = RepoExplorerRowLayout.make(for: presentation)

        #expect(layout.rowClass == .sectionHeader)
        #expect(
            layout.metrics.leadingInset
                == AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
                + AppStyles.Shell.Sidebar.rowHorizontalInset
        )
        #expect(layout.metrics.metadataLineHeight == AppStyles.Shell.Sidebar.nativeMetadataTextLineHeight)
        #expect(RepoExplorerActivityBucket.justNow.title == "Just Now")
    }

    @Test("locally inactive rows retain cached branch and status facts")
    func locallyInactiveRowsRetainCachedBranchAndStatusFacts() throws {
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let base = try RepoExplorerProjectionWorker.project(
            makeRepoRequest(repoID: repoID, worktreeID: worktreeID)
        )
        let cachedStatus = GitBranchStatus(
            isDirty: true,
            syncState: .diverged(ahead: 159, behind: 1),
            prCount: 2,
            linesAdded: 69,
            linesDeleted: 19,
            untrackedFileCount: 3
        )
        let inactiveMaterialization = RepoExplorerMaterializationSnapshot.build(
            rowIndex: base.rowIndex,
            inputs: RepoExplorerMaterializationInputs(
                snapshot: base.snapshot,
                projection: base.projection,
                branchStatusByWorktreeID: [worktreeID: cachedStatus],
                branchNameByWorktreeID: [worktreeID: "feature/luna"],
                bridgeCommandResolutionByWorktreeID: base.bridgeCommandResolutionByWorktreeId,
                paneRowFactsByPaneID: base.paneRowFactsByPaneId,
                repositoryActivityDispositionByRepoID: [repoID: .locallyInactive]
            )
        )
        let inactiveRow = try #require(
            inactiveMaterialization.rows.first { $0.representedWorktreeID == worktreeID }
        )
        let inactivePresentation = try #require(
            inactiveMaterialization.rows.compactMap { row -> RepoExplorerMaterializedWorktreePresentation? in
                guard case .worktree(let worktree) = row.presentation else { return nil }
                return worktree
            }.first
        )

        #expect(inactivePresentation.showsRepositoryFactStatus)
        #expect(inactivePresentation.branchName == "feature/luna")
        #expect(inactivePresentation.branchStatus == cachedStatus)
        #expect(RepoExplorerWorktreeStatusPresentation.reservesStatusLine(cachedStatus))
        #expect(
            inactiveRow.layout.metrics.fallbackHeight
                == expectedWorktreeHeight(
                    reservesStatusLine: true,
                    metrics: inactiveRow.layout.metrics
                )
        )
    }
}

extension RepoExplorerMaterializationSnapshotTests {
    @Test("inactive refresh preserves cached facts through captured, loading, and settled phases")
    func inactiveRefreshPreservesCachedFactsAcrossProgress() throws {
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let base = try RepoExplorerProjectionWorker.project(
            makeRepoRequest(repoID: repoID, worktreeID: worktreeID)
        )
        let cachedStatus = GitBranchStatus(
            isDirty: true,
            syncState: .ahead(4),
            prCount: 2,
            linesAdded: 21,
            linesDeleted: 8,
            untrackedFileCount: 1
        )
        let attemptID = UUIDv7.generate()
        let captured = RepositoryFactUpdateProgress.captured(repoId: repoID, attemptId: attemptID)
        let loading = RepositoryFactUpdateProgress.admitted(
            repoId: repoID,
            attemptId: attemptID,
            applicableSources: [.localGit],
            terminalResultsBySource: [:]
        )
        let settled = loading.settled([.localGit: .failed])

        for progress in [captured, loading, settled] {
            let materialization = RepoExplorerMaterializationSnapshot.build(
                rowIndex: base.rowIndex,
                inputs: RepoExplorerMaterializationInputs(
                    snapshot: base.snapshot,
                    projection: base.projection,
                    branchStatusByWorktreeID: [worktreeID: cachedStatus],
                    branchNameByWorktreeID: [worktreeID: "feature/cached"],
                    bridgeCommandResolutionByWorktreeID: base.bridgeCommandResolutionByWorktreeId,
                    paneRowFactsByPaneID: base.paneRowFactsByPaneId,
                    repositoryActivityDispositionByRepoID: [repoID: .locallyInactive],
                    repositoryFactUpdateProgressByRepoID: [repoID: progress]
                )
            )
            let presentation = try #require(
                materialization.rows.compactMap { row -> RepoExplorerMaterializedWorktreePresentation? in
                    guard case .worktree(let worktree) = row.presentation else { return nil }
                    return worktree
                }.first
            )
            let header = try #require(materialization.groupHeader(repoID: repoID))

            #expect(presentation.branchName == "feature/cached")
            #expect(presentation.branchStatus == cachedStatus)
            #expect(presentation.showsRepositoryFactStatus)
            #expect(header.repositoryFactUpdateProgress == progress)
        }

        #expect(captured.isLoading == false)
        #expect(loading.isLoading)
        #expect(settled.isLoading == false)
    }

    @Test("worker stores ordered rows with O(1) identity and occurrence indexes")
    func workerStoresOrderedRowsAndOccurrenceIndexes() throws {
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let request = makeRepoRequest(repoID: repoID, worktreeID: worktreeID)

        let result = try RepoExplorerProjectionWorker.project(request)
        let materialization = result.materializationSnapshot
        let orderedIDs = materialization.rows.map(\.id)

        #expect(orderedIDs == result.rowIndex.entries.map(\.id))
        #expect(materialization.rowIndexByID.count == materialization.rows.count)
        #expect(
            materialization.fallbackContentHeight
                == materialization.rows.reduce(into: 0) { totalHeight, row in
                    totalHeight += row.layout.metrics.fallbackHeight
                }
        )
        for (expectedIndex, rowID) in orderedIDs.enumerated() {
            #expect(materialization.rowIndexByID[rowID] == expectedIndex)
            #expect(materialization.row(id: rowID)?.id == rowID)
        }
        #expect(materialization.rowIDsByRepoID[repoID]?.count == 2)
        #expect(materialization.rowIDsByWorktreeID[worktreeID]?.count == 1)
        #expect(
            materialization.rowIDsByWorktreeID[worktreeID]?.first
                == .worktree(
                    groupID: "repos:repositories:remote:askluna/agent-studio",
                    repoID: repoID,
                    worktreeID: worktreeID
                )
        )
    }

    @Test("group icon is an immutable materialized fact from captured grouping mode")
    func groupIconComesFromCapturedGroupingMode() throws {
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let request = makeRepoRequest(repoID: repoID, worktreeID: worktreeID)
        let result = try RepoExplorerProjectionWorker.project(request)
        let updateAttemptID = UUIDv7.generate()
        let settledProgress = RepositoryFactUpdateProgress.captured(
            repoId: repoID,
            attemptId: updateAttemptID
        ).settled([:])
        let repoGroup = try #require(
            result.materializationSnapshot.rows.compactMap { row -> RepoExplorerMaterializedGroupHeaderPresentation? in
                guard case .groupHeader(let group) = row.presentation else { return nil }
                return group
            }.first
        )
        let tabSnapshot = RepoExplorerSnapshot(
            repos: request.snapshot.repos,
            repoEnrichmentByRepoId: request.snapshot.repoEnrichmentSnapshotByRepoId,
            surface: .panes,
            groupingMode: .tab,
            query: request.snapshot.query
        )
        let tabMaterialization = RepoExplorerMaterializationSnapshot.build(
            rowIndex: result.rowIndex,
            inputs: RepoExplorerMaterializationInputs(
                snapshot: tabSnapshot,
                projection: result.projection,
                branchStatusByWorktreeID: result.branchStatusByWorktreeId,
                branchNameByWorktreeID: result.branchNameByWorktreeId,
                bridgeCommandResolutionByWorktreeID: result.bridgeCommandResolutionByWorktreeId,
                paneRowFactsByPaneID: result.paneRowFactsByPaneId,
                repositoryActivityDispositionByRepoID: [repoID: .locallyInactive],
                repositoryFactUpdateProgressByRepoID: [repoID: settledProgress]
            )
        )
        let tabGroup = try #require(
            tabMaterialization.rows.compactMap { row -> RepoExplorerMaterializedGroupHeaderPresentation? in
                guard case .groupHeader(let group) = row.presentation else { return nil }
                return group
            }.first
        )
        let paneSnapshot = RepoExplorerSnapshot(
            repos: request.snapshot.repos,
            repoEnrichmentByRepoId: request.snapshot.repoEnrichmentSnapshotByRepoId,
            surface: .panes,
            groupingMode: .repo,
            query: request.snapshot.query
        )
        let paneMaterialization = RepoExplorerMaterializationSnapshot.build(
            rowIndex: result.rowIndex,
            inputs: RepoExplorerMaterializationInputs(
                snapshot: paneSnapshot,
                projection: result.projection,
                branchStatusByWorktreeID: result.branchStatusByWorktreeId,
                branchNameByWorktreeID: result.branchNameByWorktreeId,
                bridgeCommandResolutionByWorktreeID: result.bridgeCommandResolutionByWorktreeId,
                paneRowFactsByPaneID: result.paneRowFactsByPaneId,
                repositoryActivityDispositionByRepoID: [repoID: .locallyInactive],
                repositoryFactUpdateProgressByRepoID: [repoID: settledProgress]
            )
        )
        let paneGroup = try #require(
            paneMaterialization.rows.compactMap { row -> RepoExplorerMaterializedGroupHeaderPresentation? in
                guard case .groupHeader(let group) = row.presentation else { return nil }
                return group
            }.first
        )

        #expect(repoGroup.icon == .repo)
        #expect(repoGroup.presentsRepositoryActivity)
        #expect(tabGroup.icon == .tabGroup)
        #expect(!tabGroup.presentsRepositoryActivity)
        #expect(tabGroup.repositoryActivityDisposition == .unclassified)
        #expect(tabGroup.repositoryFactUpdateProgress == nil)
        #expect(!paneGroup.presentsRepositoryActivity)
        #expect(paneGroup.repositoryActivityDisposition == .unclassified)
        #expect(paneGroup.repositoryFactUpdateProgress == nil)
    }

    @Test("every grouping mode materializes group and child rows on the shared native grid")
    func everyGroupingModeMaterializesRowsOnSharedNativeGrid() throws {
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let paneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let result = try RepoExplorerProjectionWorker.project(
            makeRepoRequest(repoID: repoID, worktreeID: worktreeID)
        )
        let worktreePresentation = try #require(
            result.materializationSnapshot.rows.compactMap { row -> RepoExplorerMaterializedWorktreePresentation? in
                guard case .worktree(let worktree) = row.presentation else { return nil }
                return worktree
            }.first
        )
        let paneDestination = RepoExplorerPaneDestination(
            paneId: paneID,
            repoId: repoID,
            worktreeId: worktreeID,
            worktreeLabel: "main",
            tabId: tabID,
            tabIndex: 0,
            paneIndexInTab: 0,
            isActiveInTab: true
        )
        let panePresentation = RepoExplorerProjectedPaneRow(
            groupId: "pane-repo:\(repoID.uuidString)",
            repoId: repoID,
            destination: paneDestination,
            rowId: "pane-row:\(paneID.uuidString)",
            primaryText: "Pane 1"
        )
        let tabPanePresentation = RepoExplorerProjectedPaneRow(
            groupId: "tab:\(tabID.uuidString)",
            repoId: repoID,
            destination: paneDestination,
            membershipOwner: .tab,
            rowId: "tab-pane-row:\(paneID.uuidString)",
            primaryText: "Pane 1"
        )
        let childPresentations: [(RepoExplorerGroupingMode, RepoExplorerMaterializedRowPresentation)] = [
            (.repo, .worktree(worktreePresentation)),
            (.repo, .pane(panePresentation)),
            (.tab, .pane(tabPanePresentation)),
        ]

        for (groupingMode, childPresentation) in childPresentations {
            let groupPresentation = RepoExplorerMaterializedRowPresentation.groupHeader(
                RepoExplorerMaterializedGroupHeaderPresentation(
                    groupID: groupingMode.rawValue,
                    icon: groupingMode == .tab ? .tabGroup : .repo,
                    title: groupingMode.title,
                    organizationName: nil,
                    colorHex: nil,
                    isExpanded: true,
                    repoIDs: [repoID],
                    semanticRepoPath: nil,
                    paneDestinations: []
                )
            )
            let groupLayout = RepoExplorerRowLayout.make(for: groupPresentation)
            let childLayout = RepoExplorerRowLayout.make(for: childPresentation)

            #expect(groupLayout.rowClass == .groupHeader)
            #expect(groupLayout.metrics.leadingInset == 0)
            let expectedRowClass: RepoExplorerRowLayoutClass =
                if case .worktree = childPresentation { .worktree } else { .pane }
            #expect(childLayout.rowClass == expectedRowClass)
            #expect(
                childLayout.metrics.leadingInset
                    == AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
            )
        }
    }

    @Test("layout facts are stable and only declared wrapping rows request visible measurement")
    func layoutFactsAreStableAndWrappingIsExplicit() throws {
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let result = try RepoExplorerProjectionWorker.project(
            makeRepoRequest(repoID: repoID, worktreeID: worktreeID)
        )

        #expect(
            result.materializationSnapshot.rows.map(\.layout.rowClass) == [
                .sectionHeader,
                .groupHeader,
                .worktree,
            ])
        #expect(result.materializationSnapshot.rows.allSatisfy { !$0.layout.requiresVisibleWidthMeasurement })
        let sectionRow = try #require(
            result.materializationSnapshot.rows.first { $0.layout.rowClass == .sectionHeader }
        )
        let worktreeRow = try #require(
            result.materializationSnapshot.rows.first { $0.layout.rowClass == .worktree }
        )
        let worktreePresentation = try requiredWorktreePresentation(worktreeRow)
        #expect(worktreePresentation.branchName.isEmpty)
        let groupHeaderRow = try #require(
            result.materializationSnapshot.rows.first { $0.layout.rowClass == .groupHeader }
        )
        #expect(
            sectionRow.layout.metrics.primaryLineHeight
                == AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
        )
        #expect(
            worktreeRow.layout.metrics.primaryLineHeight
                == AppStyles.Shell.Sidebar.nativeInlineControlLineHeight
        )
        #expect(
            worktreeRow.layout.metrics.fallbackHeight
                == expectedWorktreeHeight(
                    reservesStatusLine: false,
                    metadataLineCount: 0,
                    metrics: worktreeRow.layout.metrics
                )
        )
        #expect(
            groupHeaderRow.layout.metrics.fallbackHeight
                == AppStyles.Shell.Sidebar.nativeGroupTitleLineHeight
                + AppStyles.Shell.Sidebar.groupRowVerticalPadding * 2
                + AppStyles.Shell.Sidebar.nativeGroupHeaderTopPadding
                + AppStyles.Shell.Sidebar.nativeGroupHeaderBottomPadding
        )

        let loadingRepositoryLayout = RepoExplorerRowLayout.make(
            for: .loadingRepository(
                section: .repositories,
                repoID: repoID,
                name: "Loading repository",
                isStatusUnavailable: false
            )
        )
        #expect(
            loadingRepositoryLayout.metrics.verticalInset
                == AppStyles.Shell.Sidebar.nativeRowVerticalInset
        )
        #expect(
            loadingRepositoryLayout.metrics.fallbackHeight
                == AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
                + AppStyles.Shell.Sidebar.nativeItemSpacing
        )

        let fault = RepoExplorerTopologyFault.duplicateWorktreeIdentities([
            RepoExplorerDuplicateWorktreeIdentity(
                worktreeId: worktreeID,
                claims: [
                    RepoExplorerWorktreeIdentityClaim(
                        repoId: repoID,
                        stableKey: "first",
                        path: URL(fileURLWithPath: "/tmp/first")
                    ),
                    RepoExplorerWorktreeIdentityClaim(
                        repoId: UUIDv7.generate(),
                        stableKey: "second",
                        path: URL(fileURLWithPath: "/tmp/second")
                    ),
                ]
            )
        ])
        let faultProjection = RepoExplorerSidebarProjection.degraded(fault)
        let faultIndex = RepoExplorerRowIndex(
            projection: faultProjection,
            collapsedGroupIds: [],
            isFiltering: false
        )
        let faultMaterialization = RepoExplorerMaterializationSnapshot.build(
            rowIndex: faultIndex,
            inputs: RepoExplorerMaterializationInputs(
                snapshot: .init(
                    repos: [], repoEnrichmentByRepoId: [:], groupingMode: .repo, query: ""),
                projection: faultProjection,
                branchStatusByWorktreeID: [:],
                branchNameByWorktreeID: [:],
                bridgeCommandResolutionByWorktreeID: [:],
                paneRowFactsByPaneID: [:]
            )
        )

        #expect(faultMaterialization.rows.map(\.layout.rowClass) == [.fault])
        #expect(faultMaterialization.rows.allSatisfy { $0.layout.requiresVisibleWidthMeasurement })
    }

    @Test("unresolved idle status reserves no loading or empty chip line")
    func pendingAndResolvedWorktreeStatusReserveStableChipLine() {
        let unresolvedIdleStatus = GitBranchStatus(
            isDirty: false,
            syncState: .unknown,
            prCount: nil,
            pullRequestIsLoading: false,
            pullRequestDataUnavailable: false,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )
        let resolvedStatus = GitBranchStatus(
            isDirty: true,
            syncState: .diverged(ahead: 7, behind: 3),
            prCount: 2,
            linesAdded: 0,
            linesDeleted: 116,
            untrackedFileCount: 0
        )
        let confirmedEmptyStatus = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: 0,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )

        let unresolvedIdleLayout = RepoExplorerRowLayout.make(
            for: worktreePresentation(branchStatus: unresolvedIdleStatus)
        )
        let resolvedLayout = RepoExplorerRowLayout.make(
            for: worktreePresentation(branchStatus: resolvedStatus)
        )
        let confirmedEmptyLayout = RepoExplorerRowLayout.make(
            for: worktreePresentation(branchStatus: confirmedEmptyStatus)
        )

        #expect(!RepoExplorerWorktreeStatusPresentation.showsPendingIndicator(unresolvedIdleStatus))
        #expect(!RepoExplorerWorktreeStatusPresentation.reservesStatusLine(unresolvedIdleStatus))
        #expect(RepoExplorerWorktreeStatusPresentation.reservesStatusLine(resolvedStatus))
        #expect(!RepoExplorerWorktreeStatusPresentation.reservesStatusLine(confirmedEmptyStatus))
        #expect(unresolvedIdleLayout.metrics.fallbackHeight == confirmedEmptyLayout.metrics.fallbackHeight)
        #expect(resolvedLayout.metrics.fallbackHeight > unresolvedIdleLayout.metrics.fallbackHeight)
    }

    @Test("refreshing confirmed-empty status preserves compact worktree layout")
    func refreshingConfirmedEmptyStatusPreservesCompactWorktreeLayout() {
        let confirmedEmptyStatus = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: 0,
            pullRequestIsLoading: false,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )
        let refreshingConfirmedEmptyStatus = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: 0,
            pullRequestIsLoading: true,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )

        let confirmedEmptyLayout = RepoExplorerRowLayout.make(
            for: worktreePresentation(branchStatus: confirmedEmptyStatus)
        )
        let refreshingConfirmedEmptyLayout = RepoExplorerRowLayout.make(
            for: worktreePresentation(branchStatus: refreshingConfirmedEmptyStatus)
        )

        #expect(
            RepoExplorerWorktreeStatusPresentation.showsPendingIndicator(
                refreshingConfirmedEmptyStatus
            )
        )
        #expect(
            RepoExplorerWorktreeStatusPresentation.showsPendingIndicatorInMetadataLine(
                refreshingConfirmedEmptyStatus
            )
        )
        #expect(!RepoExplorerWorktreeStatusPresentation.reservesStatusLine(confirmedEmptyStatus))
        #expect(
            !RepoExplorerWorktreeStatusPresentation.reservesStatusLine(
                refreshingConfirmedEmptyStatus
            )
        )
        #expect(confirmedEmptyLayout.metrics == refreshingConfirmedEmptyLayout.metrics)
    }

    @Test("fixed native row slots never undercut their rendered controls or text")
    func fixedNativeRowSlotsNeverUndercutRenderedContent() throws {
        let mainResult = try RepoExplorerProjectionWorker.project(
            makeRepoRequest(
                repoID: UUIDv7.generate(),
                worktreeID: UUIDv7.generate(),
                isMainWorktree: true
            )
        )
        let linkedResult = try RepoExplorerProjectionWorker.project(
            makeRepoRequest(
                repoID: UUIDv7.generate(),
                worktreeID: UUIDv7.generate(),
                isMainWorktree: false
            )
        )
        let sectionRow = try #require(
            mainResult.materializationSnapshot.rows.first { $0.layout.rowClass == .sectionHeader }
        )
        let groupRow = try #require(
            mainResult.materializationSnapshot.rows.first { $0.layout.rowClass == .groupHeader }
        )
        let mainWorktreeRow = try #require(
            mainResult.materializationSnapshot.rows.first { $0.layout.rowClass == .worktree }
        )
        let linkedWorktreeRow = try #require(
            linkedResult.materializationSnapshot.rows.first { $0.layout.rowClass == .worktree }
        )

        let renderedPrimaryLineHeight = ceil(
            NSFont.systemFont(
                ofSize: AppStyles.General.Typography.textBase,
                weight: .semibold
            ).boundingRectForFont.height
        )
        let renderedMetadataLineHeight = ceil(
            NSFont.systemFont(
                ofSize: AppStyles.General.Typography.textSm,
                weight: .medium
            ).boundingRectForFont.height
        )
        let renderedGroupTitleLineHeight = ceil(
            NSFont.systemFont(
                ofSize: AppStyles.General.Typography.textLg,
                weight: .semibold
            ).boundingRectForFont.height
        )

        #expect(sectionRow.layout.metrics.primaryLineHeight >= renderedPrimaryLineHeight)
        #expect(groupRow.layout.metrics.primaryLineHeight >= renderedGroupTitleLineHeight)
        #expect(mainWorktreeRow.layout.metrics.primaryLineHeight >= AppStyles.General.Button.compact)
        #expect(linkedWorktreeRow.layout.metrics.primaryLineHeight >= renderedPrimaryLineHeight)
        #expect(mainWorktreeRow.layout.metrics.metadataLineHeight >= renderedMetadataLineHeight)
        #expect(linkedWorktreeRow.layout.metrics.metadataLineHeight >= renderedMetadataLineHeight)
    }

    @Test("content revision retains every associated-pane legacy fact")
    func paneContentRevisionIncludesEveryRenderedField() {
        let repoID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let paneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let destination = RepoExplorerPaneDestination(
            paneId: paneID,
            repoId: repoID,
            worktreeId: worktreeID,
            worktreeLabel: "main",
            tabId: tabID,
            tabIndex: 0,
            paneIndexInTab: 0,
            isActiveInTab: true
        )
        let baseline = RepoExplorerProjectedPaneRow(
            groupId: "pane-group",
            repoId: repoID,
            destination: destination,
            rowId: "legacy-worker-row-id",
            primaryText: "zsh",
            secondaryLine: .terminalOutput("building"),
            branchContextText: "main",
            branchStatus: .unknown,
            recencyText: "Now",
            recencyTier: .strongBlue,
            isActive: false,
            isDrawerPane: false
        )
        let changedRows = [
            replacing(baseline, primaryText: "tests"),
            replacing(baseline, secondaryLine: .note("review")),
            replacing(baseline, branchContextText: "feature"),
            replacing(
                baseline,
                branchStatus: GitBranchStatus(
                    isDirty: true,
                    syncState: .ahead(1),
                    prCount: 0,
                    pullRequestIsLoading: false,
                    pullRequestDataUnavailable: false,
                    linesAdded: 3,
                    linesDeleted: 1,
                    untrackedFileCount: 0
                )
            ),
            replacing(baseline, recencyText: "5m"),
            replacing(baseline, recencyTier: .grey),
            replacing(baseline, isActive: true),
            replacing(baseline, isDrawerPane: true),
        ]
        let baselineRevision = RepoExplorerRowContentRevision(
            presentation: .pane(baseline)
        )
        // Actual rendered-variant height/revision is covered by renderedVariantOwnsHeightAndRevision.

        for changedRow in changedRows {
            #expect(
                RepoExplorerRowContentRevision(presentation: .pane(changedRow))
                    != baselineRevision
            )
        }
    }

    @Test("By Tab materializes an unassociated pane as a focusable pane without repository identity")
    func byTabMaterializesUnassociatedPaneWithoutRepositoryIdentity() throws {
        let paneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let groupID = "tab:\(tabID.uuidString)"
        let destination = RepoExplorerUnassociatedPaneDestination(
            paneId: paneID,
            tabId: tabID,
            tabIndex: 0,
            paneIndexInTab: 0,
            isActiveInTab: true
        )
        var projectedRow = RepoExplorerProjectedPaneRow(
            groupId: groupID,
            destination: destination,
            rowId: "pane-row:\(groupID):\(paneID.uuidString)",
            primaryText: "Pane 1 · shell",
            secondaryLine: .terminalOutput("ready"),
            recencyText: "Now",
            isActive: true
        )
        let visible = RepoExplorerPaneRowVariant(lines: [.title("Pane 1 · shell")])
        projectedRow.variants = .init(compact: visible, expanded: visible)
        let group = RepoPresentationGroup(
            id: groupID,
            repoTitle: "Unassociated",
            organizationName: "1 pane",
            repos: []
        )
        let projection = RepoExplorerSidebarProjection.ready(
            RepoExplorerSidebarContent(
                sections: [
                    RepoExplorerSidebarSection(
                        kind: .panes,
                        resolvedGroups: [group],
                        loadingRepos: []
                    )
                ],
                resolvedGroups: [group],
                paneRowsByGroupId: [groupID: [projectedRow]],
                loadingRepos: [],
                emptyState: .content
            )
        )
        let rowIndex = RepoExplorerRowIndex(
            projection: projection,
            collapsedGroupIds: [],
            isFiltering: false
        )
        let materialization = RepoExplorerMaterializationSnapshot.build(
            rowIndex: rowIndex,
            inputs: RepoExplorerMaterializationInputs(
                snapshot: RepoExplorerSnapshot(
                    repos: [],
                    repoEnrichmentByRepoId: [:],
                    surface: .panes,
                    groupingMode: .tab,
                    query: ""
                ),
                projection: projection,
                branchStatusByWorktreeID: [:],
                branchNameByWorktreeID: [:],
                bridgeCommandResolutionByWorktreeID: [:],
                paneRowFactsByPaneID: [:]
            )
        )

        let rowID = RepoExplorerRowID.tabPane(groupID: groupID, paneID: paneID)
        let materializedRow = try #require(materialization.row(id: rowID))
        guard case .pane(let pane) = materializedRow.presentation else {
            Issue.record("Expected an ordinary pane-row presentation")
            return
        }
        #expect(pane.destination.paneId == paneID)
        #expect(pane.repoId == nil)
        #expect(pane.worktreeId == nil)
        #expect(pane.branchContextText == nil)
        #expect(pane.branchStatus == nil)
        #expect(pane.variants?.compact == visible)
        #expect(materializedRow.representedRepoID == nil)
        #expect(materializedRow.representedWorktreeID == nil)
        #expect(
            materializedRow.layout.metrics.fallbackHeight
                == expectedMetadataHeight(
                    metadataLineCount: 0,
                    metrics: materializedRow.layout.metrics
                )
        )
    }

    @Test("unassociated pane layout reserves only rendered lines")
    func unassociatedPaneLayoutReservesOnlyRenderedLines() {
        let destination = RepoExplorerUnassociatedPaneDestination(
            paneId: UUIDv7.generate(),
            tabId: UUIDv7.generate(),
            tabIndex: 0,
            paneIndexInTab: 0,
            isActiveInTab: false
        )
        let presentation = RepoExplorerMaterializedRowPresentation.unassociatedPane(
            RepoExplorerUnassociatedPanePresentation(
                variant: .init(lines: [.title("Pane 1 · zsh")]),
                destination: destination,
                primaryText: "Pane 1 · zsh",
                secondaryLine: nil,
                recencyText: "Now",
                recencyTier: .strongBlue,
                isActive: false,
                isDrawerPane: false
            )
        )
        let layout = RepoExplorerRowLayout.make(for: presentation)

        #expect(
            layout.metrics.fallbackHeight
                == expectedMetadataHeight(metadataLineCount: 0, metrics: layout.metrics)
        )
    }

    private func expectedMetadataHeight(
        metadataLineCount: CGFloat,
        metrics: RepoExplorerRowLayoutMetrics
    ) -> CGFloat {
        metrics.primaryLineHeight
            + metrics.metadataLineHeight * metadataLineCount
            + metrics.contentSpacing * metadataLineCount
            + metrics.verticalInset * 2
    }

    private func expectedWorktreeHeight(
        reservesStatusLine: Bool,
        metadataLineCount: CGFloat = 1,
        metrics: RepoExplorerRowLayoutMetrics
    ) -> CGFloat {
        expectedMetadataHeight(metadataLineCount: metadataLineCount, metrics: metrics)
            + (reservesStatusLine ? metrics.chipLineHeight + metrics.contentSpacing : 0)
    }

    private func worktreePresentation(
        branchStatus: GitBranchStatus
    ) -> RepoExplorerMaterializedRowPresentation {
        let repoID = UUIDv7.generate()
        let worktree = Worktree(
            id: UUIDv7.generate(),
            repoId: repoID,
            name: "main",
            path: URL(fileURLWithPath: "/tmp/repo-explorer-stable-pending-status-line"),
            isMainWorktree: true
        )
        let repo = RepoPresentationItem(
            id: repoID,
            name: "agent-studio",
            repoPath: worktree.path,
            stableKey: "agent-studio",
            worktrees: [worktree]
        )
        let rowID = RepoExplorerRowID.worktree(
            groupID: "remote:askluna/agent-studio",
            repoID: repoID,
            worktreeID: worktree.id
        )
        return .worktree(
            RepoExplorerMaterializedWorktreePresentation(
                rowID: rowID,
                groupID: "remote:askluna/agent-studio",
                repo: repo,
                worktree: worktree,
                checkoutTitle: "agent-studio",
                isMainCheckout: true,
                checkoutColorHex: "#F5C451",
                placementText: "",
                branchStatus: branchStatus,
                branchName: "main",
                bridgeCommandResolution: .create,
                paneDestinations: []
            )
        )
    }

    private func makeRepoRequest(
        repoID: UUID,
        worktreeID: UUID,
        isMainWorktree: Bool = true
    ) -> RepoExplorerProjectionRequest {
        let worktree = Worktree(
            id: worktreeID,
            repoId: repoID,
            name: "main",
            path: URL(fileURLWithPath: "/tmp/agent-studio"),
            isMainWorktree: isMainWorktree
        )
        let repo = RepoPresentationItem(
            id: repoID,
            name: "agent-studio",
            repoPath: worktree.path,
            stableKey: "agent-studio",
            worktrees: [worktree]
        )
        return RepoExplorerProjectionRequest(
            generation: 1,
            snapshot: RepoExplorerSnapshot(
                repos: [repo],
                repoEnrichmentByRepoId: [
                    repoID: .resolvedRemote(
                        repoId: repoID,
                        raw: RawRepoOrigin(
                            origin: "git@github.com:askluna/agent-studio.git",
                            upstream: nil
                        ),
                        identity: RepoIdentity(
                            groupKey: "remote:askluna/agent-studio",
                            remoteSlug: "askluna/agent-studio",
                            organizationName: "askluna",
                            displayName: "agent-studio"
                        ),
                        updatedAt: Date(timeIntervalSince1970: 0)
                    )
                ],
                groupingMode: .repo,
                query: ""
            ),
            collapsedGroupIds: [],
            isFiltering: false,
            trigger: .dataRefresh
        )
    }

    private func replacing(
        _ row: RepoExplorerProjectedPaneRow,
        primaryText: String? = nil,
        secondaryLine: RepoExplorerPaneSecondaryLine?? = nil,
        branchContextText: String?? = nil,
        branchStatus: GitBranchStatus?? = nil,
        recencyText: String? = nil,
        recencyTier: RepoExplorerPaneRecencyTier? = nil,
        isActive: Bool? = nil,
        isDrawerPane: Bool? = nil
    ) -> RepoExplorerProjectedPaneRow {
        switch row.destination {
        case .associated(let destination):
            RepoExplorerProjectedPaneRow(
                groupId: row.groupId,
                repoId: destination.repoId,
                destination: destination,
                membershipOwner: row.membershipOwner,
                rowId: row.rowId,
                primaryText: primaryText ?? row.primaryText,
                secondaryLine: secondaryLine ?? row.secondaryLine,
                branchContextText: branchContextText ?? row.branchContextText,
                branchStatus: branchStatus ?? row.branchStatus,
                recencyText: recencyText ?? row.recencyText,
                recencyTier: recencyTier ?? row.recencyTier,
                isActive: isActive ?? row.isActive,
                isDrawerPane: isDrawerPane ?? row.isDrawerPane
            )
        case .unassociated(let destination):
            RepoExplorerProjectedPaneRow(
                groupId: row.groupId,
                destination: destination,
                rowId: row.rowId,
                primaryText: primaryText ?? row.primaryText,
                secondaryLine: secondaryLine ?? row.secondaryLine,
                recencyText: recencyText ?? row.recencyText,
                recencyTier: recencyTier ?? row.recencyTier,
                isActive: isActive ?? row.isActive,
                isDrawerPane: isDrawerPane ?? row.isDrawerPane
            )
        }
    }
}

private func requiredWorktreePresentation(
    _ row: RepoExplorerMaterializedRow
) throws -> RepoExplorerMaterializedWorktreePresentation {
    var worktreePresentation: RepoExplorerMaterializedWorktreePresentation?
    if case .worktree(let presentation) = row.presentation {
        worktreePresentation = presentation
    }
    return try #require(worktreePresentation)
}
