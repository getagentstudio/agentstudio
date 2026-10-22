import Foundation

package struct AgentLineDetail: Sendable, Equatable {
    package let summary: String
    package let refs: [MessageAction]
    package let writer: AgentMessageSender
    package let updatedAt: Date

    package init(summary: String, refs: [MessageAction], writer: AgentMessageSender, updatedAt: Date) {
        self.summary = summary
        self.refs = refs
        self.writer = writer
        self.updatedAt = updatedAt
    }
}
