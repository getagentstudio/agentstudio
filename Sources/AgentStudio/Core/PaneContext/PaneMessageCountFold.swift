import Foundation

struct PaneMessageCountInput: Sendable {
    let id: AgentMessageId
    let sourcePaneId: PaneId
    let sentAt: Date
    let position: UInt64
    let displayHidden: Bool
    let attention: AgentMessageAttentionType?
}

extension PaneMessageCountInput {
    init(_ message: PaneContextStoredMessage) {
        id = message.detail.id
        sourcePaneId = message.detail.sourcePaneId
        sentAt = message.detail.sentAt
        position = message.position
        displayHidden = message.displayHidden
        switch message.detail.shape {
        case .ask(_, _, _, .open), .notice(.unread):
            attention = AgentMessageAttentionType.classify(
                shape: message.detail.shape, importance: message.detail.importance)
        default: attention = nil
        }
    }
}

enum PaneMessageCountFold {
    static func summarize(messages: [PaneContextStoredMessage], sourceOrder: [PaneId]) -> PaneMessageCounts {
        summarize(inputs: messages.map(PaneMessageCountInput.init), sourceOrder: sourceOrder)
    }

    static func summarize(inputs: [PaneMessageCountInput], sourceOrder: [PaneId]) -> PaneMessageCounts {
        let sourceRanks = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
        var approvals = 0
        var replies = 0
        var attention = 0
        var informational = 0
        var newest: PaneMessageCountInput?
        for message in inputs where !message.displayHidden && sourceRanks[message.sourcePaneId] != nil {
            switch message.attention {
            case .some(.needsApproval):
                approvals += 1
                if newest.map({ isNewer(message, than: $0, sourceRanks: sourceRanks) }) ?? true {
                    newest = message
                }
            case .some(.needsReply): replies += 1
            case .some(.attention): attention += 1
            case .some(.informational): informational += 1
            case nil: break
            }

        }
        return PaneMessageCounts(
            needsApprovalCount: approvals, needsReplyCount: replies, attentionCount: attention,
            informationalCount: informational, newestOpenBlockingAskId: newest?.id)
    }

    private static func isNewer(
        _ candidate: PaneMessageCountInput, than current: PaneMessageCountInput,
        sourceRanks: [PaneId: Int]
    ) -> Bool {
        if candidate.sentAt != current.sentAt { return candidate.sentAt > current.sentAt }
        if candidate.sourcePaneId != current.sourcePaneId {
            return (sourceRanks[candidate.sourcePaneId] ?? sourceRanks.count)
                < (sourceRanks[current.sourcePaneId] ?? sourceRanks.count)
        }
        return candidate.position > current.position
    }
}
