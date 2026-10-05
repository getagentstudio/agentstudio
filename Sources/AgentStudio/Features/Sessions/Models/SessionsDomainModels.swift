import Foundation

package enum SessionsEvidenceOrigin: String, Sendable, Codable, Equatable, CaseIterable {
    case estimated
    case agentReported
    case reported

}

// Kept for the pre-cut loss rows and existing queue-depth probe until Unit 4.
package enum SessionsLossReason: String, Sendable, Codable, Equatable {
    case paneQueueFull, globalQueueFull
}

package enum SessionsEvidenceSubject: Sendable, Codable, Equatable, Hashable {
    case root
    case tool(String)
    case subagent(String)

    var kind: String {
        switch self {
        case .root: "root"
        case .tool: "tool"
        case .subagent: "subagent"
        }
    }

    var identifier: String? {
        switch self {
        case .root: nil
        case .tool(let identifier), .subagent(let identifier): identifier
        }
    }

    var storageKey: String {
        switch self {
        case .root: "root"
        case .tool(let identifier): "tool:\(identifier)"
        case .subagent(let identifier): "subagent:\(identifier)"
        }
    }
}

package enum SessionsEvidenceKind: Sendable, Codable, Equatable {
    case activityStarted
    case completed
    case aborted
    case needsYouOpened(requestId: String, explanation: String?)
    case needsYouResolved(requestId: String)

    var storageKind: String {
        switch self {
        case .activityStarted: "activityStarted"
        case .completed: "completed"
        case .aborted: "aborted"
        case .needsYouOpened: "needsYouOpened"
        case .needsYouResolved: "needsYouResolved"
        }
    }
}

package struct SessionsEvidenceRecord: Sendable, Codable, Equatable {
    package let recordId: UUID
    package let conversationId: UUID
    package let bindingGenerationId: UUID
    package let sourceGenerationId: UUID
    package let turnId: String?
    package let subject: SessionsEvidenceSubject
    package let kind: SessionsEvidenceKind
    package let origin: SessionsEvidenceOrigin
    package let statusEffect: SessionsEvidenceStatusEffect
    package let occurredAt: Date
    package var admissionSequence: Int64?
    package var providerSignal: SessionProviderSignal?

}

package enum SessionsAttentionDisposition: String, Sendable, Codable, Equatable {
    case current
    case resolved
    case stale
}

package struct SessionsAttentionProjection: Sendable, Codable, Equatable {
    package let id: UUID
    package let requestId: String
    package let explanation: String?
    package let sourceGenerationId: UUID
    package let turnId: String?
    package let subject: SessionsEvidenceSubject
    package let origin: SessionsEvidenceOrigin
    package let freshness: String
    package let disposition: SessionsAttentionDisposition
    package let openedOccurrenceId: UUID
    package let openedAt: Date
}

package enum SessionsBindingStatus: String, Sendable, Codable, Equatable {
    case active
    case ended
}

package struct SessionsBindingRecord: Sendable, Codable, Equatable {
    package let bindingGenerationId: UUID
    package let paneId: UUID
    package let conversationId: UUID
    package let providerIdentifier: String
    package let providerConversationId: String
    package let sourceGenerationId: UUID
    package let transitionOccurrenceId: UUID
    package let origin: SessionsEvidenceOrigin
    package let status: SessionsBindingStatus
    package let startedAt: Date
    package let endedAt: Date?
    package var resumeHint: String?
    package var ownerPaneId: UUID?
}

package enum SessionsSeenDisposition: String, Sendable, Codable, Equatable {
    case unseen
    case seen
}

package struct SessionsResultRecord: Sendable, Codable, Equatable {
    package let id: UUID
    package let conversationId: UUID
    package let bindingGenerationId: UUID
    package let sourceGenerationId: UUID
    package let turnId: String
    package let subject: SessionsEvidenceSubject
    package let completionOccurrenceId: UUID
    package let origin: SessionsEvidenceOrigin
    package let freshness: String
    package let disposition: SessionsSeenDisposition
    package let seenAt: Date?
    package let createdAt: Date
    package let updatedAt: Date
}

package struct SessionsSnapshot: Sendable, Equatable {
    package let revision: Int64
    package let currentBinding: SessionsBindingRecord?
    package let staleAttention: [SessionsAttentionProjection]
    package let results: [SessionsResultRecord]
    package let historicalOccurrenceIds: [UUID]
    package let losses: [SessionsLossRecord]
}

package enum SessionsRepositoryError: Error, Sendable, Equatable {
    case invalidStoredValue(String)
    case ingestionFinished
    case paneQueueFull(UUID)
    case globalQueueFull
}

package enum SessionsSnapshotQuery: Sendable, Equatable {
    case pane(UUID)
    package init(paneId: UUID) { self = .pane(paneId) }
}
