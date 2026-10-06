import Foundation

/// Query reasons include the app's capacity refusal; CLI input has only payload reasons.
package enum IPCSessionLastRefusalReason: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case noSessionId, undecodablePayload, queueFull
}

package struct IPCSessionLastRefusal: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let reason: IPCSessionLastRefusalReason
    package let event: String?
    package let at: Date

    package init(reason: IPCSessionLastRefusalReason, event: String?, at: Date) {
        self.reason = reason
        self.event = event
        self.at = at
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "reason", description: "Last hook refusal reason",
                schema: try IPCSessionLastRefusalReason.ipcSchema()),
            .optional("event", description: "Hook event when known", schema: .string(maximumLength: 128)),
            .init(name: "at", description: "Time the app recorded the refusal", schema: .number()),
        ])
    }
}
