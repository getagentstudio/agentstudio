package struct PaneContextDisplay: Sendable, Equatable {
    package let revision: PaneContextRevision
    package let agentTitle: String?
    package let agentLine: AgentLineDetail?
    package let own: PaneMessageCounts
    package let includingDrawers: PaneMessageCounts
    package let pullRequests: PullRequestSummaryDetail

    package init(
        revision: PaneContextRevision, agentTitle: String?, agentLine: AgentLineDetail?,
        own: PaneMessageCounts, includingDrawers: PaneMessageCounts, pullRequests: PullRequestSummaryDetail
    ) {
        self.revision = revision
        self.agentTitle = agentTitle
        self.agentLine = agentLine
        self.own = own
        self.includingDrawers = includingDrawers
        self.pullRequests = pullRequests
    }
}
