import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane context presentation rules")
struct PaneContextPresentationRulesTests {
    struct AgeOracle: Sendable {
        let seconds: Double
        let words: String
        let compact: String
        let next: Double
    }

    static let ages: [AgeOracle] = [
        .init(seconds: -5, words: "Now", compact: "Now", next: 60),
        .init(seconds: 59, words: "Now", compact: "Now", next: 60),
        .init(seconds: 60, words: "1 min ago", compact: "1m", next: 120),
        .init(seconds: 3540, words: "59 min ago", compact: "59m", next: 3600),
        .init(seconds: 3600, words: "1 hr ago", compact: "1h", next: 7200),
        .init(seconds: 82_800, words: "23 hr ago", compact: "23h", next: 86_400),
        .init(seconds: 86_400, words: "1 day ago", compact: "1d", next: 172_800),
        .init(seconds: 172_800, words: "2 days ago", compact: "2d", next: 259_200),
        .init(seconds: 691_200, words: "8 days ago", compact: "8d", next: 777_600),
    ]

    @Test("V4 ages keep exact words and the next boundary forever", arguments: ages)
    func ageWordsAndDeadlines(_ oracle: AgeOracle) {
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        let now = written.addingTimeInterval(oracle.seconds)
        let age = PaneContextPresentationRules.age(referenceDate: written, now: now)
        #expect(age.text == oracle.words)
        #expect(age.nextChange == written.addingTimeInterval(oracle.next))
        #expect(age.nextChange > now)
        #expect(PaneContextPresentationRules.compactAge(referenceDate: written, now: now) == oracle.compact)
        #expect(PaneContextPresentationRules.agentLineAge(referenceDate: written, now: now) == "[\(oracle.words)]")
    }

