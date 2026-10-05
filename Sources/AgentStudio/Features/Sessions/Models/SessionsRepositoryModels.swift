import Foundation

package enum SessionsRepositoryContextQuery: Sendable, Equatable {
    case bind(paneId: UUID, providerIdentifier: String, providerConversationId: String)
    case pane(UUID)
    case source(paneId: UUID, sourceGenerationId: UUID)
    case allActiveSources
}

package struct SessionsConversationRecord: Sendable, Equatable {
    package let id: UUID
    package let providerIdentifier: String
    package let providerConversationId: String
    package let createdAt: Date
    package let lastReportedAt: Date
}

package enum SessionsSourceStatus: String, Sendable, Equatable {
    case active
    case ended
    case lost
}

package struct SessionsSourceRecord: Sendable, Equatable {
    package let id: UUID
    package let bindingGenerationId: UUID
    package let sourceIdentifier: String
    package let sourceGenerationId: UUID
    package let providerIdentifier: String
    package let providerVersion: String
    package let providerMode: String
    package let qualification: String
    package let status: SessionsSourceStatus
    package let lastCursor: String?
    package let startedAt: Date
    package let endedAt: Date?
}

package struct SessionsStoredAttentionRecord: Sendable, Equatable {
    package let id: UUID
    package let conversationId: UUID
    package let bindingGenerationId: UUID
    package let sourceId: UUID?
    package let sourceGenerationId: UUID
    package let sourceKind: String
    package let turnId: String?
    package let subject: SessionsEvidenceSubject
    package let requestId: String
    package let attentionKind: String
    package let origin: SessionsEvidenceOrigin
    package let freshness: String
    package let explanation: String?
    package let disposition: SessionsAttentionDisposition
    package let openedOccurrenceId: UUID
    package let resolutionOccurrenceId: UUID?
    package let openedAt: Date
    package let resolvedAt: Date?

    var projection: SessionsAttentionProjection {
        SessionsAttentionProjection(
            id: id,
            requestId: requestId,
            explanation: explanation,
            sourceGenerationId: sourceGenerationId,
            turnId: turnId,
            subject: subject,
            origin: origin,
            freshness: freshness,
            disposition: disposition,
            openedOccurrenceId: openedOccurrenceId,
            openedAt: openedAt
        )
    }
}

package struct SessionsRepositoryContext: Sendable, Equatable {
    package let revision: Int64
    package let matchingConversation: SessionsConversationRecord?
    package let currentBinding: SessionsBindingRecord?
    package let bindings: [SessionsBindingRecord]
    package let sources: [SessionsSourceRecord]
    package let evidence: [SessionsEvidenceRecord]
    package let attention: [SessionsStoredAttentionRecord]
    package let results: [SessionsResultRecord]

}

package struct SessionsLossRecord: Sendable, Equatable {
    package let id: UUID
    package let paneId: UUID
    package let conversationId: UUID?
    package let bindingGenerationId: UUID?
    package let sourceGenerationId: UUID?
    package let providerIdentifier: String?
    package let eventKind: String
    package let reason: SessionsLossReason
    package let occurredAt: Date
}

package struct SessionsRepositoryReduction: Sendable, Equatable {
    package var conversationChanges: [SessionsConversationRecord] = []
    package var bindingChanges: [SessionsBindingRecord] = []
    package var sourceChanges: [SessionsSourceRecord] = []
    package var evidenceChanges: [SessionsEvidenceRecord] = []
    package var attentionChanges: [SessionsStoredAttentionRecord] = []
    package var resultChanges: [SessionsResultRecord] = []
    package var lossChanges: [SessionsLossRecord] = []
    package let outcome: SessionsHookDisposition
}
