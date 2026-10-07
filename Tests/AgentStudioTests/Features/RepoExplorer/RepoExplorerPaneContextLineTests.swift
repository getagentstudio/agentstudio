import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite
struct RepoExplorerPaneContextLineTests {
    struct StatusOracle: Sendable {
        let status: AgentSessionStatus
        let text: String?
        let icon: CommandIcon?
        let tone: PaneContextChipTone?
    }
    // Expected words and glyphs transcribed from Spec R21a, independent of the presentation function.
    static let statuses: [StatusOracle] = [
        .init(status: .needsYou(.approval), text: "Needs you · approval", icon: .system(.flag), tone: .warning),
        .init(status: .needsYou(.question), text: "Needs you · question", icon: .system(.flag), tone: .warning),
        .init(status: .needsYou(.blocked), text: "Needs you · blocked", icon: .system(.flag), tone: .warning),
        .init(
            status: .failed(.init(category: "Build")), text: "Failed · Build", icon: .system(.xmarkOctagon),
            tone: .danger),
        .init(status: .working(.active), text: "Working", icon: .system(.circleFill), tone: .success),
        .init(status: .working(.monitoring), text: "Working · monitoring", icon: .system(.circleFill), tone: .success),
        .init(status: .idle(.done), text: "Idle · done", icon: .system(.checkmark), tone: .neutral),
        .init(status: .idle(.ready), text: "Idle · ready", icon: .system(.circle), tone: .neutral),
        .init(status: .idle(.interrupted), text: "Idle · interrupted", icon: .system(.circle), tone: .neutral),
        .init(status: .idle(.ended), text: "Idle · ended", icon: .system(.circle), tone: .neutral),
        .init(status: .unknown, text: nil, icon: nil, tone: nil),
    ]
    @Test(arguments: statuses)
    func sessionLineUsesItsOwnGlyphAndWords(_ oracle: StatusOracle) {
        let line = RepoExplorerPaneContextLine.session(oracle.status)
        #expect(line?.text == oracle.text)
        #expect(line?.icon == oracle.icon)
        #expect(line?.tone == oracle.tone)
        #expect(line?.tooltip.text == oracle.text)
    }
    @Test
    func everyExistingLineShowsInBothVariantsWithIndependentAgentWork() throws {
        let line = AgentLineDetail(
            summary: "Watching CI", work: .monitoring("checks"), detail: nil, refs: [],
            writer: .session(
                provider: try .init("codex"), sessionRef: try .init("run"), bindingGeneration: UUIDv7.generate()),
            updatedAt: .distantPast, lifetime: .untilReplaced, stale: true)
        let variants = RepoExplorerPaneRowVariants.make(
            title: "Agent title", branchContext: "repo · main", note: "Review this", isDrawer: true,
            branchStatus: nil, isActive: false, agentLine: line, sessionStatus: .needsYou(.approval))
        #expect(variants.compact.lines == variants.expanded.lines)
        #expect(variants.compact.lines.count == 5)
        #expect(variants.compact.fallbackLineCount == 6)
        guard case .agentLine(let workLine) = variants.compact.lines[3],
            case .sessionStatus(let statusLine) = variants.compact.lines[4]
        else {
            Issue.record("Agent Line and Session status must remain separate ordered lines")
            return
        }
        #expect(workLine.text == "Watching CI")
        #expect(workLine.icon == .system(.circleDotted))
        #expect(workLine.tone == .info)
        #expect(workLine.stale)
        #expect(statusLine.icon == .system(.flag))
        #expect(statusLine.text == "Needs you · approval")
    }
    @Test
    func missingAndUnknownStatusHaveNoLine() {
        for status: AgentSessionStatus? in [nil, .unknown] {
            let variants = RepoExplorerPaneRowVariants.make(
                title: "Pane", branchContext: nil, note: nil, isDrawer: false,
                branchStatus: nil, isActive: false, sessionStatus: status)
            #expect(variants.compact.lines == [.title("Pane")])
            #expect(variants.compact.fallbackLineCount == 2)
        }
    }
    @Test
    func projectionKeepsDrawerStatusSeparateAndRetainsEndedStatus() throws {
        let owner = UUIDv7.generate()
        let drawer = UUIDv7.generate()
        let tab = UUIDv7.generate()
        let snapshot = RepoExplorerSnapshot(
            repos: [], repoEnrichmentByRepoId: [:], surface: .panes, query: "",
            unassociatedPaneLocations: [owner, drawer].enumerated().map { offset, pane in
                WorkspacePaneLocation(
                    paneId: pane, tabId: tab, tabIndex: 0, paneIndexInTab: offset, isActiveInTab: false)
            })
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: "Owner agent", agentLine: nil,
            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
        let ownerFacts = RepoExplorerPaneRowFacts(
            terminalTitle: "Owner terminal", sessionStatus: .working(.active), contextDisplay: display,
            latestMessageText: "Private output", recencyReferenceDate: .distantPast, recencyText: "—", isActive: false)
        let drawerFacts = RepoExplorerPaneRowFacts(
            terminalTitle: "Drawer", sessionStatus: .idle(.ended), latestMessageText: nil,
            recencyReferenceDate: .distantPast, recencyText: "—", isActive: false,
            isDrawerPane: true, drawerOwnerPaneID: owner)
        let projection = RepoExplorerProjection.project(
            snapshot, paneRowFactsByPaneId: [owner: ownerFacts, drawer: drawerFacts])
        let rows = projection.resolvedGroups.flatMap { projection.paneRowsByGroupId[$0.id] ?? [] }
        let ownerRow = try #require(rows.first { $0.destination.paneId == owner })
        let drawerRow = try #require(rows.first { $0.destination.paneId == drawer })
        #expect(ownerRow.primaryText == "Owner agent")
        #expect(
            ownerRow.variants?.compact.lines.last
                == .sessionStatus(try #require(RepoExplorerPaneContextLine.session(.working(.active)))))
        #expect(
            drawerRow.variants?.compact.lines.last
                == .sessionStatus(try #require(RepoExplorerPaneContextLine.session(.idle(.ended)))))
        #expect(drawerRow.variants?.compact.lines == drawerRow.variants?.expanded.lines)
    }

}
