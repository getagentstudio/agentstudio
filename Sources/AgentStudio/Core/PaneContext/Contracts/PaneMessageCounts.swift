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
