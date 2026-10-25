import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@Suite("V3 literal pane context scenario projections")
struct PaneContextScenarioProjectionTests {
    @Test(
        "S1–S19 sidebar and toolbar from the real fold and Sessions publication; approval driver lands at P6",
        arguments: PaneContextScenario.all.filter { $0.id != "S15" && !$0.isSyntheticPromptInput })
    func sourceFactsReachSidebarAndToolbar(_ scenario: PaneContextScenario) async throws {
        try await assertProjections(scenario)
    }

    @Test(
        "G07/G08 synthetic-input compact prompts; no real-ingress claim",
        arguments: PaneContextScenario.all.filter(\.isSyntheticPromptInput))
    func syntheticInputPromptProjections(_ scenario: PaneContextScenario) async throws {
        try await assertProjections(scenario)
    }

    private func assertProjections(_ scenario: PaneContextScenario) async throws {
        let facts = try await PaneContextScenarioFacts.make(scenario)
        try assertProjectedFacts(scenario, facts: facts)
    }

    @Test(
        "G10 four source evidence states reach compact shapers without suppressing pane-written facts",
        arguments: [
            (0, StatusEvidence.verifiedLive, AgentSessionStatus.working(.active)),
            (1, .verifiedEnded, .idle(.ended)), (2, .unverified, .working(.active)), (3, .none, .unknown),
        ])
    func sourceEvidenceGatesOnlyStatus(index: Int, evidence: StatusEvidence, status: AgentSessionStatus) async throws {
        let scenario = PaneContextScenario.evidenceCases[index]
        let facts = try await PaneContextScenarioFacts.make(scenario)
        #expect(facts.presentation.evidence == evidence)
        #expect(facts.presentation.status == status)
        try assertProjectedFacts(scenario, facts: facts)
    }

    private func assertProjectedFacts(_ scenario: PaneContextScenario, facts: PaneContextScenarioFacts) throws {
        #expect(facts.scoped.kinds == scenario.expected.counts)
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: facts.line,
            own: facts.own, includingDrawers: facts.scoped, pullRequests: .notApplicable)
        let tab = UUIDv7.generate()
        let snapshot = RepoExplorerSnapshot(
            repos: [], repoEnrichmentByRepoId: [:], surface: .panes, referenceDate: facts.now, query: "",
            unassociatedPaneLocations: [facts.owner, facts.drawer].enumerated().map { index, pane in
                .init(paneId: pane.uuid, tabId: tab, tabIndex: 0, paneIndexInTab: index, isActiveInTab: false)
            })
        let rowFacts: [UUID: RepoExplorerPaneRowFacts] = [
            facts.owner.uuid: .init(
                terminalTitle: "✳ " + PaneContextScenario.title, sessionPresentation: facts.presentation,
                ownedDrawerPaneIDs: [facts.drawer.uuid], contextDisplay: display, activityAt: facts.activityDate,
                noteText: "Card-only metadata", latestMessageText: "Private terminal output",
                recencyReferenceDate: facts.activityDate, recencyText: "unused", isActive: true),
            facts.drawer.uuid: .init(
                terminalTitle: "Drawer", latestMessageText: nil, recencyReferenceDate: .distantPast,
                recencyText: "unused", isActive: false, isDrawerPane: true, drawerOwnerPaneID: facts.owner.uuid),
        ]
        let projected = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: rowFacts)
        let row = try #require(
            projected.paneRowsByGroupId.values.flatMap { $0 }.first { $0.destination.paneId == facts.owner.uuid })
        let variant = try #require(row.variants?.compact)
        #expect(row.primaryText == "Assistant capabilities overview")
        #expect(variant.lines.first == .title("Assistant capabilities overview"))
        #expect(variant.statusLine?.text == scenario.expected.sidebarStatus)
        #expect(variant.chipModels == scenario.expected.chips)
        #expect(variant.activityChip?.text == scenario.expected.activityChip)
        let lines = variant.lines.compactMap { line -> RepoExplorerPaneContextLine? in
            if case .agentLine(let value) = line { return value }
            return nil
        }
        #expect(lines.first?.text == scenario.expected.agentLine)
        #expect(lines.first?.ageText == scenario.expected.bracketedAge)
        let expectedKinds: [RepoExplorerPaneLineKind] =
            [.title]
            + (scenario.expected.sidebarStatus == nil ? [] : [.sessionStatus])
            + (scenario.expected.agentLine == nil ? [] : [.agentLine])
        #expect(variant.lines.map(\.kind) == expectedKinds)
        #expect(row.variants?.expanded == variant)
        #expect(
            ToolbarProjection.project(display: display, isDrawer: false, now: facts.now).item
                == scenario.expected.toolbar)
    }
}
