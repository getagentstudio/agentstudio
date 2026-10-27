import Foundation

/// Sessions derives this cohesive read model before publication.
package struct PaneAgentStatusPresentation: Sendable, Equatable {
    package let status: AgentSessionStatus
    package let connectionIssue: AgentConnectionRefusalReason?
    package let evidence: StatusEvidence
    package let compactPrompt: CompactProviderPrompt?
    package let promptListRevision: UInt64
    /// The Sessions owner's current binding identity; runtime-only, never historical or IPC.
    package let currentBindingId: UUID?

    package init(
        status: AgentSessionStatus, connectionIssue: AgentConnectionRefusalReason? = nil,
        evidence: StatusEvidence = .none, compactPrompt: CompactProviderPrompt? = nil, promptListRevision: UInt64 = 0,
        currentBindingId: UUID? = nil
    ) {
        self.status = status
        self.connectionIssue = connectionIssue
        self.evidence = evidence
        self.compactPrompt = compactPrompt
        self.promptListRevision = promptListRevision
        self.currentBindingId = currentBindingId
    }
}

package enum StatusEvidence: Sendable, Equatable {
    case verifiedLive, verifiedEnded, unverified
    // swiftlint:disable:next discouraged_none_name
    case none
}

package struct CompactProviderPrompt: Sendable, Equatable {
    package let reason: AskReason
    package let summary: String?
    package let observedAt: Date
    package let omittedOrFurtherCount: Int

    package init(reason: AskReason, summary: String?, observedAt: Date, omittedOrFurtherCount: Int) {
        self.reason = reason
        self.summary = summary
        self.observedAt = observedAt
        self.omittedOrFurtherCount = omittedOrFurtherCount
    }
}

package enum AgentConnectionRefusalReason: String, Sendable, Equatable, CaseIterable {
    case credentialNotRecognized, paneNotFound, paneRetired, otherWorkspace, intentRequiresToken
    case noSessionId, undecodablePayload, queueFull, appUnavailable, deadlineExceeded, orderingStoreUnavailable
}

package enum AgentCallIntent: String, Sendable, Equatable {
    case status, identity, message, read, control
}
