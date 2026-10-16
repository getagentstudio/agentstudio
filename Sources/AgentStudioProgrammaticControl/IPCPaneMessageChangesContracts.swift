import Foundation

package struct IPCPaneMessageChangesParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let writer: IPCPaneWriterClaim?
    package let after: UInt64
    package let correlationId: UUID

    package init(handle: String, writer: IPCPaneWriterClaim? = nil, after: UInt64, correlationId: UUID) {
        self.handle = handle
        self.writer = writer
        self.after = after
        self.correlationId = correlationId
    }

    private enum CodingKeys: String, CodingKey {
        case handle
        case writer
        case after
        case correlationId
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handle = try container.decode(String.self, forKey: .handle)
        writer = try container.decodeIfPresent(IPCPaneWriterClaim.self, forKey: .writer)
        after = try IPCPaneNumericCoding.decodeUnsigned(from: container, forKey: .after)
        correlationId = try container.decode(UUID.self, forKey: .correlationId)
    }

    package func encode(to encoder: any Encoder) throws {
        try IPCPaneNumericCoding.requireSafe(after)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handle, forKey: .handle)
        try container.encodeIfPresent(writer, forKey: .writer)
        try container.encode(after, forKey: .after)
        try container.encode(correlationId, forKey: .correlationId)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "handle", schema: .string()),
            .optional("writer", description: "writer", schema: try IPCPaneWriterClaim.ipcSchema()),
            .init(name: "after", description: "after", schema: IPCSchemaScalars.unsignedInteger),
            .init(name: "correlationId", description: "correlationId", schema: IPCSchemaScalars.uuid),
        ])
    }
}

package struct IPCPaneMessageChangesResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let entries: [IPCPaneMessageChangeEntry]
    package let nextPosition: UInt64
    package let more: Bool

    package init(entries: [IPCPaneMessageChangeEntry], nextPosition: UInt64, more: Bool) {
        self.entries = entries
        self.nextPosition = nextPosition
        self.more = more
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case nextPosition
        case more
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([IPCPaneMessageChangeEntry].self, forKey: .entries)
        nextPosition = try IPCPaneNumericCoding.decodeUnsigned(from: container, forKey: .nextPosition)
        more = try container.decode(Bool.self, forKey: .more)
    }

    package func encode(to encoder: any Encoder) throws {
        try IPCPaneNumericCoding.requireSafe(nextPosition)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(nextPosition, forKey: .nextPosition)
        try container.encode(more, forKey: .more)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "entries", description: "entries",
                schema: .array(items: try IPCPaneMessageChangeEntry.ipcSchema())),
            .init(name: "nextPosition", description: "nextPosition", schema: IPCSchemaScalars.unsignedInteger),
            .init(name: "more", description: "more", schema: .boolean),
        ])
    }
}

package struct IPCPaneMessageChangeEntry: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let id: UUID
    package let position: UInt64
    package let messageId: UUID
    package let kind: IPCPaneMessageChangeKind

    package init(id: UUID, position: UInt64, messageId: UUID, kind: IPCPaneMessageChangeKind) {
        self.id = id
        self.position = position
        self.messageId = messageId
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case position
        case messageId
        case kind
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        position = try IPCPaneNumericCoding.decodeUnsigned(from: container, forKey: .position)
        messageId = try container.decode(UUID.self, forKey: .messageId)
        kind = try container.decode(IPCPaneMessageChangeKind.self, forKey: .kind)
    }

    package func encode(to encoder: any Encoder) throws {
        try IPCPaneNumericCoding.requireSafe(position)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(position, forKey: .position)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(kind, forKey: .kind)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "id", schema: IPCSchemaScalars.uuid),
            .init(name: "position", description: "position", schema: IPCSchemaScalars.unsignedInteger),
            .init(name: "messageId", description: "messageId", schema: IPCSchemaScalars.uuid),
            .init(name: "kind", description: "kind", schema: try IPCPaneMessageChangeKind.ipcSchema()),
        ])
    }
}

package enum IPCPaneMessageChangeKind: Codable, Equatable, Sendable, IPCSchemaProviding {
    case answer(value: IPCPaneAskAnswerValue)
    case dismissal
    case withdrawal

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }
    private enum Kind: String, Codable {
        case answer
        case dismissal
        case withdrawal
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .answer: self = .answer(value: try container.decode(IPCPaneAskAnswerValue.self, forKey: .value))
        case .dismissal: self = .dismissal
        case .withdrawal: self = .withdrawal
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .answer(let value):
            try container.encode(Kind.answer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .dismissal:
            try container.encode(Kind.dismissal, forKey: .kind)
        case .withdrawal:
            try container.encode(Kind.withdrawal, forKey: .kind)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "answer", schema: .string(allowedValues: ["answer"])),
                .init(name: "value", description: "value", schema: try IPCPaneAskAnswerValue.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "dismissal", schema: .string(allowedValues: ["dismissal"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "withdrawal", schema: .string(allowedValues: ["withdrawal"]))

            ]),
        ])
    }
}
