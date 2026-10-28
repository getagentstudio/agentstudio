import Foundation

struct PaneMessageCountInput: Sendable {
    enum CountedState: Sendable {
        case openAsk(AskWaiting)
        case unreadNotice(MessageImportance)
        case settled
    }
    let id: AgentMessageId
    let sourcePaneId: PaneId
    let sentAt: Date
    let position: UInt64
    let displayHidden: Bool
    let state: CountedState
}

extension PaneMessageCountInput {
    init(_ message: PaneContextStoredMessage) {
        id = message.detail.id
        sourcePaneId = message.detail.sourcePaneId
        sentAt = message.detail.sentAt
        position = message.position
        displayHidden = message.displayHidden
        switch message.detail.shape {
        case .ask(_, _, let waiting, let askState):
            switch askState {
            case .open: state = .openAsk(waiting)
            case .answered, .handedBack, .dismissed, .expired, .withdrawn, .stale: state = .settled
            }
        case .notice(let noticeState):
            switch noticeState {
            case .unread: state = .unreadNotice(message.detail.importance)
            case .read, .dismissed, .withdrawn: state = .settled
            }
        }
    }
}

enum PaneMessageCountFold {
    static func summarize(messages: [PaneContextStoredMessage], sourceOrder: [PaneId]) -> PaneMessageCounts {
        summarize(inputs: messages.map(PaneMessageCountInput.init), sourceOrder: sourceOrder)
    }

    static func summarize(inputs: [PaneMessageCountInput], sourceOrder: [PaneId]) -> PaneMessageCounts {
        let sourceRanks = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
        var failure = 0
        var needsYou = 0
        var done = 0
        var info = 0
        var newest: PaneMessageCountInput?
        var oldest: PaneMessageCountInput?
        for message in inputs where !message.displayHidden && sourceRanks[message.sourcePaneId] != nil {
            switch message.state {
            case .openAsk(let waiting):
                needsYou += 1
                if oldest.map({ isOlder(message, than: $0, sourceRanks: sourceRanks) }) ?? true { oldest = message }
                if case .blocking = waiting,
                    newest.map({ isNewer(message, than: $0, sourceRanks: sourceRanks) }) ?? true
                {
                    newest = message
                }
            case .unreadNotice(let importance):
                switch importance {
                case .failure: failure += 1
                case .attention: needsYou += 1
                case .done: done += 1
                case .info: info += 1
                }
            case .settled: break
            }

        }
        return PaneMessageCounts(
            kinds: .init(failure: failure, needsYou: needsYou, done: done, info: info),
            newestOpenBlockingAskId: newest?.id,
            oldestOpenAsk: oldest.map { .init(paneId: $0.sourcePaneId, messageId: $0.id) })
    }

    private static func isOlder(
        _ candidate: PaneMessageCountInput, than current: PaneMessageCountInput, sourceRanks: [PaneId: Int]
    ) -> Bool {
        if candidate.sentAt != current.sentAt { return candidate.sentAt < current.sentAt }
        if candidate.sourcePaneId != current.sourcePaneId {
            return (sourceRanks[candidate.sourcePaneId] ?? sourceRanks.count)
                < (sourceRanks[current.sourcePaneId] ?? sourceRanks.count)
        }
        return candidate.position < current.position
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