    @Test("O13 chips preserve every positive kind in urgency order and omit zeros")
    func kindChipsPreserveInfoAndOrder() {
        let counts = PaneMessageKindCounts(failure: 2, needsYou: 3, done: 4, info: 5)
        let chips = PaneContextPresentationRules.kindChips(counts)
        #expect(chips.map(\.kind) == [.failure, .needsYou, .done, .info])
        #expect(chips.map(\.count) == [2, 3, 4, 5])
        #expect(counts.unread == 14)
        #expect(PaneContextPresentationRules.kindChips(.zero).isEmpty)
        #expect(
            PaneContextPresentationRules.kindChips(.init(failure: 0, needsYou: 0, done: 0, info: 1)).map(\.kind)
                == [.info])
    }

    @Test(
        "O5 admits live and ended evidence and rejects a non-unknown claim",
        arguments: [
            StatusEvidence.verifiedLive, .verifiedEnded, .unverified, .none,
        ])
    func statusEvidenceGate(evidence: StatusEvidence) {
        let status = PaneContextPresentationRules.statusLine(
            .init(status: .idle(.ended), evidence: evidence))
        switch evidence {
        case .verifiedLive, .verifiedEnded: #expect(status?.text == "Idle · ended")
        case .unverified, .none: #expect(status == nil)
        }
        #expect(PaneContextPresentationRules.statusLine(.init(status: .unknown, evidence: evidence)) == nil)
        let prompt = CompactProviderPrompt(
            reason: .question, summary: "Use staging?", observedAt: .distantPast, omittedOrFurtherCount: 0)
        let withPrompt = PaneContextPresentationRules.statusLine(
            .init(status: .idle(.ended), evidence: evidence, compactPrompt: prompt))
        switch evidence {
        case .verifiedLive: #expect(withPrompt?.text == "Needs you · question: Use staging?")
        case .verifiedEnded: #expect(withPrompt?.text == "Idle · ended")
        case .unverified, .none: #expect(withPrompt == nil)
        }
    }

    struct StatusOracle: Sendable {
        let status: AgentSessionStatus
        let text: String?
        let kind: StatusLine.Kind?
    }

    static let statuses: [StatusOracle] = [
        .init(status: .working(.active), text: "Working", kind: .working),
        .init(status: .working(.monitoring), text: "Working · monitoring", kind: .monitoring),
        .init(status: .needsYou(.approval), text: "Needs you · approval", kind: .needsYou),
        .init(status: .needsYou(.question), text: "Needs you · question", kind: .needsYou),
        .init(status: .needsYou(.blocked), text: "Needs you · blocked", kind: .needsYou),
        .init(status: .failed(.init(category: "")), text: "Failed", kind: .failed),
        .init(status: .failed(.init(category: "Build")), text: "Failed · Build", kind: .failed),
        .init(status: .idle(.done), text: "Idle · done", kind: .idle),
        .init(status: .idle(.ready), text: "Idle · ready", kind: .idle),
        .init(status: .idle(.interrupted), text: "Idle · interrupted", kind: .idle),
        .init(status: .idle(.ended), text: "Idle · ended", kind: .idle),
        .init(status: .unknown, text: nil, kind: nil),
    ]

    @Test("Known status vocabulary comes from the catalog", arguments: statuses)
    func statusVocabulary(_ oracle: StatusOracle) {
        let line = PaneContextPresentationRules.statusLine(.init(status: oracle.status, evidence: .verifiedLive))
        #expect(line?.text == oracle.text)
        #expect(line?.kind == oracle.kind)
    }

    @Test("F03 literal synthetic prompt table controls status and card duplication")
    func syntheticPromptStatusAndCardTable() {
        let source = PaneId.generateUUIDv7()
        let question = CompactProviderPrompt(
            reason: .question, summary: "Use staging DB?", observedAt: .distantPast, omittedOrFurtherCount: 1)
        let approval = CompactProviderPrompt(
            reason: .approval, summary: "Allow write to ~/.zshrc?", observedAt: .distantPast, omittedOrFurtherCount: 2)
        for (reducer, prompt, expected) in [
            (AgentSessionStatus.needsYou(.approval), approval, "Needs you · approval: Allow write to ~/.zshrc?"),
            (.needsYou(.approval), question, "Needs you · question: Use staging DB?"),
            (.working(.active), question, "Needs you · question: Use staging DB?"),
        ] {
            let line = PaneContextPresentationRules.statusLine(
                .init(status: reducer, evidence: .verifiedLive, compactPrompt: prompt))
            #expect(line?.text == expected)
            #expect(line?.kind == .needsYou)
            #expect(
                PaneContextPresentationRules.cardStatusChip(line, selection: .providerPrompt(source: source, prompt))?
                    .text == (prompt.reason == .question ? "Needs you · question" : "Needs you · approval"))
            #expect(
                PaneContextPresentationRules.cardStatusChip(
                    line, selection: .ask(source: source, message: .generateUUIDv7()))?.text == expected)
        }
        let withoutSummary = CompactProviderPrompt(
            reason: .approval, summary: nil, observedAt: .distantPast, omittedOrFurtherCount: 0)
        #expect(
            PaneContextPresentationRules.statusLine(
                .init(status: .working(.active), evidence: .verifiedLive, compactPrompt: withoutSummary))?.text
                == "Needs you · approval")
        #expect(
            PaneContextPresentationRules.statusLine(
                .init(status: .working(.active), evidence: .verifiedLive),
                scopedPrompt: (source, withoutSummary))?.text == "Needs you · approval")
    }

    @Test("F15 scope picks the newest live prompt with main/drawer tie order")
    func scopedPromptKeepsSourceAndEvidence() {
        let main = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let latest = CompactProviderPrompt(
            reason: .question, summary: "Drawer question", observedAt: .distantPast.addingTimeInterval(2),
            omittedOrFurtherCount: 0)
        let older = CompactProviderPrompt(
            reason: .approval, summary: "Main approval", observedAt: .distantPast,
            omittedOrFurtherCount: 0)
        let selected = PaneContextPresentationRules.scopedCompactPrompt([
            (main, .init(status: .working(.active), evidence: .verifiedLive, compactPrompt: older)),
            (drawer, .init(status: .needsYou(.question), evidence: .verifiedLive, compactPrompt: latest)),
        ])
        #expect(selected?.source == drawer)
        #expect(selected?.prompt == latest)
        let tie = PaneContextPresentationRules.scopedCompactPrompt([
            (main, .init(status: .working(.active), evidence: .verifiedLive, compactPrompt: latest)),
            (drawer, .init(status: .needsYou(.question), evidence: .verifiedLive, compactPrompt: latest)),
        ])
        #expect(tie?.source == main)
        #expect(
            PaneContextPresentationRules.scopedCompactPrompt([
                (main, .init(status: .working(.active), evidence: .unverified, compactPrompt: latest))
            ]) == nil)
    }

    @Test("O20 toolbar chooses chips, otherwise the Agent Line, otherwise nothing")
    func toolbarSelectionIsExclusive() {
        let line = AgentLineDetail(
            summary: "Running tests", refs: [], writer: .pane(.generateUUIDv7()), updatedAt: .distantPast)
        let counts = PaneMessageKindCounts(failure: 0, needsYou: 0, done: 0, info: 1)
        guard
            case .chips(let chips) = PaneContextPresentationRules.toolbarSelection(
                counts: counts, agentLine: line, now: .distantPast)
        else {
            Issue.record("Unread info must replace the toolbar Agent Line")
            return
        }
        #expect(chips.map(\.kind) == [.info])
        guard
            case .agentLine(let text, let age) = PaneContextPresentationRules.toolbarSelection(
                counts: .zero, agentLine: line, now: .distantPast)
        else {
            Issue.record("The cleared toolbar must show its Agent Line")
            return
        }
        #expect(text == "Running tests")
        #expect(age.text == "Now")
        #expect(
            PaneContextPresentationRules.toolbarSelection(counts: .zero, agentLine: nil, now: .distantPast) == .none)
        #expect(
            PaneContextPresentationRules.activityChip(agentLine: line, activity: .distantPast, now: .distantPast) == nil
        )
        #expect(PaneContextPresentationRules.activityChip(agentLine: nil, activity: nil, now: .distantPast) == nil)
        #expect(
            PaneContextPresentationRules.activityChip(
                agentLine: nil, activity: .distantPast, now: .distantPast.addingTimeInterval(60))?.text == "1m")
    }

    @Test("O6 title normalization strips spinners and preserves semantic titles", arguments: ["✳", "⠃", "⠋"])
    func displayTitleRemovesLeadingSpinners(spinner: String) {
        #expect(
            PaneContextPresentationRules.displayTitle(
                raw: "\(spinner) Running tests", cwd: nil, shell: "/bin/zsh") == "Running tests")
        #expect(
            PaneContextPresentationRules.displayTitle(
                raw: "/tmp/project", agentTitle: "\(spinner) Agent title", cwd: nil, shell: "/bin/zsh") == "Agent title"
        )
        #expect(PaneContextPresentationRules.displayTitle(raw: "", cwd: nil, shell: "/bin/fish") == "fish")
        #expect(PaneContextPresentationRules.displayTitle(raw: "~/project", cwd: nil, shell: nil) == "zsh")
    }
}
