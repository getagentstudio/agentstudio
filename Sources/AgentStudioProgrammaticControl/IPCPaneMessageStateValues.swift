import Foundation

package enum IPCPanePersonActor: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case localUser
}

package enum IPCPaneMessageSender: Codable, Equatable, Sendable, IPCSchemaProviding {
    case pane(paneId: UUID)
    case session(provider: String, conversationId: String, bindingGeneration: UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case paneId
        case provider
        case conversationId
        case bindingGeneration
    }
    private enum Kind: String, Codable {
        case pane
        case session
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pane: self = .pane(paneId: try container.decode(UUID.self, forKey: .paneId))
        case .session:
            self = .session(
                provider: try container.decode(String.self, forKey: .provider),
                conversationId: try container.decode(String.self, forKey: .conversationId),
                bindingGeneration: try container.decode(UUID.self, forKey: .bindingGeneration))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let paneId):
            try container.encode(Kind.pane, forKey: .kind)
            try container.encode(paneId, forKey: .paneId)
        case .session(let provider, let conversationId, let bindingGeneration):
            try container.encode(Kind.session, forKey: .kind)
            try container.encode(provider, forKey: .provider)
            try container.encode(conversationId, forKey: .conversationId)
            try container.encode(bindingGeneration, forKey: .bindingGeneration)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "pane", schema: .string(allowedValues: ["pane"])),
                .init(name: "paneId", description: "paneId", schema: IPCSchemaScalars.uuid),
            ]),
            .object(fields: [
                .init(name: "kind", description: "session", schema: .string(allowedValues: ["session"])),
                .init(name: "provider", description: "provider", schema: .string()),
                .init(name: "conversationId", description: "conversationId", schema: .string()),
                .init(name: "bindingGeneration", description: "bindingGeneration", schema: IPCSchemaScalars.uuid),
            ]),
        ])
    }
}

package enum IPCPaneNoticeState: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case unread
    case read
    case dismissed
    case withdrawn
}

package enum IPCPaneNoticeTerminalState: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case dismissed
    case withdrawn
}

package enum IPCPaneAnswerReceipt: Codable, Equatable, Sendable, IPCSchemaProviding {
    case notYetConfirmed
    case confirmed(at: Date)
    case unconfirmed

    private enum CodingKeys: String, CodingKey {
        case kind
        case at
    }
    private enum Kind: String, Codable {
        case notYetConfirmed
        case confirmed
        case unconfirmed
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .notYetConfirmed: self = .notYetConfirmed
        case .confirmed: self = .confirmed(at: try container.decode(Date.self, forKey: .at))
        case .unconfirmed: self = .unconfirmed
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notYetConfirmed:
            try container.encode(Kind.notYetConfirmed, forKey: .kind)
        case .confirmed(let at):
            try container.encode(Kind.confirmed, forKey: .kind)
            try container.encode(at, forKey: .at)
        case .unconfirmed:
            try container.encode(Kind.unconfirmed, forKey: .kind)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "notYetConfirmed", schema: .string(allowedValues: ["notYetConfirmed"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "confirmed", schema: .string(allowedValues: ["confirmed"])),
                .init(name: "at", description: "at", schema: .number()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "unconfirmed", schema: .string(allowedValues: ["unconfirmed"]))

            ]),
        ])
    }
}

