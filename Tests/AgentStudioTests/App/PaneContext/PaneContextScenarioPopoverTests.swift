import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@Suite("V3 literal popover projections")
struct PaneContextScenarioPopoverTests {
    @Test(
        "real fold and Sessions publication reach Messages and Agent Line shapers",
        arguments: PaneContextScenario.all.filter { !$0.isSyntheticPromptInput })
    func sourceFactsReachPopovers(_ scenario: PaneContextScenario) async throws {
        try await assertPopovers(scenario)
    }

    @Test(
        "G07/G08 synthetic-input full prompts, with no producer or real-ingress claim",
        arguments: PaneContextScenario.all.filter(\.isSyntheticPromptInput))
    func syntheticInputFullPromptPopovers(_ scenario: PaneContextScenario) async throws {
        try await assertPopovers(scenario)
    }

    private func assertPopovers(_ scenario: PaneContextScenario) async throws {
        let facts = try await PaneContextScenarioFacts.make(scenario)
        #expect(facts.scoped.kinds == scenario.expected.counts)
        let detail = try Self.detail(scenario, facts: facts)
        let shape = await PaneContextPopoverShaping.shape(
            detail,
            sourceTitles: [facts.owner: "Owner", facts.drawer: "tests"], counts: facts.scoped.kinds, now: facts.now)
        #expect(shape.messages.groups.map { $0.kind.title } == scenario.expected.groups)
        #expect(shape.agentLine?.summary == scenario.expected.agentLine)
        #expect(shape.agentLine?.age.text == scenario.expected.bracketedAge)
        let rows = shape.messages.messageRows
        #expect(rows.map(\.body) == expectedBodies(scenario.id))
        if let label = scenario.expected.settledLabel { #expect(rows.first?.settledLabel == label) }
        if scenario.id == "S11" { #expect(rows.last?.sourceLabel == "tests") }
        if scenario.id == "S15" {
            guard case .ask(.approval, .approval(let approve, let deny, let reason), _, .open)? = rows.first?.shape
            else {
                Issue.record("S15 must show the approval form")
                return
            }
            #expect(approve.label == "Approve")
            #expect(deny.label == "Deny")
            #expect(reason.label == "Reason (optional)")
        }
        if scenario.id == "S8" {
            #expect(
                rows.first?.actions == [
                    .openFile(path: "Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion.swift", line: 142)
                ])
        }
        if scenario.id == "S19" {
            #expect(
                rows.map(\.settledLabel) == [
                    "Read", "Withdrawn by the agent",
                    "Answer sent; the agent didn't confirm it", "Dismissed",
                ])
            #expect(rows.map(\.availability) == [.noticeActions, .none, .none, .none])
            #expect(rows.map(\.isDimmed) == [true, false, false, false])
        }
        let prompts = PaneContextPopoverShapingTests.prompts(shape)
        switch scenario.prompts {
        case .absent: #expect(prompts.isEmpty)
        case .approvalWithoutSummary:
            #expect(prompts.map(\.reasonText) == ["Needs you · approval"])
            #expect(prompts.map(\.summary) == [nil])
            #expect(shape.messages.groups.first?.omittedPromptCount == 0)
        case .syntheticApprovalSummary:
            #expect(prompts.map(\.summary) == ["Allow write to ~/.zshrc?"])
            #expect(shape.messages.groups.first?.omittedPromptCount == 0)
        case .syntheticTwoListedOneOmitted:
            #expect(prompts.map(\.summary) == ["Allow write to ~/.zshrc?", "Use staging DB?"])
            #expect(prompts.map(\.reasonText) == ["Needs you · approval", "Needs you · question"])
            #expect(shape.messages.groups.first?.omittedPromptCount == 1)
        }
    }

    static func detail(_ scenario: PaneContextScenario, facts: PaneContextScenarioFacts) throws -> PaneContextDetail {
        let own = facts.messages.map(\.detail).filter { $0.sourcePaneId == facts.owner }
        let drawer = facts.messages.map(\.detail).filter { $0.sourcePaneId == facts.drawer }
        var session = facts.session
        if scenario.isSyntheticPromptInput {
            let current = try #require(session)
            let prompts: [SessionProviderPromptSummary] =
                scenario.id == "S18-synthetic-input"
                ? [
                    .init(reason: .approval, observedAt: facts.now, summary: "Allow write to ~/.zshrc?"),
                    .init(reason: .question, observedAt: facts.now.addingTimeInterval(-1), summary: "Use staging DB?"),
                ] : [.init(reason: .approval, observedAt: facts.now, summary: "Allow write to ~/.zshrc?")]
            session = .init(
                id: current.id, provider: current.provider, sessionRef: current.sessionRef,
                bindingGeneration: current.bindingGeneration, status: current.status, providerPrompts: prompts,
                omittedPromptCount: scenario.id == "S18-synthetic-input" ? 1 : 0)
        }
        return PaneContextPopoverShapingTests.detail(
            paneId: facts.owner, messages: own,
            drawers: [.init(sourcePaneId: facts.drawer, messages: drawer)], line: facts.line,
            scopedSessions: [
                .init(sourcePaneId: facts.owner, session: session),
                .init(sourcePaneId: facts.drawer, session: nil),
            ])
    }

    private func expectedBodies(_ id: String) -> [String] {
        switch id {
        case "S5", "S13": ["Branch rebased onto main"]
        case "S6": ["Tests passed (412)", "Branch rebased onto main"]
        case "S7": ["Review the migration plan before I apply it", "Tests passed (412)", "Branch rebased onto main"]
        case "S8", "S11":
            [
                "Build failed: 3 errors in SessionsIngestion.swift",
                "Review the migration plan before I apply it", "Tests passed (412)", "Branch rebased onto main",
            ]
        case "S9", "S10-pending", "S10-confirmed": ["Pick a color for the test?"]
        case "S14": ["Which suites should I rerun?"]
        case "S15": ["Approve running the migration?"]
        case "S17":
            [
                """
                Build failed while compiling the Sessions module.
                SessionsIngestion.swift:142: generic parameter 'Clock' could not be inferred.
                The build stopped before running the test bundle.
                No application files were changed by this failure.
                Review the diagnostic and update the affected call site.
                Then run the focused test lane again.
                """
            ]
        case "S19":
            [
                "Build failed: 3 errors in SessionsIngestion.swift", "Branch rebased onto main",
                "Pick a color for the test?", "Review the migration plan before I apply it",
            ]
        default: []
        }
    }
}
