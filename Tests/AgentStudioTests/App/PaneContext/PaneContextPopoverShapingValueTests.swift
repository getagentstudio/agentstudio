import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

struct PaneContextPopoverShapingValueTests {
    struct FormScenario {
        let form: AskForm
        let expectedForm: AskFormModel
        let answer: AskAnswerValue
        let expectedAnswer: AskAnswerModel
    }
    @Test
    func formsKeepTheirControlsConstraintsAndAnswerReceipts() async throws {
        let paneId = PaneId.generateUUIDv7()
        let choiceId = try AskChoiceId("allow")
        let schema = ElicitationSchema(
            properties: [
                .init(
                    name: "name", title: "Name", description: "Contact",
                    type: .string(
                        .init(
                            choices: ["a", "b"], minLength: 1, maxLength: 8, format: nil))),
                .init(name: "amount", title: nil, description: nil, type: .number(.init(minimum: 1, maximum: 5))),
                .init(name: "count", title: nil, description: nil, type: .integer(.init(minimum: 2, maximum: 6))),
                .init(name: "enabled", title: nil, description: nil, type: .boolean),
            ], required: ["name", "count"])
        let cases: [FormScenario] = [
            .init(
                form: .choice(options: [.init(id: choiceId, label: "Allow")], allowsMultiple: false),
                expectedForm: .choice(
                    options: [
                        .init(
                            id: "allow", label: "Allow",
                            control: .init(
                                identifier: "pane-context.choice.allow", label: "Allow",
                                icon: .system("checkmark.circle"),
                                tooltip: .init(text: "Allow", shortcutDisplayText: nil)))
                    ], allowsMultiple: false),
                answer: .choices([choiceId]), expectedAnswer: .choices(["allow"])),
            .init(
                form: .choice(options: [.init(id: choiceId, label: "Allow")], allowsMultiple: true),
                expectedForm: .choice(
                    options: [
                        .init(
                            id: "allow", label: "Allow",
                            control: .init(
                                identifier: "pane-context.choice.allow", label: "Allow",
                                icon: .system("checkmark.circle"),
                                tooltip: .init(text: "Allow", shortcutDisplayText: nil)))
                    ], allowsMultiple: true),
                answer: .choices([choiceId]), expectedAnswer: .choices(["allow"])),
            .init(
                form: .freeText(placeholder: "Reply"), expectedForm: .freeText(placeholder: "Reply"),
                answer: .text("Yes"), expectedAnswer: .text("Yes")),
            .init(
                form: .elicitation(schema),
                expectedForm: .elicitation([
                    .init(
                        name: "name", title: "Name", description: "Contact", required: true,
                        kind: .string(choices: ["a", "b"], minLength: 1, maxLength: 8, format: nil)),
                    .init(
                        name: "amount", title: nil, description: nil, required: false,
                        kind: .number(minimum: 1, maximum: 5)),
                    .init(
                        name: "count", title: nil, description: nil, required: true,
                        kind: .integer(minimum: 2, maximum: 6)),
                    .init(name: "enabled", title: nil, description: nil, required: false, kind: .boolean),
                ]),
                answer: .form(
                    .init(properties: [
                        "name": .string("a"), "amount": .number(3), "count": .integer(4), "enabled": .boolean(true),
                    ])),
                expectedAnswer: .form([
                    "name": .string("a"), "amount": .number(3), "count": .integer(4), "enabled": .boolean(true),
                ])),
        ]
        let receipts: [(AnswerReceipt, AnswerReceiptModel)] = [
            (.notYetConfirmed, .notYetConfirmed),
            (.confirmed(at: Date(timeIntervalSince1970: 4)), .confirmed(at: Date(timeIntervalSince1970: 4))),
            (.unconfirmed, .unconfirmed),
        ]
        for scenario in cases {
            for (receipt, expectedReceipt) in receipts {
                let message = try PaneContextPopoverShapingTests.message(
                    paneId: paneId,
                    shape: .ask(
                        .approval, scenario.form, .blocking(deadline: Date(timeIntervalSince1970: 100)),
                        .answered(by: .localUser, value: scenario.answer, receipt: receipt)), importance: .info)
                let row = try await PaneContextPopoverShapingTests.onlyRow(message)
                #expect(
                    row.shape
                        == .ask(
                            reason: .approval, form: scenario.expectedForm,
                            waiting: .blocking(deadline: Date(timeIntervalSince1970: 100)),
                            state: .answered(by: .localUser, value: scenario.expectedAnswer, receipt: expectedReceipt)))
                #expect(!row.isOutstanding)
            }
        }
    }

    @Test
    func agentLineReferencesAttributionAndProviderPromptCutsArePreserved() async throws {
        let paneId = PaneId.generateUUIDv7()
        let generation = UUIDv7.generate()
        let updatedAt = Date(timeIntervalSince1970: 2)
        let expiry = Date(timeIntervalSince1970: 5)
        let identity = try ForgePullRequestIdentity(host: "github.com", owner: "org", repository: "repo", number: 7)
        let sender = AgentMessageSender.session(
            provider: try .init("codex"), sessionRef: try .init("session"), bindingGeneration: generation)
        let works: [(AgentLineWork, AgentLineWorkModel)] = [
            (.working(.indeterminate), .working(.indeterminate)),
            (.working(.step(current: 2, total: 5)), .working(.step(current: 2, total: 5))),
            (.monitoring("CI"), .monitoring("CI")),
            (.blockedOnYou(action: "Reply"), .blockedOnYou(action: "Reply")),
            (.done, .done),
            (.failed(summary: "Failed"), .failed(summary: "Failed")),
        ]
        for (work, expectedWork) in works {
            let shape = await PaneContextPopoverShaping.shape(
                PaneContextPopoverShapingTests.detail(
                    paneId: paneId,
                    line: .init(
                        summary: "Summary", work: work, detail: "Detail",
                        refs: [.openFile(path: "file.swift", line: 3), .goToPane(paneId), .openPullRequest(identity)],
                        writer: sender, updatedAt: updatedAt, lifetime: .expires(at: expiry), stale: true),
                    session: .init(
                        id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init("session"),
                        bindingGeneration: generation, status: .needsYou(.question),
                        providerPrompts: [
                            .init(reason: .question, observedAt: updatedAt, summary: "Provider question")
                        ],
                        omittedPromptCount: 5)), sourceTitles: [:])
            #expect(
                shape.agentLine
                    == .init(
                        summary: "Summary", work: expectedWork, detail: "Detail",
                        refs: [
                            .openFile(path: "file.swift", line: 3), .goToPane(paneId.uuid),
                            .openPullRequest(.init(host: "github.com", owner: "org", repository: "repo", number: 7)),
                        ],
                        writer: .session(provider: "codex", sessionRef: "session", bindingGeneration: generation),
                        updatedAt: updatedAt, lifetime: .expires(at: expiry), stale: true))
            #expect(
                shape.providerPrompts
                    == .init(
                        prompts: [.init(reason: .question, observedAt: updatedAt, summary: "Provider question")],
                        omittedPromptCount: 5))
        }
    }

}
