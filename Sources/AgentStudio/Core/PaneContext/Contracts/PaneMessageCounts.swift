package struct PaneMessageKindCounts: Sendable, Equatable {
    package let failure: Int
    package let needsYou: Int
    package let done: Int
    package let info: Int
    package var unread: Int { failure + needsYou + done + info }

    package init(failure: Int, needsYou: Int, done: Int, info: Int) {
        self.failure = failure
        self.needsYou = needsYou
        self.done = done
        self.info = info
    }

    package static let zero = Self(failure: 0, needsYou: 0, done: 0, info: 0)
}

package struct PaneMessageCounts: Sendable, Equatable {
    package let kinds: PaneMessageKindCounts
    package let newestOpenBlockingAskId: AgentMessageId?
    package let oldestOpenAsk: PaneContextMessageKey?

    package init(
        kinds: PaneMessageKindCounts,
        newestOpenBlockingAskId: AgentMessageId?,
        oldestOpenAsk: PaneContextMessageKey? = nil
    ) {
        self.kinds = kinds
        self.newestOpenBlockingAskId = newestOpenBlockingAskId
        self.oldestOpenAsk = oldestOpenAsk
    }

    package static let zero = Self(
        kinds: .zero,
        newestOpenBlockingAskId: nil,
        oldestOpenAsk: nil
    )
}
