/// Sessions derives this cohesive read model before publication.
package struct PaneAgentStatusPresentation: Sendable, Equatable {
    package let status: AgentSessionStatus
    package let connectionIssue: AgentConnectionRefusalReason?

    package init(status: AgentSessionStatus, connectionIssue: AgentConnectionRefusalReason? = nil) {
        self.status = status
        self.connectionIssue = connectionIssue
    }
}

package enum AgentConnectionRefusalReason: String, Sendable, Equatable, CaseIterable {
    case credentialNotRecognized, paneNotFound, paneRetired, otherWorkspace, intentRequiresToken
    case noSessionId, undecodablePayload, queueFull, appUnavailable, deadlineExceeded, orderingStoreUnavailable
}

package enum AgentCallIntent: String, Sendable, Equatable {
    case status, identity, message, read, control
}
