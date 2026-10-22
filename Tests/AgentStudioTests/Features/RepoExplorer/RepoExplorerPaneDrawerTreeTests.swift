import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite("Repo Explorer pane drawer tree")
struct RepoExplorerPaneDrawerTreeTests {
    @Test("attached drawer rows indent one icon column while owners and orphans stay aligned")
    @MainActor
    func drawerContentIndentFollowsTreeAttachment() {
        let iconColumnWidth = AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth
        #expect(RepoExplorerPaneRowContent.leadingContentInset(for: .none) == 0)
        #expect(RepoExplorerPaneRowContent.leadingContentInset(for: .ownerWithDrawers) == 0)
        #expect(RepoExplorerPaneRowContent.leadingContentInset(for: .drawer(isLast: false)) == iconColumnWidth)
        #expect(RepoExplorerPaneRowContent.leadingContentInset(for: .drawer(isLast: true)) == iconColumnWidth)
    }

    @Test("shown drawers follow their owner in tab order and hiding removes their rows")
    func ownerChildrenAndHiddenState() throws {
        let referenceInstant = ContinuousClock.now
        let ownerID = UUIDv7.generate()
        let newerChildID = UUIDv7.generate()
        let olderChildID = UUIDv7.generate()
        let paneIDs = [ownerID, olderChildID, newerChildID]
        let snapshot = makeSnapshot(paneIDs: paneIDs, referenceInstant: referenceInstant, showsDrawers: true)
        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(
            [
                ownerID: makeFacts(title: "owner", age: 180, referenceInstant: referenceInstant),
                newerChildID: makeFacts(
                    title: "newer drawer",
                    age: 60,
                    referenceInstant: referenceInstant,
                    ownerID: ownerID
                ),
                olderChildID: makeFacts(
                    title: "older drawer",
                    age: 120,
                    referenceInstant: referenceInstant,
                    ownerID: ownerID
                ),
            ],
            snapshot: snapshot
        )

        let shown = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: prepared)
        let shownGroupID = try #require(shown.resolvedGroups.first?.id)
        let shownRows = try #require(shown.paneRowsByGroupId[shownGroupID])
        #expect(shownRows.map(\.destination.paneId) == [ownerID, olderChildID, newerChildID])
        #expect(shownRows.map(\.anchorIdentity) == [ownerID, olderChildID, newerChildID])
        #expect(shownRows[1].drawerOwnerPaneID == ownerID)
        #expect(shownRows.map(\.drawerRail) == [.ownerWithDrawers, .drawer(isLast: false), .drawer(isLast: true)])

        let hiddenSnapshot = makeSnapshot(paneIDs: paneIDs, referenceInstant: referenceInstant, showsDrawers: false)
        let hidden = RepoExplorerProjection.project(hiddenSnapshot, paneRowFactsByPaneId: prepared)
        let hiddenGroupID = try #require(hidden.resolvedGroups.first?.id)
        #expect(hidden.paneRowsByGroupId[hiddenGroupID]?.map(\.destination.paneId) == [ownerID])
        #expect(hidden.paneRowsByGroupId[hiddenGroupID]?.first?.drawerRail == RepoExplorerDrawerRail.none)
    }

    @Test("a drawer with no visible owner is unindented")
    func orphanDrawerHasNoRail() throws {
        let referenceInstant = ContinuousClock.now
        let drawerID = UUIDv7.generate()
        let snapshot = makeSnapshot(paneIDs: [drawerID], referenceInstant: referenceInstant, showsDrawers: true)
        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(
            [
                drawerID: makeFacts(
                    title: "Drawer",
                    age: 90,
                    referenceInstant: referenceInstant,
                    ownerID: UUIDv7.generate()
                )
            ],
            snapshot: snapshot
        )

        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: prepared)
        let groupID = try #require(projection.resolvedGroups.first?.id)
        #expect(projection.paneRowsByGroupId[groupID]?.first?.drawerRail == RepoExplorerDrawerRail.none)
        #expect(projection.paneRowsByGroupId[groupID]?.first?.primaryText == "Drawer")
    }

    @Test("a drawer in an older activity bucket stays directly under its owner")
    func drawerFollowsOwnerAcrossActivityBuckets() throws {
        let referenceInstant = ContinuousClock.now
        let ownerID = UUIDv7.generate()
        let drawerID = UUIDv7.generate()
        let snapshot = makeSnapshot(
            paneIDs: [ownerID, drawerID],
            referenceInstant: referenceInstant,
            showsDrawers: true
        )
        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(
            [
                ownerID: makeFacts(title: "Owner", age: 15, referenceInstant: referenceInstant),
                drawerID: makeFacts(
                    title: "Older drawer", age: 7200,
                    referenceInstant: referenceInstant, ownerID: ownerID
                ),
            ],
            snapshot: snapshot
        )

        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: prepared)
        let groupID = try #require(projection.resolvedGroups.first?.id)
        let rows = try #require(projection.paneRowsByGroupId[groupID])
        try #require(rows.count == 2)

        #expect(rows.map(\.destination.paneId) == [ownerID, drawerID])
        #expect(rows.map(\.drawerRail) == [.ownerWithDrawers, .drawer(isLast: true)])
        #expect(rows[0].recencyText != rows[1].recencyText)
    }

    private func makeSnapshot(
        paneIDs: [UUID],
        referenceInstant: ContinuousClock.Instant,
        showsDrawers: Bool
    ) -> RepoExplorerSnapshot {
        let tabID = UUIDv7.generate()
        return RepoExplorerSnapshot(
            repos: [],
            repoEnrichmentByRepoId: [:],
            surface: .panes,
            groupingMode: .activity,
            showsDrawerPanes: showsDrawers,
            referenceDate: Date(timeIntervalSince1970: 1_769_000_000),
            referenceInstant: referenceInstant,
            query: "",
            unassociatedPaneLocations: paneIDs.enumerated().map { index, paneID in
                WorkspacePaneLocation(
                    paneId: paneID,
                    tabId: tabID,
                    tabIndex: 0,
                    paneIndexInTab: index,
                    isActiveInTab: false
                )
            }
        )
    }

    private func makeFacts(
        title: String,
        age: Int,
        referenceInstant: ContinuousClock.Instant,
        ownerID: UUID? = nil
    ) -> RepoExplorerPaneRowFacts {
        RepoExplorerPaneRowFacts(
            terminalTitle: title,
            paneActivityTime: PaneActivityTime(
                orderingInstant: referenceInstant.advanced(by: .seconds(-age)),
                wallTime: Date(timeIntervalSince1970: 1),
                source: .terminal
            ),
            latestMessageText: nil,
            recencyReferenceDate: .distantPast,
            recencyText: "",
            isActive: false,
            isDrawerPane: ownerID != nil,
            drawerOwnerPaneID: ownerID
        )
    }
}
