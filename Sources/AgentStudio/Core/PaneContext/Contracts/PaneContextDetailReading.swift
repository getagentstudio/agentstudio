import Foundation

package struct PaneContextReadRequest: Sendable, Equatable {
    package let paneId: PaneId
    package let page: PaneContextReadPage

    package init(
        paneId: PaneId,
        page: PaneContextReadPage
    ) {
        self.paneId = paneId
        self.page = page
    }
}

package struct LiveMessageCursor: Sendable, Equatable {
    package let rank: Int
    package let position: UInt64

    package init(
        rank: Int,
        position: UInt64
    ) {
        self.rank = rank
        self.position = position
    }
}

package struct DetailTruncation: Sendable, Equatable {
    package let omitted: [OmittedLiveMessages]
    package let remainingLiveSources: Int
    package let nextSourcesAfter: PaneId?

    package init(
        omitted: [OmittedLiveMessages],
        remainingLiveSources: Int,
        nextSourcesAfter: PaneId?
    ) {
        self.omitted = omitted
        self.remainingLiveSources = remainingLiveSources
        self.nextSourcesAfter = nextSourcesAfter
    }
}

package struct OmittedLiveMessages: Sendable, Equatable {
    package let source: PaneId
    package let openAsks: Int
    package let unreadNotices: Int
    package let next: LiveMessageCursor

    package init(
        source: PaneId,
        openAsks: Int,
        unreadNotices: Int,
        next: LiveMessageCursor
    ) {
        self.source = source
        self.openAsks = openAsks
        self.unreadNotices = unreadNotices
        self.next = next
    }
}

package struct PaneContextScopedSessionSummary: Sendable, Equatable {
    package let sourcePaneId: PaneId
    package let session: SessionSummary?

    package init(sourcePaneId: PaneId, session: SessionSummary?) {
        self.sourcePaneId = sourcePaneId
        self.session = session
    }
}

package struct PaneContextDetail: Sendable, Equatable {
    package let paneId: PaneId
    package let revision: PaneContextRevision
    package let agentTitle: String?
    package let agentLine: AgentLineDetail?
    package let scopedSessions: [PaneContextScopedSessionSummary]
    package let hasDismissibleNotices: Bool
    package let messages: [AgentMessageDetail]
    package let drawerMessages: [DrawerMessageGroup]
    package let links: PaneLinksDetail
    package let pullRequests: PullRequestSummaryDetail
    package let truncation: DetailTruncation?

    package init(
        paneId: PaneId,
        revision: PaneContextRevision,
        agentTitle: String?,
        agentLine: AgentLineDetail?,
        scopedSessions: [PaneContextScopedSessionSummary],
        hasDismissibleNotices: Bool,
        messages: [AgentMessageDetail],
        drawerMessages: [DrawerMessageGroup],
        links: PaneLinksDetail,
        pullRequests: PullRequestSummaryDetail,
        truncation: DetailTruncation?
    ) {
        self.paneId = paneId
        self.revision = revision
        self.agentTitle = agentTitle
        self.agentLine = agentLine
        self.scopedSessions = scopedSessions
        self.hasDismissibleNotices = hasDismissibleNotices
        self.messages = messages
        self.drawerMessages = drawerMessages
        self.links = links
        self.pullRequests = pullRequests
        self.truncation = truncation
    }

    /// The public IPC identity field describes the requested pane, while native prompts use the full scope.
    package var ownSession: SessionSummary? {
        scopedSessions.first { $0.sourcePaneId == paneId }?.session
    }
}

package struct DrawerMessageGroup: Sendable, Equatable {
    package let sourcePaneId: PaneId
    package let messages: [AgentMessageDetail]

    package init(
        sourcePaneId: PaneId,
        messages: [AgentMessageDetail]
    ) {
        self.sourcePaneId = sourcePaneId
        self.messages = messages
    }
}

package protocol PaneContextDetailReading: Sendable {
    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult
    func readMessage(source: PaneId, message: AgentMessageId) async -> MessageReadResult
}

package enum MessageReadResult: Sendable, Equatable {
    case found(AgentMessageDetail)
    case notFound
    case unavailable(StorageFailureSummary)
}
package enum PaneContextReadPage: Sendable, Equatable {
    case first
    case more(source: PaneId, after: LiveMessageCursor)
    case moreSources(after: PaneId)
}
package enum PaneContextReadResult: Sendable, Equatable {
    case detail(PaneContextDetail)
    case paneGone
    case sourceNotInView
    case unavailable(StorageFailureSummary)
}
package enum PaneLinksDetail: Sendable, Equatable {
    case unknown
}
