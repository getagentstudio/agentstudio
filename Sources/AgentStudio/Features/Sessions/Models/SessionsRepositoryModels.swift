import Foundation

package enum SessionsRepositoryContextQuery: Sendable, Equatable {
    case bind(paneId: UUID, providerIdentifier: String, providerConversationId: String)
    case pane(UUID)
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

package struct SessionsRepositoryContext: Sendable, Equatable {
    package let revision: Int64
    package let matchingConversation: SessionsConversationRecord?
    package let currentBinding: SessionsBindingRecord?
    package let bindings: [SessionsBindingRecord]
    package let sources: [SessionsSourceRecord]
    package let evidence: [SessionsEvidenceRecord]
    /// Hydration-only provenance from the existing operation log; evidence itself is unchanged.
    package let bindingStartRecordIds: Set<UUID>
}

package struct SessionsRepositoryReduction: Sendable, Equatable {
    package var conversationChanges: [SessionsConversationRecord] = []
    package var bindingChanges: [SessionsBindingRecord] = []
    package var sourceChanges: [SessionsSourceRecord] = []
    package var evidenceChanges: [SessionsEvidenceRecord] = []
    package let outcome: SessionsHookDisposition
}

package struct SessionsBindingEndCommit: Sendable, Equatable {
    package let binding: SessionsBindingRecord
    package let revision: Int64
    package let endedAt: Date
}
