import AgentStudioCore
import Foundation
import Testing

@Suite("Agent message attention type")
struct AgentMessageAttentionTypeTests {
    @Test("Every notice state follows its importance", arguments: noticeStates, noticeImportanceTable)
    func noticeType(state: NoticeState, scenario: NoticeImportanceScenario) {
        #expect(
            AgentMessageAttentionType.classify(shape: .notice(state), importance: scenario.importance)
                == scenario.expected)
    }

    @Test(
        "Every ask form, state and reason follows waiting mode for every importance", arguments: askScenarios(),
        importanceValues)
    func askType(scenario: AskAttentionScenario, importance: MessageImportance) {
        let shape = AgentMessageShape.ask(scenario.reason, scenario.form, scenario.waiting, scenario.state)

        #expect(AgentMessageAttentionType.classify(shape: shape, importance: importance) == scenario.expected)
    }

    @Test("Zero counts contain no message identity")
    func zeroCounts() {
        #expect(
            PaneMessageCounts.zero
                == PaneMessageCounts(
                    needsApprovalCount: 0, needsReplyCount: 0, attentionCount: 0, informationalCount: 0,
                    newestOpenBlockingAskId: nil))
    }
}

private let noticeStates: [NoticeState] = [.unread, .read, .dismissed, .withdrawn]
private let importanceValues: [MessageImportance] = [.info, .attention, .done, .failure]
private let noticeImportanceTable = [
    NoticeImportanceScenario(importance: .info, expected: .informational),
    NoticeImportanceScenario(importance: .attention, expected: .attention),
    NoticeImportanceScenario(importance: .done, expected: .informational),
    NoticeImportanceScenario(importance: .failure, expected: .attention),
]

struct NoticeImportanceScenario: Sendable {
    let importance: MessageImportance
    let expected: AgentMessageAttentionType
}

struct AskAttentionScenario: Sendable {
    let reason: AskReason
    let form: AskForm
    let waiting: AskWaiting
    let state: AskState
    let expected: AgentMessageAttentionType
}

private func askScenarios() -> [AskAttentionScenario] {
    let forms: [AskForm] = [
        .choice(options: [], allowsMultiple: false),
        .choice(options: [], allowsMultiple: true),
        .freeText(placeholder: nil),
        .elicitation(ElicitationSchema(properties: [], required: [])),
    ]
    let states: [AskState] = [
        .open,
        .answered(by: .localUser, value: .text("answer"), receipt: .notYetConfirmed),
        .handedBack, .dismissed, .expired, .withdrawn, .stale,
    ]
    let reasons: [AskReason] = [.approval, .question, .blocked]
    let waitingTable: [(AskWaiting, AgentMessageAttentionType)] = [
        (.nonBlocking, .needsReply),
        (.blocking(deadline: Date(timeIntervalSince1970: 1_800_000_000)), .needsApproval),
    ]
    var scenarios: [AskAttentionScenario] = []
    for reason in reasons {
        for form in forms {
            for state in states {
                for (waiting, expected) in waitingTable {
                    scenarios.append(
                        AskAttentionScenario(
                            reason: reason, form: form, waiting: waiting, state: state, expected: expected))
                }
            }
        }
    }
    return scenarios
}
