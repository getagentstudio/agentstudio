import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite
struct RepoExplorerPaneMessageCountTests {
    @Test
    func actualRowsReceiveTheirPreparedCountsAndFixedChipOrder() throws {
        let owner = UUIDv7.generate()
        let child = UUIDv7.generate()
        let tab = UUIDv7.generate()
        let own = counts(failure: 0, needsYou: 1, info: 8)
        let drawerOwn = counts(failure: 2, needsYou: 3, info: 4)
        let ownerDisplay = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: nil, own: own,
            includingDrawers: counts(failure: 2, needsYou: 4, info: 12), pullRequests: .notApplicable
        )
        let childDisplay = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: nil, own: drawerOwn,
            includingDrawers: .zero, pullRequests: .notApplicable)
        let snapshot = RepoExplorerSnapshot(
            repos: [], repoEnrichmentByRepoId: [:], surface: .panes, query: "",
            unassociatedPaneLocations: [owner, child].enumerated().map { offset, pane in
                WorkspacePaneLocation(
                    paneId: pane, tabId: tab, tabIndex: 0, paneIndexInTab: offset, isActiveInTab: false)
            })
        let facts: [UUID: RepoExplorerPaneRowFacts] = [
            owner: .init(
                terminalTitle: "Owner", contextDisplay: ownerDisplay, latestMessageText: nil,
                recencyReferenceDate: .distantPast, recencyText: "—", isActive: false),
            child: .init(
                terminalTitle: "Child", contextDisplay: childDisplay, latestMessageText: nil,
                recencyReferenceDate: .distantPast, recencyText: "—", isActive: false, isDrawerPane: true,
                drawerOwnerPaneID: owner),
        ]
        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: facts)
        let rows = projection.resolvedGroups.flatMap { projection.paneRowsByGroupId[$0.id] ?? [] }
        let ownerRow = try #require(rows.first { $0.destination.paneId == owner })
        let childRow = try #require(rows.first { $0.destination.paneId == child })
        #expect(
            ownerRow.variants?.compact.chipModels == [
                .init(kind: .failure, count: 2), .init(kind: .needsYou, count: 4), .init(kind: .info, count: 12),
            ])
        #expect(
            childRow.variants?.compact.chipModels == [
                .init(kind: .failure, count: 2), .init(kind: .needsYou, count: 3), .init(kind: .info, count: 4),
            ])
        #expect(ownerRow.variants?.compact.fallbackLineCount == ownerRow.variants?.expanded.fallbackLineCount)
    }
    private func counts(failure: Int, needsYou: Int, done: Int = 0, info: Int) -> PaneMessageCounts {
        .init(
            kinds: .init(failure: failure, needsYou: needsYou, done: done, info: info), newestOpenBlockingAskId: nil)
    }
}
