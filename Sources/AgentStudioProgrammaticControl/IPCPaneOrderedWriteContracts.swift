import Foundation

package struct IPCPaneWriteNumber: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let epoch: UInt64
    package let counter: UInt64

    package init(epoch: UInt64, counter: UInt64) {
        self.epoch = epoch
        self.counter = counter
    }

    private enum CodingKeys: String, CodingKey {
        case epoch
        case counter
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try IPCPaneNumericCoding.decodeUnsigned(from: container, forKey: .epoch)
        counter = try IPCPaneNumericCoding.decodeUnsigned(from: container, forKey: .counter)
    }

    package func encode(to encoder: any Encoder) throws {
        try IPCPaneNumericCoding.requireSafe(epoch)
        try IPCPaneNumericCoding.requireSafe(counter)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(counter, forKey: .counter)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "epoch", description: "epoch", schema: IPCSchemaScalars.unsignedInteger),
            .init(name: "counter", description: "counter", schema: IPCSchemaScalars.unsignedInteger),
        ])
    }
}

package enum IPCPaneWriteStream: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case line
    case title
}

package struct IPCPaneWriterClaimEpochParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let writer: IPCPaneWriterClaim?
    package let stream: IPCPaneWriteStream
    package let claimId: UUID
    package let correlationId: UUID

    package init(
        handle: String, writer: IPCPaneWriterClaim? = nil, stream: IPCPaneWriteStream, claimId: UUID,
        correlationId: UUID
    ) {
        self.handle = handle
        self.writer = writer
        self.stream = stream
        self.claimId = claimId
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "handle", schema: .string()),
            .optional("writer", description: "writer", schema: try IPCPaneWriterClaim.ipcSchema()),
            .init(name: "stream", description: "stream", schema: try IPCPaneWriteStream.ipcSchema()),
            .init(name: "claimId", description: "claimId", schema: IPCSchemaScalars.uuid),
            .init(name: "correlationId", description: "correlationId", schema: IPCSchemaScalars.uuid),
        ])
    }
}

package enum IPCPaneEpochClaimResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    case claimed(epoch: UInt64)

    private enum CodingKeys: String, CodingKey {
        case kind
        case epoch
    }
    private enum Kind: String, Codable {
        case claimed
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .claimed: self = .claimed(epoch: try IPCPaneNumericCoding.decodeUnsigned(from: container, forKey: .epoch))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claimed(let epoch):
            try IPCPaneNumericCoding.requireSafe(epoch)
            try container.encode(Kind.claimed, forKey: .kind)
            try container.encode(epoch, forKey: .epoch)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "kind", description: "claimed", schema: .string(allowedValues: ["claimed"])),
            .init(name: "epoch", description: "epoch", schema: IPCSchemaScalars.unsignedInteger),
        ])
    }
}

package struct IPCPaneTitleSetParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let writer: IPCPaneWriterClaim?
    package let text: String?
    package let writeNumber: IPCPaneWriteNumber
    package let correlationId: UUID

    package init(
        handle: String, writer: IPCPaneWriterClaim? = nil, text: String? = nil, writeNumber: IPCPaneWriteNumber,
        correlationId: UUID
    ) {
        self.handle = handle
        self.writer = writer
        self.text = text
        self.writeNumber = writeNumber
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "handle", schema: .string()),
            .optional("writer", description: "writer", schema: try IPCPaneWriterClaim.ipcSchema()),
            .optional("text", description: "text", schema: .string()),
            .init(name: "writeNumber", description: "writeNumber", schema: try IPCPaneWriteNumber.ipcSchema()),
            .init(name: "correlationId", description: "correlationId", schema: IPCSchemaScalars.uuid),
        ])
    }
}

package struct IPCPaneLineSetParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let writer: IPCPaneWriterClaim?
    package let line: IPCPaneAgentLineInput?
    package let writeNumber: IPCPaneWriteNumber
    package let correlationId: UUID

    package init(
        handle: String, writer: IPCPaneWriterClaim? = nil, line: IPCPaneAgentLineInput? = nil,
        writeNumber: IPCPaneWriteNumber, correlationId: UUID
    ) {
        self.handle = handle
        self.writer = writer
        self.line = line
        self.writeNumber = writeNumber
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "handle", schema: .string()),
            .optional("writer", description: "writer", schema: try IPCPaneWriterClaim.ipcSchema()),
            .optional("line", description: "line", schema: try IPCPaneAgentLineInput.ipcSchema()),
            .init(name: "writeNumber", description: "writeNumber", schema: try IPCPaneWriteNumber.ipcSchema()),
            .init(name: "correlationId", description: "correlationId", schema: IPCSchemaScalars.uuid),
        ])
    }
}

package enum IPCPaneWriteStaleness: Codable, Equatable, Sendable, IPCSchemaProviding {
    case lastAccepted(writeNumber: IPCPaneWriteNumber)
    case epochSuperseded
    case writerReplaced

    private enum CodingKeys: String, CodingKey {
        case kind
        case writeNumber
    }
    private enum Kind: String, Codable {
        case lastAccepted
        case epochSuperseded
        case writerReplaced
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .lastAccepted:
            self = .lastAccepted(writeNumber: try container.decode(IPCPaneWriteNumber.self, forKey: .writeNumber))
        case .epochSuperseded: self = .epochSuperseded
        case .writerReplaced: self = .writerReplaced
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lastAccepted(let writeNumber):
            try container.encode(Kind.lastAccepted, forKey: .kind)
            try container.encode(writeNumber, forKey: .writeNumber)
        case .epochSuperseded:
            try container.encode(Kind.epochSuperseded, forKey: .kind)
        case .writerReplaced:
            try container.encode(Kind.writerReplaced, forKey: .kind)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "lastAccepted", schema: .string(allowedValues: ["lastAccepted"])),
                .init(name: "writeNumber", description: "writeNumber", schema: try IPCPaneWriteNumber.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "epochSuperseded", schema: .string(allowedValues: ["epochSuperseded"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "writerReplaced", schema: .string(allowedValues: ["writerReplaced"]))

            ]),
        ])
    }
}

package enum IPCPaneOrderedWriteResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    case applied
    case stale(reason: IPCPaneWriteStaleness)

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }
    private enum Kind: String, Codable {
        case applied
        case stale
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .applied: self = .applied
        case .stale: self = .stale(reason: try container.decode(IPCPaneWriteStaleness.self, forKey: .reason))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .applied:
            try container.encode(Kind.applied, forKey: .kind)
        case .stale(let reason):
            try container.encode(Kind.stale, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "applied", schema: .string(allowedValues: ["applied"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "stale", schema: .string(allowedValues: ["stale"])),
                .init(name: "reason", description: "reason", schema: try IPCPaneWriteStaleness.ipcSchema()),
            ]),
        ])
    }
}