package enum IPCPaneAskState: Codable, Equatable, Sendable, IPCSchemaProviding {
    case open
    case answered(by: IPCPanePersonActor, value: IPCPaneAskAnswerValue, receipt: IPCPaneAnswerReceipt)
    case handedBack
    case dismissed
    case expired
    case withdrawn
    case stale

    private enum CodingKeys: String, CodingKey {
        case kind
        case by
        case value
        case receipt
    }
    private enum Kind: String, Codable {
        case open
        case answered
        case handedBack
        case dismissed
        case expired
        case withdrawn
        case stale
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .open: self = .open
        case .answered:
            self = .answered(
                by: try container.decode(IPCPanePersonActor.self, forKey: .by),
                value: try container.decode(IPCPaneAskAnswerValue.self, forKey: .value),
                receipt: try container.decode(IPCPaneAnswerReceipt.self, forKey: .receipt))
        case .handedBack: self = .handedBack
        case .dismissed: self = .dismissed
        case .expired: self = .expired
        case .withdrawn: self = .withdrawn
        case .stale: self = .stale
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .open:
            try container.encode(Kind.open, forKey: .kind)
        case .answered(let by, let value, let receipt):
            try container.encode(Kind.answered, forKey: .kind)
            try container.encode(by, forKey: .by)
            try container.encode(value, forKey: .value)
            try container.encode(receipt, forKey: .receipt)
        case .handedBack:
            try container.encode(Kind.handedBack, forKey: .kind)
        case .dismissed:
            try container.encode(Kind.dismissed, forKey: .kind)
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
                .init(name: "kind", description: "open", schema: .string(allowedValues: ["open"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "answered", schema: .string(allowedValues: ["answered"])),
                .init(name: "by", description: "by", schema: try IPCPanePersonActor.ipcSchema()),
                .init(name: "value", description: "value", schema: try IPCPaneAskAnswerValue.ipcSchema()),
                .init(name: "receipt", description: "receipt", schema: try IPCPaneAnswerReceipt.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "handedBack", schema: .string(allowedValues: ["handedBack"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "dismissed", schema: .string(allowedValues: ["dismissed"]))

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

package enum IPCPaneAskTerminalState: Codable, Equatable, Sendable, IPCSchemaProviding {
    case answered(by: IPCPanePersonActor, value: IPCPaneAskAnswerValue, receipt: IPCPaneAnswerReceipt)
    case handedBack
    case dismissed
    case expired
    case withdrawn
    case stale

    private enum CodingKeys: String, CodingKey {
        case kind
        case by
        case value
        case receipt
    }
    private enum Kind: String, Codable {
        case answered
        case handedBack
        case dismissed
        case expired
        case withdrawn
        case stale
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .answered:
            self = .answered(
                by: try container.decode(IPCPanePersonActor.self, forKey: .by),
                value: try container.decode(IPCPaneAskAnswerValue.self, forKey: .value),
                receipt: try container.decode(IPCPaneAnswerReceipt.self, forKey: .receipt))
        case .handedBack: self = .handedBack
        case .dismissed: self = .dismissed
        case .expired: self = .expired
        case .withdrawn: self = .withdrawn
        case .stale: self = .stale
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .answered(let by, let value, let receipt):
            try container.encode(Kind.answered, forKey: .kind)
            try container.encode(by, forKey: .by)
            try container.encode(value, forKey: .value)
            try container.encode(receipt, forKey: .receipt)
        case .handedBack:
            try container.encode(Kind.handedBack, forKey: .kind)
        case .dismissed:
            try container.encode(Kind.dismissed, forKey: .kind)
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
                .init(name: "by", description: "by", schema: try IPCPanePersonActor.ipcSchema()),
                .init(name: "value", description: "value", schema: try IPCPaneAskAnswerValue.ipcSchema()),
                .init(name: "receipt", description: "receipt", schema: try IPCPaneAnswerReceipt.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "handedBack", schema: .string(allowedValues: ["handedBack"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "dismissed", schema: .string(allowedValues: ["dismissed"]))

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

package enum IPCPaneTerminalState: Codable, Equatable, Sendable, IPCSchemaProviding {
    case ask(state: IPCPaneAskTerminalState)
    case notice(state: IPCPaneNoticeTerminalState)

    private enum CodingKeys: String, CodingKey {
        case kind
        case state
    }
    private enum Kind: String, Codable {
        case ask
        case notice
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ask: self = .ask(state: try container.decode(IPCPaneAskTerminalState.self, forKey: .state))
        case .notice: self = .notice(state: try container.decode(IPCPaneNoticeTerminalState.self, forKey: .state))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ask(let state):
            try container.encode(Kind.ask, forKey: .kind)
            try container.encode(state, forKey: .state)
        case .notice(let state):
            try container.encode(Kind.notice, forKey: .kind)
            try container.encode(state, forKey: .state)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "ask", schema: .string(allowedValues: ["ask"])),
                .init(name: "state", description: "state", schema: try IPCPaneAskTerminalState.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "notice", schema: .string(allowedValues: ["notice"])),
                .init(name: "state", description: "state", schema: try IPCPaneNoticeTerminalState.ipcSchema()),
            ]),
        ])
    }
}
