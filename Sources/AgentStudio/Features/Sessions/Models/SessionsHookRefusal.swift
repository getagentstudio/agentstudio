import Foundation

package enum SessionsHookRefusalReason: String, Sendable, Equatable {
    case noSessionId, undecodablePayload, queueFull
}

package struct SessionsHookRefusal: Sendable, Equatable {
    package let reason: SessionsHookRefusalReason
    package let event: String?
    package let at: Date

    package init(reason: SessionsHookRefusalReason, event: String?, at: Date) {
        self.reason = reason
        self.event = event
        self.at = at
    }
}
