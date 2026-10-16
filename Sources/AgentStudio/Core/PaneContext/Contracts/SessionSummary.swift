import Foundation

package struct SessionSummary: Sendable, Equatable {
    package let id: UUID
    package let provider: BridgeAgentProviderName
    package let sessionRef: BridgeAgentSessionRef
    package let bindingGeneration: UUID
    package let status: AgentSessionStatus
    package let providerPrompts: [SessionProviderPromptSummary]
    package let omittedPromptCount: Int

    package init(
        id: UUID,
        provider: BridgeAgentProviderName,
        sessionRef: BridgeAgentSessionRef,
        bindingGeneration: UUID,
        status: AgentSessionStatus,
        providerPrompts: [SessionProviderPromptSummary],
        omittedPromptCount: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.sessionRef = sessionRef
        self.bindingGeneration = bindingGeneration
        self.status = status
        self.providerPrompts = providerPrompts
        self.omittedPromptCount = omittedPromptCount
    }
}

package struct SessionProviderPromptSummary: Sendable, Equatable {
    package let reason: AskReason
    package let observedAt: Date
    package let summary: String?

    package init(
        reason: AskReason,
        observedAt: Date,
        summary: String?
    ) {
        self.reason = reason
        self.observedAt = observedAt
        self.summary = summary
    }
}

package struct SessionFailureSummary: Sendable, Equatable {
    package let category: String

    package init(
        category: String
    ) {
        self.category = category
    }
}

package enum AgentSessionStatus: Sendable, Equatable {
    case needsYou(AskReason)
    case failed(SessionFailureSummary)
    case working(SessionWorkingState)
    case idle(SessionIdleState)
    case unknown
}
package enum SessionWorkingState: Sendable, Equatable {
    case active
    case monitoring
}
package enum SessionIdleState: Sendable, Equatable {
    case done
    case ready
    case interrupted
    case ended
}
