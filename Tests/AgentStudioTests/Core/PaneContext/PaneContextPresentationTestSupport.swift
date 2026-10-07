import AgentStudioInfrastructure
import Foundation

@testable import AgentStudioCore

func presentationDisplay(
    revision: UInt64 = 1, title: String? = nil, line: AgentLineDetail? = nil,
    own: PaneMessageCounts = .zero, includingDrawers: PaneMessageCounts? = nil,
    pullRequests: PullRequestSummaryDetail = .notApplicable
) -> PaneContextDisplay {
    PaneContextDisplay(
        revision: PaneContextRevision(revision), agentTitle: title, agentLine: line,
        own: own, includingDrawers: includingDrawers ?? own, pullRequests: pullRequests)
}

func countedMessage(
    source: PaneId, position: UInt64 = 1, sentAt: Date = Date(timeIntervalSince1970: 100),
    importance: MessageImportance = .info, shape: AgentMessageShape
) throws -> PaneContextStoredMessage {
    let sender: AgentMessageSender
    if case .ask = shape {
        sender = .session(
            provider: try BridgeAgentProviderName("claude-code"),
            sessionRef: try BridgeAgentSessionRef("count-fixture"),
            bindingGeneration: UUIDv7.generate())
    } else {
        sender = .pane(source)
    }
    return PaneContextStoredMessage(
        rowId: UUIDv7.generate(), position: position,
        detail: AgentMessageDetail(
            id: .generateUUIDv7(), sourcePaneId: source, sender: sender, sentAt: sentAt,
            sourceOccurredAt: nil, importance: importance, body: "Count fixture", why: nil,
            actions: [], shape: shape),
        settledAt: nil, displayHidden: false)
}

struct PaneMessageCountCase: Sendable {
    let shape: AgentMessageShape
    let importance: MessageImportance
    let expectedType: AgentMessageAttentionType?
}

let paneMessageCountCases: [PaneMessageCountCase] = {
    let importance: [MessageImportance] = [.info, .attention, .done, .failure]
    let reasons: [AskReason] = [.approval, .question, .blocked]
    let waiting: [AskWaiting] = [.nonBlocking, .blocking(deadline: Date(timeIntervalSince1970: 200))]
    let states: [AskState] = [
        .open, .answered(by: .localUser, value: .text("answer"), receipt: .notYetConfirmed),
        .handedBack, .dismissed, .expired, .withdrawn, .stale,
    ]
    let noticeStates: [NoticeState] = [.unread, .read, .dismissed, .withdrawn]
    var cases: [PaneMessageCountCase] = []
    for state in noticeStates {
        for level in importance {
            let category: AgentMessageAttentionType?
            if state == .unread {
                category = level == .attention || level == .failure ? .attention : .informational
            } else {
                category = nil
            }
            cases.append(.init(shape: .notice(state), importance: level, expectedType: category))
        }
    }
    for reason in reasons {
        for mode in waiting {
            for state in states {
                for level in importance {
                    let category: AgentMessageAttentionType?
                    if state == .open {
                        if case .blocking = mode { category = .needsApproval } else { category = .needsReply }
                    } else {
                        category = nil
                    }
                    cases.append(
                        .init(
                            shape: .ask(reason, .freeText(placeholder: nil), mode, state), importance: level,
                            expectedType: category))
                }
            }
        }
    }
    return cases
}()
