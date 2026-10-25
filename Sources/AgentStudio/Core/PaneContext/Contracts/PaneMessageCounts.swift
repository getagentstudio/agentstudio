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
    package let needsApprovalCount: Int
    package let needsReplyCount: Int
    package let attentionCount: Int
    package let informationalCount: Int
    package let newestOpenBlockingAskId: AgentMessageId?

    package init(
        needsApprovalCount: Int,
        needsReplyCount: Int,
        attentionCount: Int,
        informationalCount: Int,
        newestOpenBlockingAskId: AgentMessageId?
    ) {
        self.needsApprovalCount = needsApprovalCount
        self.needsReplyCount = needsReplyCount
        self.attentionCount = attentionCount
        self.informationalCount = informationalCount
        self.newestOpenBlockingAskId = newestOpenBlockingAskId
    }

    package static let zero = Self(
        needsApprovalCount: 0,
        needsReplyCount: 0,
        attentionCount: 0,
        informationalCount: 0,
        newestOpenBlockingAskId: nil
    )
}
