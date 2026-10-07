import Foundation

package struct AgentLineDetail: Sendable, Equatable {
    package let summary: String
    package let work: AgentLineWork
    package let detail: String?
    package let refs: [MessageAction]
    package let writer: AgentMessageSender
    package let updatedAt: Date
    package let lifetime: AgentLineLifetime
    package let stale: Bool

    package init(
        summary: String,
        work: AgentLineWork,
        detail: String?,
        refs: [MessageAction],
        writer: AgentMessageSender,
        updatedAt: Date,
        lifetime: AgentLineLifetime,
        stale: Bool
    ) {
        self.summary = summary
        self.work = work
        self.detail = detail
        self.refs = refs
        self.writer = writer
        self.updatedAt = updatedAt
        self.lifetime = lifetime
        self.stale = stale
    }
}

package enum AgentLineWork: Sendable, Equatable {
    case working(AgentLineProgress)
    case monitoring(String)
    case blockedOnYou(action: String)
    case done
    case failed(summary: String)
}
package enum AgentLineProgress: Sendable, Equatable {
    case indeterminate
    case step(current: Int, total: Int)
}
package enum AgentLineLifetime: Sendable, Equatable {
    case untilReplaced
    case expires(at: Date)
}
