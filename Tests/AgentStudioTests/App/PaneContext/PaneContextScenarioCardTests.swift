import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@Suite("V3 literal card projections")
struct PaneContextScenarioCardTests {
    @Test(
        "synthetic-input summary stays in status while its provider request is loading or unavailable",
        arguments: [false, true])
    func syntheticPromptSummaryStaysUntilTheBlockIsVisible(failed: Bool) async throws {
        let scenario = try #require(PaneContextScenario.all.first { $0.id == "S16a-synthetic-input" })
        let facts = try await PaneContextScenarioFacts.make(scenario)
        var input = PaneManagementIdentityCapture.LineInput(
            paneId: facts.owner.uuid, terminalTitle: "Card",
            cwd: nil, shellExecutablePath: nil, agentTitle: nil, note: nil, isDrawer: false,
            agentLine: nil, sessionPresentation: facts.presentation,
            contextDisplay: .init(
                revision: .init(1), agentTitle: nil, agentLine: nil,
                own: facts.own, includingDrawers: facts.scoped, pullRequests: .notApplicable),
            scopedPresentations: [.init(source: facts.owner, presentation: facts.presentation)])
        input.cardUnavailable = failed
        if failed {
            let detail = try PaneContextScenarioPopoverTests.detail(scenario, facts: facts)
            input.detailMessages = await PaneContextPopoverShaping.shape(
                detail, sourceTitles: [:], counts: facts.scoped.kinds, now: facts.now
            )
            .messages
        }
        let card = await CardProjection.project(input, now: facts.now, information: .init(lines: [.title("Card")]))
        #expect(card.statusChip?.text == "Needs you · approval: Allow write to ~/.zshrc?")
        #expect(
            card.information.lines.compactMap { if case .sessionStatus(let line) = $0 { line.text } else { nil } }
                == ["Needs you · approval: Allow write to ~/.zshrc?"])
        #expect(card.unreadCount == 0)
    }
    @Test(
        "real fold and Sessions publication reach the card",
        arguments: (PaneContextScenario.all + PaneContextScenario.evidenceCases).filter {
            !$0.isSyntheticPromptInput
        })
    func sourceFactsReachCard(_ scenario: PaneContextScenario) async throws { try await assertCard(scenario) }

    @Test(
        "G07/G08 synthetic-input card prompts; no producer claim",
        arguments:
            PaneContextScenario.all.filter(\.isSyntheticPromptInput))
    func syntheticInputCardPrompts(_ scenario: PaneContextScenario) async throws { try await assertCard(scenario) }

    private func assertCard(_ scenario: PaneContextScenario) async throws {
        let facts = try await PaneContextScenarioFacts.make(scenario)
        let detail = try PaneContextScenarioPopoverTests.detail(scenario, facts: facts)
        let popover = await PaneContextPopoverShaping.shape(
            detail, sourceTitles: [facts.drawer: "tests"], counts: facts.scoped.kinds, now: facts.now)
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: facts.line,
            own: facts.own, includingDrawers: facts.scoped, pullRequests: .notApplicable)
        var input = PaneManagementIdentityCapture.LineInput(
            paneId: facts.owner.uuid,
            terminalTitle: "✳ " + PaneContextScenario.title, cwd: nil, shellExecutablePath: nil,
            agentTitle: nil, note: nil, isDrawer: false, agentLine: facts.line,
            sessionPresentation: facts.presentation,
            activityTime: .init(orderingInstant: .now, wallTime: facts.activityDate, source: .hook),
            contextDisplay: display,
            scopedPresentations: [.init(source: facts.owner, presentation: facts.presentation)])
        input.detailMessages = popover.messages
        let information = PaneManagementIdentityCapture.Presentation(
            lines: await PaneManagementIdentityCapture.lines(input, now: facts.now))
        let card = await CardProjection.project(input, now: facts.now, information: information)
        #expect(card.statusChip?.text == scenario.expected.cardStatus)
        #expect(
            card.information.lines.compactMap { if case .sessionStatus(let line) = $0 { line.text } else { nil } }
                == scenario.expected.cardStatus.map { [$0] } ?? [])
        #expect(card.unreadCount == scenario.expected.counts.unread)
        #expect(
            card.information.lines.compactMap { if case .agentLine(let line) = $0 { line.text } else { nil } }.first
                == scenario.expected.agentLine)
        #expect(card.activityText == expectedActivity(scenario.id))
    }

    private func expectedActivity(_ id: String) -> String {
        switch id {
        case "S1": "1 min ago"
        case "S12": "9 min ago"
        default: "Now"
        }
    }
}
