import Foundation

package struct IPCPaneAgentLineInput: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let summary: String
    package let refs: [IPCPaneMessageAction]

    package init(summary: String, refs: [IPCPaneMessageAction] = []) {
        self.summary = summary
        self.refs = refs
    }

    private enum CodingKeys: String, CodingKey { case summary, refs }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        refs = try container.decodeIfPresent([IPCPaneMessageAction].self, forKey: .refs) ?? []
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "summary", description: "Agent message", schema: .string()),
            .optional(
                "refs", description: "Message attachments", schema: .array(items: try IPCPaneMessageAction.ipcSchema())),
        ])
    }
}

package struct IPCPaneAgentLineDetail: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let summary: String
    package let refs: [IPCPaneMessageAction]
    package let writer: IPCPaneMessageSender
    package let updatedAt: Date

    package init(summary: String, refs: [IPCPaneMessageAction], writer: IPCPaneMessageSender, updatedAt: Date) {
        self.summary = summary
        self.refs = refs
        self.writer = writer
        self.updatedAt = updatedAt
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "summary", description: "Agent message", schema: .string()),
            .init(
                name: "refs", description: "Message attachments",
                schema: .array(items: try IPCPaneMessageAction.ipcSchema())),
            .init(name: "writer", description: "Message writer", schema: try IPCPaneMessageSender.ipcSchema()),
            .init(name: "updatedAt", description: "Message write time", schema: .number()),
        ])
    }
}
