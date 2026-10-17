import Foundation

package enum IPCPaneMessageShape: Codable, Equatable, Sendable, IPCSchemaProviding {
    case notice(state: IPCPaneNoticeState)
    case ask(reason: IPCPaneAskReason, form: IPCPaneAskForm, waiting: IPCPaneAskWaiting, state: IPCPaneAskState)

    private enum CodingKeys: String, CodingKey {
        case kind
        case state
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
        case .notice: self = .notice(state: try container.decode(IPCPaneNoticeState.self, forKey: .state))
        case .ask:
            self = .ask(
                reason: try container.decode(IPCPaneAskReason.self, forKey: .reason),
                form: try container.decode(IPCPaneAskForm.self, forKey: .form),
                waiting: try container.decode(IPCPaneAskWaiting.self, forKey: .waiting),
                state: try container.decode(IPCPaneAskState.self, forKey: .state))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notice(let state):
            try container.encode(Kind.notice, forKey: .kind)
            try container.encode(state, forKey: .state)
        case .ask(let reason, let form, let waiting, let state):
            try container.encode(Kind.ask, forKey: .kind)
            try container.encode(reason, forKey: .reason)
            try container.encode(form, forKey: .form)
            try container.encode(waiting, forKey: .waiting)
            try container.encode(state, forKey: .state)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "notice", schema: .string(allowedValues: ["notice"])),
                .init(name: "state", description: "state", schema: try IPCPaneNoticeState.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "ask", schema: .string(allowedValues: ["ask"])),
                .init(name: "reason", description: "reason", schema: try IPCPaneAskReason.ipcSchema()),
                .init(name: "form", description: "form", schema: try IPCPaneAskForm.ipcSchema()),
                .init(name: "waiting", description: "waiting", schema: try IPCPaneAskWaiting.ipcSchema()),
                .init(name: "state", description: "state", schema: try IPCPaneAskState.ipcSchema()),
            ]),
        ])
    }
}

package struct IPCPaneMessageDetail: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let id: UUID
    package let sourcePaneId: UUID
    package let sender: IPCPaneMessageSender
    package let sentAt: Date
    package let sourceOccurredAt: Date?
    package let importance: IPCPaneMessageImportance
    package let body: String
    package let why: String?
    package let actions: [IPCPaneMessageAction]
    package let shape: IPCPaneMessageShape

    package init(
        id: UUID, sourcePaneId: UUID, sender: IPCPaneMessageSender, sentAt: Date, sourceOccurredAt: Date? = nil,
        importance: IPCPaneMessageImportance, body: String, why: String? = nil, actions: [IPCPaneMessageAction],
        shape: IPCPaneMessageShape
    ) {
        self.id = id
        self.sourcePaneId = sourcePaneId
        self.sender = sender
        self.sentAt = sentAt
        self.sourceOccurredAt = sourceOccurredAt
        self.importance = importance
        self.body = body
        self.why = why
        self.actions = actions
        self.shape = shape
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "id", schema: IPCSchemaScalars.uuid),
            .init(name: "sourcePaneId", description: "sourcePaneId", schema: IPCSchemaScalars.uuid),
            .init(name: "sender", description: "sender", schema: try IPCPaneMessageSender.ipcSchema()),
            .init(name: "sentAt", description: "sentAt", schema: .number()),
            .optional("sourceOccurredAt", description: "sourceOccurredAt", schema: .number()),
            .init(name: "importance", description: "importance", schema: try IPCPaneMessageImportance.ipcSchema()),
            .init(name: "body", description: "body", schema: .string()),
            .optional("why", description: "why", schema: .string()),
            .init(name: "actions", description: "actions", schema: .array(items: try IPCPaneMessageAction.ipcSchema())),
            .init(name: "shape", description: "shape", schema: try IPCPaneMessageShape.ipcSchema()),
        ])
    }
}
