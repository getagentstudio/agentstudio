import Foundation

public enum IPCPaneActivitySource: String, Codable, CaseIterable, Equatable, Sendable {
    case hook
    case terminal
}

public struct IPCPaneActivity: Codable, Equatable, Sendable {
    public let at: Date
    public let source: IPCPaneActivitySource

    public init(at: Date, source: IPCPaneActivitySource) {
        self.at = at
        self.source = source
    }
}

extension IPCPaneActivitySource: IPCSchemaProviding {}

extension IPCPaneActivity: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "at", description: "Wall time of the latest admitted activity", schema: .number()),
            .init(
                name: "source", description: "Source of the latest activity",
                schema: try IPCPaneActivitySource.ipcSchema()),
        ])
    }
}
