import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

extension RepoExplorerPaneContextLineTests {
    struct MessageAgeOracle: Sendable {
        let seconds: Double
        let message: String
        let chip: String
        let nextSeconds: Double
    }

    static let messageAges: [MessageAgeOracle] = [
        .init(seconds: -5, message: "just now", chip: "Now", nextSeconds: 60),
        .init(seconds: 0, message: "just now", chip: "Now", nextSeconds: 60),
        .init(seconds: 59.999, message: "just now", chip: "Now", nextSeconds: 60),
        .init(seconds: 60, message: "1 min ago", chip: "1m", nextSeconds: 120),
        .init(seconds: 60.001, message: "1 min ago", chip: "1m", nextSeconds: 120),
        .init(seconds: 125, message: "2 min ago", chip: "2m", nextSeconds: 180),
        .init(seconds: 3599.999, message: "59 min ago", chip: "59m", nextSeconds: 3600),
        .init(seconds: 3600, message: "1 hr ago", chip: "1h", nextSeconds: 7200),
        .init(seconds: 3600.001, message: "1 hr ago", chip: "1h", nextSeconds: 7200),
        .init(seconds: 86_400 - 0.001, message: "23 hr ago", chip: "23h", nextSeconds: 86_400),
        .init(seconds: 86_400, message: "1 days ago", chip: "1d", nextSeconds: 172_800),
        .init(seconds: 86_400.001, message: "1 days ago", chip: "1d", nextSeconds: 172_800),
        .init(seconds: 172_800, message: "2 days ago", chip: "2d", nextSeconds: 259_200),
    ]

    @Test("message and chip labels share exact unit boundaries without changing message paint", arguments: messageAges)
    func messageAgeSharesChipUnits(_ oracle: MessageAgeOracle) {
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        let now = written.addingTimeInterval(oracle.seconds)
        let detail = AgentLineDetail(
            summary: "A message", refs: [], writer: .pane(.generateUUIDv7()), updatedAt: written)

        let line = RepoExplorerPaneContextLine.agent(detail, now: now)

        #expect(line.text == "A message")
        #expect(line.ageText == oracle.message)
        #expect(line.tone == .neutral)
        #expect(line.glyphMotion == .still)
        #expect(RepoExplorerPaneRecencyText.display(lastInteractedAt: written, now: now) == oracle.chip)
        #expect(
            RepoExplorerPaneContextLine.nextMessageAgeChangeDate(detail, now: now)
                == written.addingTimeInterval(oracle.nextSeconds))
    }
}

extension RepoExplorerPaneActivityProjectionTests {
    @Test(
        "a message without activity supplies row age and the next visible deadline under every sort",
        arguments: [SidebarSortField.name, .activity])
    func messageOnlyRowSchedulesItsOwnAge(sort: SidebarSortField) throws {
        let paneId = UUIDv7.generate()
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        let now = written.addingTimeInterval(125)
        let line = AgentLineDetail(
            summary: "Quiet message", refs: [], writer: .pane(.init(existingUUID: paneId)), updatedAt: written)
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: line,
            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
        let facts = RepoExplorerPaneRowFacts(
            terminalTitle: "Terminal", contextDisplay: display, latestMessageText: nil,
            recencyReferenceDate: .distantPast, recencyText: "—", isActive: false)
        let snapshot = RepoExplorerSnapshot(
            repos: [], repoEnrichmentByRepoId: [:], surface: .panes, groupingMode: .repo,
            sortField: sort, referenceDate: now, referenceInstant: .now, query: "",
            unassociatedPaneLocations: [
                .init(
                    paneId: paneId, tabId: UUIDv7.generate(), tabIndex: 0,
                    paneIndexInTab: 0, isActiveInTab: false)
            ])

        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts([paneId: facts], snapshot: snapshot)
        let transitions = RepoExplorerProjectionWorker.sidebarPresentationTransitions(prepared, snapshot: snapshot)
        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: prepared)
        let row = try #require(projection.paneRowsByGroupId.values.flatMap { $0 }.first)
        let message = try #require(
            row.variants?.compact.lines.compactMap { rowLine -> RepoExplorerPaneContextLine? in
                if case .agentLine(let value) = rowLine { return value }
                return nil
            }.first)

        #expect(message.ageText == "2 min ago")
        #expect(transitions == [paneId: written.addingTimeInterval(180)])
        #expect(row.recencyText == "—")
        #expect(!row.isActive)
        #expect(prepared[paneId]?.paneActivityTime == nil)
        #expect(prepared[paneId]?.contextDisplay == display)
        #expect(row.destination.paneId == paneId)
    }
}
