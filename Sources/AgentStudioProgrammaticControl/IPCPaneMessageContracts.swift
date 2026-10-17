import Foundation

package enum IPCPaneMessageSendShape: Codable, Equatable, Sendable, IPCSchemaProviding {
    case notice
    case ask(reason: IPCPaneAskReason, form: IPCPaneAskForm, waiting: IPCPaneNonBlockingWaiting)

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
        case form
        case waiting
    }
    private enum Kind: String, Codable {
        case notice
        case ask
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .notice: self = .notice
        case .ask:
            self = .ask(
                reason: try container.decode(IPCPaneAskReason.self, forKey: .reason),
                form: try container.decode(IPCPaneAskForm.self, forKey: .form),
                waiting: try container.decode(IPCPaneNonBlockingWaiting.self, forKey: .waiting))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notice:
            try container.encode(Kind.notice, forKey: .kind)
        case .ask(let reason, let form, let waiting):
            try container.encode(Kind.ask, forKey: .kind)
            try container.encode(reason, forKey: .reason)
            try container.encode(form, forKey: .form)
            try container.encode(waiting, forKey: .waiting)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "notice", schema: .string(allowedValues: ["notice"]))
            ]),
            .object(fields: [
                .init(name: "kind", description: "ask", schema: .string(allowedValues: ["ask"])),
                .init(name: "reason", description: "reason", schema: try IPCPaneAskReason.ipcSchema()),
                .init(name: "form", description: "form", schema: try IPCPaneAskForm.ipcSchema()),
                .init(name: "waiting", description: "waiting", schema: try IPCPaneNonBlockingWaiting.ipcSchema()),
            ]),
        ])
    }
}
package enum IPCPaneBlockingAskShape: Codable, Equatable, Sendable, IPCSchemaProviding {
    case ask(reason: IPCPaneAskReason, form: IPCPaneAskForm, waiting: IPCPaneBlockingWaiting)

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
        case form
        case waiting
    }
    private enum Kind: String, Codable {
        case ask
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ask:
            self = .ask(
                reason: try container.decode(IPCPaneAskReason.self, forKey: .reason),
                form: try container.decode(IPCPaneAskForm.self, forKey: .form),
                waiting: try container.decode(IPCPaneBlockingWaiting.self, forKey: .waiting))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ask(let reason, let form, let waiting):
            try container.encode(Kind.ask, forKey: .kind)
            try container.encode(reason, forKey: .reason)
            try container.encode(form, forKey: .form)
            try container.encode(waiting, forKey: .waiting)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "kind", description: "ask", schema: .string(allowedValues: ["ask"])),
            .init(name: "reason", description: "reason", schema: try IPCPaneAskReason.ipcSchema()),
            .init(name: "form", description: "form", schema: try IPCPaneAskForm.ipcSchema()),
            .init(name: "waiting", description: "waiting", schema: try IPCPaneBlockingWaiting.ipcSchema()),
        ])
    }
}
package struct IPCPaneMessageSendParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let messageId: UUID
    package let writer: IPCPaneWriterClaim?
    package let sourceOccurredAt: Date?
    package let importance: IPCPaneMessageImportance
    package let body: String
    package let why: String?
    package let actions: [IPCPaneMessageAction]
    package let shape: IPCPaneMessageSendShape
    package let correlationId: UUID

    package init(
        handle: String, messageId: UUID, writer: IPCPaneWriterClaim? = nil, sourceOccurredAt: Date? = nil,
        importance: IPCPaneMessageImportance, body: String, why: String? = nil, actions: [IPCPaneMessageAction],
        shape: IPCPaneMessageSendShape, correlationId: UUID
    ) {
        self.handle = handle
        self.messageId = messageId
        self.writer = writer
        self.sourceOccurredAt = sourceOccurredAt
        self.importance = importance
        self.body = body
        self.why = why
        self.actions = actions
        self.shape = shape
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "handle", schema: .string()),
            .init(name: "messageId", description: "messageId", schema: IPCSchemaScalars.uuid),
            .optional("writer", description: "writer", schema: try IPCPaneWriterClaim.ipcSchema()),
            .optional("sourceOccurredAt", description: "sourceOccurredAt", schema: .number()),
            .init(name: "importance", description: "importance", schema: try IPCPaneMessageImportance.ipcSchema()),
            .init(name: "body", description: "body", schema: .string()),
            .optional("why", description: "why", schema: .string()),
            .init(name: "actions", description: "actions", schema: .array(items: try IPCPaneMessageAction.ipcSchema())),
            .init(name: "shape", description: "shape", schema: try IPCPaneMessageSendShape.ipcSchema()),
            .init(name: "correlationId", description: "correlationId", schema: IPCSchemaScalars.uuid),
        ])
    }
}
package struct IPCPaneMessageAskParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let messageId: UUID
    package let writer: IPCPaneWriterClaim?
    package let sourceOccurredAt: Date?
    package let importance: IPCPaneMessageImportance
    package let body: String
    package let why: String?
    package let actions: [IPCPaneMessageAction]
    package let shape: IPCPaneBlockingAskShape
    package let correlationId: UUID

    package init(
        handle: String, messageId: UUID, writer: IPCPaneWriterClaim? = nil, sourceOccurredAt: Date? = nil,
        importance: IPCPaneMessageImportance, body: String, why: String? = nil, actions: [IPCPaneMessageAction],
        shape: IPCPaneBlockingAskShape, correlationId: UUID
    ) {
        self.handle = handle
        self.messageId = messageId
        self.writer = writer
        self.sourceOccurredAt = sourceOccurredAt
        self.importance = importance
        self.body = body
        self.why = why
        self.actions = actions
        self.shape = shape
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "handle", schema: .string()),
            .init(name: "messageId", description: "messageId", schema: IPCSchemaScalars.uuid),
            .optional("writer", description: "writer", schema: try IPCPaneWriterClaim.ipcSchema()),
            .optional("sourceOccurredAt", description: "sourceOccurredAt", schema: .number()),
            .init(name: "importance", description: "importance", schema: try IPCPaneMessageImportance.ipcSchema()),
            .init(name: "body", description: "body", schema: .string()),
            .optional("why", description: "why", schema: .string()),
            .init(name: "actions", description: "actions", schema: .array(items: try IPCPaneMessageAction.ipcSchema())),
            .init(name: "shape", description: "shape", schema: try IPCPaneBlockingAskShape.ipcSchema()),
            .init(name: "correlationId", description: "correlationId", schema: IPCSchemaScalars.uuid),
        ])
    }
}
package struct IPCPaneMessageWithdrawParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let messageId: UUID
    package let writer: IPCPaneWriterClaim?
    package let correlationId: UUID

    package init(handle: String, messageId: UUID, writer: IPCPaneWriterClaim? = nil, correlationId: UUID) {
        self.handle = handle
        self.messageId = messageId
        self.writer = writer
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "handle", schema: .string()),
            .init(name: "messageId", description: "messageId", schema: IPCSchemaScalars.uuid),
            .optional("writer", description: "writer", schema: try IPCPaneWriterClaim.ipcSchema()),
            .init(name: "correlationId", description: "correlationId", schema: IPCSchemaScalars.uuid),
        ])
    }
}
package enum IPCPaneMessageSendResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    case created(id: UUID)
    case existing(id: UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }
    private enum Kind: String, Codable {
        case created
        case existing
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .created: self = .created(id: try container.decode(UUID.self, forKey: .id))
        case .existing: self = .existing(id: try container.decode(UUID.self, forKey: .id))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .created(let id):
            try container.encode(Kind.created, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .existing(let id):
            try container.encode(Kind.existing, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "created", schema: .string(allowedValues: ["created"])),
                .init(name: "id", description: "id", schema: IPCSchemaScalars.uuid),
            ]),
            .object(fields: [
                .init(name: "kind", description: "existing", schema: .string(allowedValues: ["existing"])),
                .init(name: "id", description: "id", schema: IPCSchemaScalars.uuid),
            ]),
        ])
    }
}
package enum IPCPaneAskOutcome: Codable, Equatable, Sendable, IPCSchemaProviding {
    case answered(value: IPCPaneAskAnswerValue)
    case handedBack
    case expired
    case withdrawn
    case stale

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }
    private enum Kind: String, Codable {
        case answered
        case handedBack
        case expired
        case withdrawn
        case stale
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .answered: self = .answered(value: try container.decode(IPCPaneAskAnswerValue.self, forKey: .value))
        case .handedBack: self = .handedBack
        case .expired: self = .expired
        case .withdrawn: self = .withdrawn
        case .stale: self = .stale
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .answered(let value):
            try container.encode(Kind.answered, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .handedBack:
            try container.encode(Kind.handedBack, forKey: .kind)
        case .expired:
            try container.encode(Kind.expired, forKey: .kind)
        case .withdrawn:
            try container.encode(Kind.withdrawn, forKey: .kind)
        case .stale:
            try container.encode(Kind.stale, forKey: .kind)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "answered", schema: .string(allowedValues: ["answered"])),
                .init(name: "value", description: "value", schema: try IPCPaneAskAnswerValue.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "handedBack", schema: .string(allowedValues: ["handedBack"]))
            ]),
            .object(fields: [
                .init(name: "kind", description: "expired", schema: .string(allowedValues: ["expired"]))
            ]),
            .object(fields: [
                .init(name: "kind", description: "withdrawn", schema: .string(allowedValues: ["withdrawn"]))
            ]),
            .object(fields: [
                .init(name: "kind", description: "stale", schema: .string(allowedValues: ["stale"]))
            ]),
        ])
    }
}
package enum IPCPaneMessageWithdrawResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    case withdrawn
    case alreadySettled(state: IPCPaneTerminalState)
    case notFound

    private enum CodingKeys: String, CodingKey {
        case kind
        case state
    }
    private enum Kind: String, Codable {
        case withdrawn
        case alreadySettled
        case notFound
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .withdrawn: self = .withdrawn
        case .alreadySettled:
            self = .alreadySettled(state: try container.decode(IPCPaneTerminalState.self, forKey: .state))
        case .notFound: self = .notFound
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .withdrawn:
            try container.encode(Kind.withdrawn, forKey: .kind)
        case .alreadySettled(let state):
            try container.encode(Kind.alreadySettled, forKey: .kind)
            try container.encode(state, forKey: .state)
        case .notFound:
            try container.encode(Kind.notFound, forKey: .kind)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "withdrawn", schema: .string(allowedValues: ["withdrawn"]))
            ]),
            .object(fields: [
                .init(name: "kind", description: "alreadySettled", schema: .string(allowedValues: ["alreadySettled"])),
                .init(name: "state", description: "state", schema: try IPCPaneTerminalState.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "notFound", schema: .string(allowedValues: ["notFound"]))
            ]),
        ])
    }
}
