import Foundation

package struct IPCEmptyParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package init() {}

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [])
    }
}

package struct IPCPaneSelectorParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String

    package init(handle: String) {
        self.handle = handle
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [IPCRequestSchemaFields.pane()])
    }
}

package struct IPCPaneControlParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let correlationId: UUID

    package init(handle: String, correlationId: UUID) {
        self.handle = handle
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

package struct IPCTerminalSendParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let input: String
    package let correlationId: UUID

    package init(handle: String, input: String, correlationId: UUID) {
        self.handle = handle
        self.input = input
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(
                name: "input", description: "Exact terminal input bytes represented as Unicode text", schema: .string()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

package struct IPCTerminalWaitParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let condition: IPCTerminalWaitCondition
    package let timeoutSeconds: Double
    package let afterSequence: UInt64?

    package init(
        handle: String,
        condition: IPCTerminalWaitCondition,
        timeoutSeconds: Double,
        afterSequence: UInt64?
    ) {
        self.handle = handle
        self.condition = condition
        self.timeoutSeconds = timeoutSeconds
        self.afterSequence = afterSequence
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(
                name: "condition", description: "Terminal condition to observe",
                schema: try IPCTerminalWaitCondition.ipcSchema()),
            .init(
                name: "timeoutSeconds",
                description:
                    "Finite nonnegative wait duration in seconds; the composed method supplies its upper bound",
                schema: .number(minimum: 0)),
            .optional(
                "afterSequence", description: "Observe only events after this terminal sequence",
                schema: IPCSchemaScalars.unsignedInteger),
        ])
    }
}

package struct IPCSystemPingResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let ok: Bool
    package let runtimeId: UUID

    package init(runtimeId: UUID) {
        ok = true
        self.runtimeId = runtimeId
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Bool.self, forKey: .ok) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ok,
                in: container,
                debugDescription: "Ping success must be true"
            )
        }
        ok = true
        runtimeId = try container.decode(UUID.self, forKey: .runtimeId)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(true, forKey: .ok)
        try container.encode(runtimeId, forKey: .runtimeId)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "ok", description: "Successful ping discriminator", schema: .booleanConstant(true)),
            .init(name: "runtimeId", description: "Application runtime UUID", schema: IPCSchemaScalars.uuid),
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case runtimeId
    }
}

package struct IPCAuthLoginParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let token: String

    package init(token: String) {
        self.token = token
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "token", description: "Bearer credential supplied by the owning runtime",
                schema: .string(minimumLength: 1))
        ])
    }
}

package enum IPCAuthStatusResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    case unauthenticated
    case authenticated(
        principalId: UUID, runtimeId: UUID, accessMode: IPCAccessMode,
        cliStoreReadThrough: IPCCLIStoreReadThrough? = nil)

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let authenticated = try container.decode(Bool.self, forKey: .authenticated)
        let suppliedKeys = Set(try decoder.container(keyedBy: AuthStatusCodingKey.self).allKeys.map(\.stringValue))
        if authenticated {
            guard suppliedKeys == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Authenticated status requires exact fields including CLI store read-through")
                )
            }
            self = .authenticated(
                principalId: try container.decode(UUID.self, forKey: .principalId),
                runtimeId: try container.decode(UUID.self, forKey: .runtimeId),
                accessMode: try container.decode(IPCAccessMode.self, forKey: .accessMode),
                cliStoreReadThrough: try container.decodeIfPresent(
                    IPCCLIStoreReadThrough.self, forKey: .cliStoreReadThrough)
            )
        } else {
            guard suppliedKeys == [CodingKeys.authenticated.rawValue] else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unauthenticated status carries no principal fields")
                )
            }
            self = .unauthenticated
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unauthenticated:
            try container.encode(false, forKey: .authenticated)
        case .authenticated(let principalId, let runtimeId, let accessMode, let cliStoreReadThrough):
            try container.encode(true, forKey: .authenticated)
            try container.encode(principalId, forKey: .principalId)
            try container.encode(runtimeId, forKey: .runtimeId)
            try container.encode(accessMode, forKey: .accessMode)
            if let cliStoreReadThrough {
                try container.encode(cliStoreReadThrough, forKey: .cliStoreReadThrough)
            } else {
                try container.encodeNil(forKey: .cliStoreReadThrough)
            }
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(
                    name: "authenticated", description: "No authenticated principal is attached",
                    schema: .booleanConstant(false))
            ]),
            .object(fields: [
                .init(
                    name: "authenticated", description: "An authenticated principal is attached",
                    schema: .booleanConstant(true)),
                .init(name: "principalId", description: "Authenticated principal UUID", schema: IPCSchemaScalars.uuid),
                .init(
                    name: "runtimeId", description: "Issuing application runtime UUID", schema: IPCSchemaScalars.uuid),
                .init(
                    name: "accessMode", description: "Authenticated IPC access mode",
                    schema: try IPCAccessMode.ipcSchema()),
                .init(
                    name: "cliStoreReadThrough", description: "Store-bound handled prefixes, or null when unavailable",
                    schema: .oneOf([try IPCCLIStoreReadThrough.ipcSchema(), .null])),
            ]),
        ])
    }

    private enum CodingKeys: String, CodingKey, CaseIterable, Hashable {
        case authenticated
        case principalId
        case runtimeId
        case accessMode
        case cliStoreReadThrough
    }
}

private struct AuthStatusCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

package struct IPCEventsSubscribeParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let eventNames: [IPCEventName]
    package let correlationId: UUID

    package init(eventNames: [IPCEventName], correlationId: UUID) {
        self.eventNames = eventNames
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "eventNames", description: "Non-empty event names included in the subscription",
                schema: .array(items: try IPCEventName.ipcSchema(), minimumCount: 1)),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

package struct IPCEventsUnsubscribeParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let subscriptionId: UUID
    package let correlationId: UUID

    package init(subscriptionId: UUID, correlationId: UUID) {
        self.subscriptionId = subscriptionId
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "subscriptionId", description: "Subscription UUID to remove", schema: IPCSchemaScalars.uuid),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

package struct IPCEventsUnsubscribeResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let unsubscribed: Bool
    package let subscriptionId: UUID

    package init(subscriptionId: UUID) {
        unsubscribed = true
        self.subscriptionId = subscriptionId
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Bool.self, forKey: .unsubscribed) else {
            throw DecodingError.dataCorruptedError(
                forKey: .unsubscribed,
                in: container,
                debugDescription: "Unsubscribe success must be true"
            )
        }
        unsubscribed = true
        subscriptionId = try container.decode(UUID.self, forKey: .subscriptionId)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(true, forKey: .unsubscribed)
        try container.encode(subscriptionId, forKey: .subscriptionId)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "unsubscribed", description: "Successful unsubscribe discriminator",
                schema: .booleanConstant(true)),
            .init(name: "subscriptionId", description: "Removed subscription UUID", schema: IPCSchemaScalars.uuid),
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case unsubscribed
        case subscriptionId
    }
}
