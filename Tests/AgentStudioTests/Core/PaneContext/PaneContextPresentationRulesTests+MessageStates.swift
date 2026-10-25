import Foundation
import Testing

@testable import AgentStudioCore

extension PaneContextPresentationRulesTests {
    struct MessageStateOracle: Sendable {
        let importance: MessageImportance
        let shape: AgentMessageShape
        let group: MessageGroupKind?
        let label: String?
        let actions: RowActionAvailability
    }

    static let messageStates: [MessageStateOracle] = [
        .init(importance: .info, shape: .notice(.unread), group: .info, label: nil, actions: .noticeActions),
        .init(importance: .done, shape: .notice(.unread), group: .done, label: nil, actions: .noticeActions),
        .init(importance: .attention, shape: .notice(.unread), group: .needsYou, label: nil, actions: .noticeActions),
        .init(importance: .failure, shape: .notice(.unread), group: .needsYou, label: nil, actions: .noticeActions),
        .init(importance: .info, shape: .notice(.read), group: .info, label: nil, actions: .noticeActions),
        .init(importance: .done, shape: .notice(.read), group: .done, label: nil, actions: .noticeActions),
        .init(importance: .attention, shape: .notice(.read), group: .resolved, label: "Read", actions: .noticeActions),
        .init(importance: .failure, shape: .notice(.read), group: .resolved, label: "Read", actions: .noticeActions),
        .init(
            importance: .info, shape: .notice(.withdrawn), group: .resolved, label: "Withdrawn by the agent",
            actions: .none),
        .init(
            importance: .done, shape: .notice(.withdrawn), group: .resolved, label: "Withdrawn by the agent",
            actions: .none),
        .init(
            importance: .attention, shape: .notice(.withdrawn), group: .resolved, label: "Withdrawn by the agent",
            actions: .none),
        .init(
            importance: .failure, shape: .notice(.withdrawn), group: .resolved, label: "Withdrawn by the agent",
            actions: .none),
        .init(importance: .info, shape: .notice(.dismissed), group: nil, label: nil, actions: .none),
        .init(importance: .done, shape: .notice(.dismissed), group: nil, label: nil, actions: .none),
        .init(importance: .attention, shape: .notice(.dismissed), group: nil, label: nil, actions: .none),
        .init(importance: .failure, shape: .notice(.dismissed), group: nil, label: nil, actions: .none),
    ]

    @Test("Every E5 notice state uses its literal group, label and actions", arguments: messageStates)
    func noticeStateTable(_ oracle: MessageStateOracle) {
        let message = messageDetail(importance: oracle.importance, shape: oracle.shape)
        #expect(PaneContextPresentationRules.messageGroup(for: message) == oracle.group)
        #expect(PaneContextPresentationRules.settledLabel(message) == oracle.label)
        #expect(PaneContextPresentationRules.rowActionAvailability(message) == oracle.actions)
    }

    struct AskStateOracle: Sendable {
        let state: AskState
        let group: MessageGroupKind
        let label: String?
        let actions: RowActionAvailability
    }

    static let askStates: [AskStateOracle] = [
        .init(state: .open, group: .needsYou, label: nil, actions: .askForm),
        .init(
            state: .answered(by: .localUser, value: .text("blue"), receipt: .notYetConfirmed),
            group: .resolved, label: "Answer sent, waiting for the agent", actions: .none),
        .init(
            state: .answered(by: .localUser, value: .text("blue"), receipt: .confirmed(at: .distantPast)),
            group: .resolved, label: "Answered: blue", actions: .none),
        .init(
            state: .answered(by: .localUser, value: .text("blue"), receipt: .unconfirmed),
            group: .resolved, label: "Answer sent; the agent didn't confirm it", actions: .none),
        .init(state: .handedBack, group: .resolved, label: "Handed back to the agent", actions: .none),
        .init(state: .dismissed, group: .resolved, label: "Dismissed", actions: .none),
        .init(state: .expired, group: .resolved, label: "Expired", actions: .none),
        .init(state: .withdrawn, group: .resolved, label: "Withdrawn by the agent", actions: .none),
        .init(state: .stale, group: .resolved, label: "No longer current", actions: .none),
    ]

    @Test("Every E5 ask state uses its literal group, receipt label and actions", arguments: askStates)
    func askStateTable(_ oracle: AskStateOracle) {
        let message = messageDetail(
            importance: .attention, shape: .ask(.question, .freeText(placeholder: nil), .nonBlocking, oracle.state))
        #expect(PaneContextPresentationRules.messageGroup(for: message) == oracle.group)
        #expect(PaneContextPresentationRules.settledLabel(message) == oracle.label)
        #expect(PaneContextPresentationRules.rowActionAvailability(message) == oracle.actions)
    }

    @Test("Confirmed choices display option labels, preserving selected order")
    func confirmedChoiceSummaryUsesLabels() throws {
        let red = try AskChoiceId("red-id")
        let blue = try AskChoiceId("blue-id")
        let form = AskForm.choice(
            options: [.init(id: red, label: "Red"), .init(id: blue, label: "Blue")], allowsMultiple: true)
        let state = AskState.answered(
            by: .localUser, value: .choices([blue, red]), receipt: .confirmed(at: .distantPast))
        let message = messageDetail(importance: .attention, shape: .ask(.question, form, .nonBlocking, state))
        #expect(PaneContextPresentationRules.settledLabel(message) == "Answered: Blue, Red")
    }

    private func messageDetail(importance: MessageImportance, shape: AgentMessageShape) -> AgentMessageDetail {
        let source = PaneId.generateUUIDv7()
        return AgentMessageDetail(
            id: .generateUUIDv7(), sourcePaneId: source, sender: .pane(source), sentAt: .distantPast,
            sourceOccurredAt: nil, importance: importance, body: "Message", why: nil, actions: [], shape: shape)
    }
}
