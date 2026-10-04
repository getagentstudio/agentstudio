import Foundation

/// Documented failure reasons the session methods declare. The descriptor's
/// error catalog, the app's error payload and the CLI's one-line model reply
/// all read these constants so the wire reason cannot drift between them.
package enum IPCSessionFailureReason {
    package static let bindingRequired = "bindingRequired"
    package static let correlationConflict = "correlationConflict"
}

/// Wire projection of the Sessions agent state. It mirrors the domain states
/// without exporting the domain type across the protocol boundary.
package enum IPCSessionAgentState: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case unknown
    case running
    case needsYou
    case done
}

/// Server-assigned evidence origin. `unknown` reports the absence of a state
/// origin rather than inventing a weaker one.
package enum IPCSessionEvidenceOrigin: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case unknown
    case estimated
    case agentReported
    case reported
}

/// Lifecycle capability a provider hook claims for one projected event.
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

/// Admission disposition for one projected provider event. Only an exactly
/// qualified provider/version/mode/capability is admitted.
package enum IPCSessionEventDisposition: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case admitted
    case unknownCapability
    case unqualified
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
    package var sourceOccurredAt: Date? { providerFields.sourceOccurredAt }

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
        case sourceOccurredAt, resumeHint
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
    package var sourceOccurredAt: Date?
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

package struct IPCSessionAttentionProjection: Codable, Equatable, Sendable {
    package let requestId: String
    package let explanation: String?

    package init(requestId: String, explanation: String?) {
        self.requestId = requestId
        self.explanation = explanation
    }
}

package struct IPCSessionMessageProjection: Codable, Equatable, Sendable {
    package let occurrenceId: UUID
    package let text: String
    package let seen: Bool
    package let receivedAt: Date

    package init(occurrenceId: UUID, text: String, seen: Bool, receivedAt: Date) {
        self.occurrenceId = occurrenceId
        self.text = text
        self.seen = seen
        self.receivedAt = receivedAt
    }
}

package struct IPCSessionQueryResult: Codable, Equatable, Sendable {
    package let paneId: UUID
    package let state: IPCSessionAgentState
    package let origin: IPCSessionEvidenceOrigin
    package let needsYou: IPCSessionAttentionProjection?
    package let messages: [IPCSessionMessageProjection]
    package let sourceHealth: IPCSessionSourceHealth

    package init(
        paneId: UUID,
        state: IPCSessionAgentState,
        origin: IPCSessionEvidenceOrigin,
        needsYou: IPCSessionAttentionProjection?,
        messages: [IPCSessionMessageProjection],
        sourceHealth: IPCSessionSourceHealth
    ) {
        self.paneId = paneId
        self.state = state
        self.origin = origin
        self.needsYou = needsYou
        self.messages = messages
        self.sourceHealth = sourceHealth
    }
}
