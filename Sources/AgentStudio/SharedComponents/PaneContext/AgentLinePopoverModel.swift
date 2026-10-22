import Foundation

package struct AgentLinePopoverModel: Sendable, Equatable {
    package let summary: String
    package let refs: [MessageActionModel]
    package let writer: MessageSenderModel
    package let updatedAt: Date

    package init(summary: String, refs: [MessageActionModel], writer: MessageSenderModel, updatedAt: Date) {
        self.summary = summary
        self.refs = refs
        self.writer = writer
        self.updatedAt = updatedAt
    }
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
