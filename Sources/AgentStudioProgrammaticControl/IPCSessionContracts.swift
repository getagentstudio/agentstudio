import Foundation

/// Documented failure reasons the session methods declare. The descriptor's
/// error catalog, the app's error payload and the CLI's one-line model reply
/// all read these constants so the wire reason cannot drift between them.
package enum IPCSessionFailureReason {
    package static let bindingRequired = "bindingRequired"
    package static let correlationConflict = "correlationConflict"
}

/// Typed lifecycle fact reported by a provider hook.
package enum IPCSessionEventName: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case sessionStart
    case sessionEnd
    case turnStart
    case turnDone
    case turnAbort
    case turnFailed
    case permission
    case question
    case elicitation
    case elicitationResult
    case toolCompleted
    case toolFailed
    case toolActivity
    case subagentActivity
}

/// The pane-authenticated hook was recorded. Version is descriptive only.
package enum IPCSessionEventDisposition: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case admitted
}

/// Liveness of the pane's current binding and source generation.
package enum IPCSessionSourceHealth: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case unbound
    case live
    case ended
}

package struct IPCSessionProviderIdentity: Codable, Equatable, Sendable {
    package let identifier: String
    package let version: String
    package let mode: String

    package init(identifier: String, version: String, mode: String) {
        self.identifier = identifier
        self.version = version
        self.mode = mode
    }
}

package struct IPCSessionEventIdentity: Codable, Equatable, Sendable {
    package let name: IPCSessionEventName
    package let conversationId: String
    package let turnId: String?
    package let requestId: String?
    package let toolId: String?
    package let subagentId: String?
    package let occurrenceId: UUID
    package let providerFields: IPCSessionProviderEventFields

    package var toolName: String? { providerFields.toolName }
    package var questions: [IPCSessionQuestion]? { providerFields.questions }
    package var failureSummary: String? { providerFields.failureSummary }
    package var elicitationId: String? { providerFields.elicitationId }

    package init(
        name: IPCSessionEventName,
        conversationId: String,
        turnId: String?,
        requestId: String?,
        toolId: String?,
        subagentId: String?,
        occurrenceId: UUID,
        providerFields: IPCSessionProviderEventFields = .init()
    ) {
        self.name = name
        self.conversationId = conversationId
        self.turnId = turnId
        self.requestId = requestId
        self.toolId = toolId
        self.subagentId = subagentId
        self.occurrenceId = occurrenceId
        self.providerFields = providerFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, conversationId, turnId, requestId, toolId, subagentId, occurrenceId
        case toolName, questions, failureSummary, elicitationId, message
        case resumeHint
    }

    package init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        name = try fields.decode(IPCSessionEventName.self, forKey: .name)
        conversationId = try fields.decode(String.self, forKey: .conversationId)
        turnId = try fields.decodeIfPresent(String.self, forKey: .turnId)
        requestId = try fields.decodeIfPresent(String.self, forKey: .requestId)
        toolId = try fields.decodeIfPresent(String.self, forKey: .toolId)
        subagentId = try fields.decodeIfPresent(String.self, forKey: .subagentId)
        occurrenceId = try fields.decode(UUID.self, forKey: .occurrenceId)
        providerFields = try IPCSessionProviderEventFields(from: decoder)
    }

    package func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(name, forKey: .name)
        try fields.encode(conversationId, forKey: .conversationId)
        try fields.encodeIfPresent(turnId, forKey: .turnId)
        try fields.encodeIfPresent(requestId, forKey: .requestId)
        try fields.encodeIfPresent(toolId, forKey: .toolId)
        try fields.encodeIfPresent(subagentId, forKey: .subagentId)
        try fields.encode(occurrenceId, forKey: .occurrenceId)
        try providerFields.encode(to: encoder)
    }
}

package struct IPCSessionProviderEventFields: Codable, Equatable, Sendable {
    package var toolName: String?
    package var questions: [IPCSessionQuestion]?
    package var failureSummary: String?
    package var elicitationId: String?
    package var message: String?
    package var resumeHint: String?

    package init() {}
}

package struct IPCSessionQuestion: Codable, Equatable, Sendable {
    package let question: String
    package let header: String
    package let options: [IPCSessionQuestionOption]
    package let multiSelect: Bool
}

package struct IPCSessionQuestionOption: Codable, Equatable, Sendable {
    package let label: String
    package let description: String
}

package struct IPCSessionEventParams: Codable, Equatable, Sendable {
    package let handle: String
    package let provider: IPCSessionProviderIdentity
    package let event: IPCSessionEventIdentity
    package let correlationId: UUID

    package init(
        handle: String,
        provider: IPCSessionProviderIdentity,
        event: IPCSessionEventIdentity,
        correlationId: UUID
    ) {
        self.handle = handle
        self.provider = provider
        self.event = event
        self.correlationId = correlationId
    }
}

package struct IPCSessionEventResult: Codable, Equatable, Sendable {
    package let paneId: UUID
    package let disposition: IPCSessionEventDisposition
    package let correlationId: UUID

    package init(paneId: UUID, disposition: IPCSessionEventDisposition, correlationId: UUID) {
        self.paneId = paneId
        self.disposition = disposition
        self.correlationId = correlationId
    }
}

package struct IPCSessionQueryParams: Codable, Equatable, Sendable {
    package let handle: String

    package init(handle: String) {
        self.handle = handle
    }
}

package struct IPCSessionQueryResult: Codable, Equatable, Sendable {
    package let paneId: UUID
    package let sourceHealth: IPCSessionSourceHealth
    package let session: IPCPaneSessionSummary?
    package let lastRefusal: IPCSessionLastRefusal?
    package init(
        paneId: UUID, sourceHealth: IPCSessionSourceHealth, session: IPCPaneSessionSummary?,
        lastRefusal: IPCSessionLastRefusal? = nil
    ) {
        self.paneId = paneId
        self.sourceHealth = sourceHealth
        self.session = session
        self.lastRefusal = lastRefusal
    }
    private enum CodingKeys: String, CodingKey { case paneId, sourceHealth, session, lastRefusal }
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try container.decode(UUID.self, forKey: .paneId)
        sourceHealth = try container.decode(IPCSessionSourceHealth.self, forKey: .sourceHealth)
        session = try container.decode(IPCPaneSessionSummary?.self, forKey: .session)
        lastRefusal = try container.decode(IPCSessionLastRefusal?.self, forKey: .lastRefusal)
        guard (sourceHealth == .unbound) == (session == nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .session, in: container, debugDescription: "Session is null exactly when unbound")
        }
    }
    package func encode(to encoder: any Encoder) throws {
        guard (sourceHealth == .unbound) == (session == nil) else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Session is null exactly when unbound"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneId, forKey: .paneId)
        try container.encode(sourceHealth, forKey: .sourceHealth)
        try container.encode(session, forKey: .session)
        try container.encode(lastRefusal, forKey: .lastRefusal)
    }
}

package enum IPCSessionRefusalReason: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case noSessionId, undecodablePayload
}

package struct IPCSessionRefusalParams: Codable, Equatable, Sendable {
    package let handle: String
    package let reason: IPCSessionRefusalReason
    package let event: String?
    package let correlationId: UUID
    package init(handle: String, reason: IPCSessionRefusalReason, event: String? = nil, correlationId: UUID) {
        self.handle = handle
        self.reason = reason
        self.event = event
        self.correlationId = correlationId
    }
}

package struct IPCSessionRefusalResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let paneId: UUID
    package init(paneId: UUID) { self.paneId = paneId }
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [IPCSessionSchemaFields.pane])
    }
}
