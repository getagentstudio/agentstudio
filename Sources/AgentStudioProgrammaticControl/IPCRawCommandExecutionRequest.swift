import Foundation

/// The sole command.execute wire envelope. App interprets these strings using
/// the selected command spec; clients never need its argument catalog first.
package struct IPCRawCommandExecutionRequest: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let commandId: IPCCommandIdentifier
    package let correlationId: UUID
    package let arguments: [String: String]

    package init(commandId: IPCCommandIdentifier, correlationId: UUID, arguments: [String: String]) {
        self.commandId = commandId
        self.correlationId = correlationId
        self.arguments = arguments
    }

    /// A typed caller explicitly projects its domain arguments into the same
    /// raw envelope. This is not an alternate wire decoder.
    package init(typedRequest: IPCCommandExecutionRequest) throws {
        let data = try JSONEncoder().encode(typedRequest.arguments)
        self.init(
            commandId: typedRequest.commandId, correlationId: typedRequest.correlationId,
            arguments: try JSONDecoder().decode([String: String].self, from: data))
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "commandId", description: "Open App-owned command identifier", schema: .string(minimumLength: 1)),
            .init(
                name: "correlationId", description: "Logical command UUID retained unchanged across retries",
                schema: IPCSchemaScalars.uuid),
            .init(
                name: "arguments",
                description: "Raw key=value strings parsed by the selected command's App-owned IPC projection",
                schema: .dictionary(values: .string())),
        ])
    }
}
