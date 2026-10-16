import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite
struct RepoExplorerPaneMessageCountTests {
    @Test
    func ownerUsesDrawersChildUsesOwnAndTotalsCountEachSourceOnce() {
        let owner = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: nil,
            own: counts(approval: 0, reply: 1, attention: 0, information: 8),
            includingDrawers: counts(approval: 2, reply: 1, attention: 3, information: 12), pullRequests: .notApplicable
        )
        let drawer = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: nil,
            own: counts(approval: 2, reply: 0, attention: 3, information: 4),
            includingDrawers: .zero, pullRequests: .notApplicable)
        let ownerChip = RepoExplorerPaneMessageCountProjection.make(display: owner, isDrawer: false)
        let drawerChip = RepoExplorerPaneMessageCountProjection.make(display: drawer, isDrawer: true)
        #expect(ownerChip.count == 6)
        #expect(drawerChip.count == 5)
        #expect(ownerChip.tone == .danger)
        #expect(drawerChip.tone == .danger)
        #expect(RepoExplorerPaneMessageCountProjection.totalOwn([owner, drawer]) == 6)
        #expect(ownerChip.countIncludingInformational == 18)
        #expect(drawerChip.countIncludingInformational == 9)
        #expect(RepoExplorerPaneMessageCountProjection.totalOwn([owner, drawer], includingInformational: true) == 18)
    }
    @Test
    func tintAndInformationComeOnlyFromCountedTypes() {
        let cases: [MessageCountOracle] = [
            .init(
                counts: counts(approval: 1, reply: 3, attention: 4, information: 9), count: 8, tone: .danger,
                countIncludingInformational: 17, toneIncludingInformational: .danger),
            .init(
                counts: counts(approval: 0, reply: 1, attention: 0, information: 9), count: 1, tone: .warning,
                countIncludingInformational: 10, toneIncludingInformational: .warning),
            .init(
                counts: counts(approval: 0, reply: 0, attention: 2, information: 9), count: 2, tone: .warning,
                countIncludingInformational: 11, toneIncludingInformational: .warning),
            .init(
                counts: counts(approval: 0, reply: 0, attention: 0, information: 9), count: 0, tone: .neutral,
                countIncludingInformational: 9, toneIncludingInformational: .info),
            .init(
                counts: .zero, count: 0, tone: .neutral, countIncludingInformational: 0,
                toneIncludingInformational: .neutral),
        ]
        for oracle in cases {
            let model = RepoExplorerPaneMessageCountProjection.make(oracle.counts)
            #expect(model.count == oracle.count)
            #expect(model.tone == oracle.tone)
            #expect(model.countIncludingInformational == oracle.countIncludingInformational)
            #expect(model.toneIncludingInformational == oracle.toneIncludingInformational)
        }
    }
    struct MessageCountOracle {
        let counts: PaneMessageCounts
        let count: Int
        let tone: PaneContextChipTone
        let countIncludingInformational: Int
        let toneIncludingInformational: PaneContextChipTone
    }

    @Test
    func actualRowsReceiveTheirPreparedCountsAndFixedChipOrder() throws {
        let owner = UUIDv7.generate()
        let child = UUIDv7.generate()
        let tab = UUIDv7.generate()
        let own = counts(approval: 0, reply: 1, attention: 0, information: 8)
        let drawerOwn = counts(approval: 2, reply: 0, attention: 3, information: 4)
        let ownerDisplay = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: nil, own: own,
            includingDrawers: counts(approval: 2, reply: 1, attention: 3, information: 12), pullRequests: .notApplicable
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
        #expect(ownerRow.messageChip?.count == 6)
        #expect(childRow.messageChip?.count == 5)
        #expect(ownerRow.variants?.compact.chips == [.messages, .clock])
        #expect(childRow.variants?.compact.chips == [.drawer, .messages, .clock])
        #expect(ownerRow.variants?.compact.fallbackLineCount == ownerRow.variants?.expanded.fallbackLineCount)
    }
    private func counts(approval: Int, reply: Int, attention: Int, information: Int) -> PaneMessageCounts {
        .init(
            needsApprovalCount: approval, needsReplyCount: reply, attentionCount: attention,
            informationalCount: information, newestOpenBlockingAskId: nil)
    }
}
