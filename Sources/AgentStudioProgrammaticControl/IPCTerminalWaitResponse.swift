import Foundation

/// Transport receipt combines a runtime observation with the server's actual
/// wait policy. Runtime ports remain responsible only for the observation.
package struct IPCTerminalWaitResponse: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let observation: IPCTerminalWaitResult
    package let timeoutSeconds: Double
    package let wasClamped: Bool

    package init(observation: IPCTerminalWaitResult, timeoutSeconds: Double, wasClamped: Bool) {
        self.observation = observation
        self.timeoutSeconds = timeoutSeconds
        self.wasClamped = wasClamped
    }

    private enum CodingKeys: String, CodingKey { case timeoutSeconds, wasClamped }

    package init(from decoder: any Decoder) throws {
        observation = try IPCTerminalWaitResult(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeoutSeconds = try container.decode(Double.self, forKey: .timeoutSeconds)
        wasClamped = try container.decode(Bool.self, forKey: .wasClamped)
    }

    package func encode(to encoder: any Encoder) throws {
        try observation.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(wasClamped, forKey: .wasClamped)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        guard case .object(let fields) = try IPCTerminalWaitResult.ipcSchema() else {
            throw IPCSchemaValidationError(
                fieldPath: "$", reason: .invalidDefinition, expected: "terminal observation object")
        }
        return .object(
            fields: fields + [
                .init(
                    name: "timeoutSeconds", description: "Effective wait duration after server policy clamping",
                    schema: .number(minimum: 0)),
                .init(
                    name: "wasClamped", description: "The requested duration exceeded the server policy maximum",
                    schema: .boolean),
            ])
    }
}
