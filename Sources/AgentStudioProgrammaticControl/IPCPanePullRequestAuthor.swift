import Foundation

package enum IPCPanePullRequestAuthor: Codable, Equatable, Sendable, IPCSchemaProviding {
    case paneAgent(sourcePaneId: UUID, conversation: IPCPaneWriterClaim?)
    case client
    case person

    private enum CodingKeys: String, CodingKey { case kind, sourcePaneId, conversation }
    private enum Kind: String, Codable { case paneAgent, client, person }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .paneAgent:
            self = .paneAgent(
                sourcePaneId: try container.decode(UUID.self, forKey: .sourcePaneId),
                conversation: try container.decodeIfPresent(IPCPaneWriterClaim.self, forKey: .conversation))
        case .client: self = .client
        case .person: self = .person
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .paneAgent(let sourcePaneId, let conversation):
            try container.encode(Kind.paneAgent, forKey: .kind)
            try container.encode(sourcePaneId, forKey: .sourcePaneId)
            try container.encodeIfPresent(conversation, forKey: .conversation)
        case .client: try container.encode(Kind.client, forKey: .kind)
        case .person: try container.encode(Kind.person, forKey: .kind)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "paneAgent", schema: .string(allowedValues: ["paneAgent"])),
                .init(name: "sourcePaneId", description: "Authenticated source pane", schema: IPCSchemaScalars.uuid),
                .optional(
                    "conversation", description: "A verified source-pane conversation",
                    schema: try IPCPaneWriterClaim.ipcSchema()),
            ]),
            .object(fields: [.init(name: "kind", description: "client", schema: .string(allowedValues: ["client"]))]),
            .object(fields: [.init(name: "kind", description: "person", schema: .string(allowedValues: ["person"]))]),
        ])
    }
}
