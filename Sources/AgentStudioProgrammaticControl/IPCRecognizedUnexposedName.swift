import Foundation

/// A method or command this build recognizes that the current channel does
/// not expose. Discovery lists these names with their agent eligibility so a
/// pane agent can see what is not yet allowed; the app refuses a pane agent
/// that names one with `notYetAllowed`, by name.
package struct IPCRecognizedUnexposedName: Codable, Equatable, Hashable, Sendable {
    package let name: String
    package let agentEligibility: IPCAgentEligibility

    package init(name: String, agentEligibility: IPCAgentEligibility) {
        self.name = name
        self.agentEligibility = agentEligibility
    }
}

extension IPCRecognizedUnexposedName: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "name", description: "Recognized method or command identifier", schema: .string(minimumLength: 1)),
            .init(
                name: "agentEligibility", description: "What a pane-bound agent may do with it",
                schema: try IPCAgentEligibility.ipcSchema()),
        ])
    }

    /// Discovery field listing recognized names this channel hides. Defaulted
    /// to empty, so the debug channel, which hides nothing, sends none.
    static func discoveryField(_ name: String, description: String) throws -> IPCObjectField {
        .init(
            name: name,
            description: description,
            schema: .array(items: try ipcSchema()),
            presence: try .defaulted([Self]())
        )
    }
}
