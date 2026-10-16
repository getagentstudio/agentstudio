import AgentStudioCore
import Foundation

package struct SessionsHookRefusal: Sendable, Equatable {
    package let reason: AgentConnectionRefusalReason
    package let event: String?
    package let at: Date
    package let intent: AgentCallIntent
    package let count: Int

    package init(
        reason: AgentConnectionRefusalReason, event: String?, at: Date, intent: AgentCallIntent = .identity,
        count: Int = 1
    ) {
        self.reason = reason
        self.event = event
        self.at = at
        self.intent = intent
        self.count = count
    }
}
