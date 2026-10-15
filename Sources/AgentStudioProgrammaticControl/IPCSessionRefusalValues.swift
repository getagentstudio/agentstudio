import Foundation

package struct IPCSessionLastRefusal: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let reason: IPCAgentConnectionRefusalReason
    package let event: String?
    package let at: Date
    package let intent: IPCCallIntent
    package let count: Int

    package init(
        reason: IPCAgentConnectionRefusalReason, event: String?, at: Date, intent: IPCCallIntent = .identity,
        count: Int = 1
    ) {
        self.reason = reason
        self.event = event
        self.at = at
        self.intent = intent
        self.count = count
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "reason", description: "Last hook refusal reason",
                schema: try IPCAgentConnectionRefusalReason.ipcSchema()),
            .optional("event", description: "Hook event when known", schema: .string(maximumLength: 128)),
            .init(name: "at", description: "Time the app recorded the refusal", schema: .number()),
            .init(name: "intent", description: "Refused call intent", schema: try IPCCallIntent.ipcSchema()),
            .init(name: "count", description: "Refusals since accepted identity", schema: .integer(minimum: 1)),
        ])
    }
}
