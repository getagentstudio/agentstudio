import Foundation

package enum SessionsEvidenceOrigin: String, Sendable, Codable, Equatable, CaseIterable {
    case estimated
    case agentReported
    case reported
}

// Queue-capacity probe reasons; no loss rows are written.
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
}

package enum SessionsEvidenceKind: Sendable, Codable, Equatable {
    case activityStarted
    case completed
    case aborted
    case needsYouOpened
    case needsYouResolved

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

package enum SessionsRepositoryError: Error, Sendable, Equatable {
    case invalidStoredValue(String)
    case ingestionFinished
    case paneQueueFull(UUID)
    case globalQueueFull
}
