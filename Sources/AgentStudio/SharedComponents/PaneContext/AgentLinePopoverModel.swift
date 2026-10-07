import Foundation

package struct AgentLinePopoverModel: Sendable, Equatable {
    package let summary: String
    package let work: AgentLineWorkModel
    package let detail: String?
    package let refs: [MessageActionModel]
    package let writer: MessageSenderModel
    package let updatedAt: Date
    package let lifetime: AgentLineLifetimeModel
    package let stale: Bool

    package init(
        summary: String, work: AgentLineWorkModel, detail: String?, refs: [MessageActionModel],
        writer: MessageSenderModel, updatedAt: Date, lifetime: AgentLineLifetimeModel, stale: Bool
    ) {
        self.summary = summary
        self.work = work
        self.detail = detail
        self.refs = refs
        self.writer = writer
        self.updatedAt = updatedAt
        self.lifetime = lifetime
        self.stale = stale
    }

}

package enum AgentLineWorkModel: Sendable, Equatable {
    case working(AgentLineProgressModel)
    case monitoring(String)
    case blockedOnYou(action: String)
    case done
    case failed(summary: String)
}
package enum AgentLineProgressModel: Sendable, Equatable {
    case indeterminate
    case step(current: Int, total: Int)
}
package enum AgentLineLifetimeModel: Sendable, Equatable {
    case untilReplaced
    case expires(at: Date)
}
package struct ProviderPromptsModel: Sendable, Equatable {
    package let prompts: [ProviderPromptRowModel]
    package let omittedPromptCount: Int

    package init(prompts: [ProviderPromptRowModel], omittedPromptCount: Int) {
        self.prompts = prompts
        self.omittedPromptCount = omittedPromptCount
    }

}
package struct ProviderPromptRowModel: Sendable, Equatable {
    package let reason: AskReasonModel
    package let observedAt: Date
    package let summary: String?

    package init(reason: AskReasonModel, observedAt: Date, summary: String?) {
        self.reason = reason
        self.observedAt = observedAt
        self.summary = summary
    }

}
