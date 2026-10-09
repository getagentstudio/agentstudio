import Foundation

package struct MessageRowModel: Sendable, Equatable {
    package let id: UUID
    package let sourcePaneId: UUID
    package let sourcePaneLabel: String
    package let sender: MessageSenderModel
    package let sentAt: Date
    package let sourceOccurredAt: Date?
    package let body: String
    package let why: String?
    package let importance: MessageImportanceModel
    package let attentionType: MessageAttentionTypeModel
    package let isOutstanding: Bool
    package let shape: MessageShapeModel
    package let actions: [MessageActionModel]

    package init(
        id: UUID, sourcePaneId: UUID, sourcePaneLabel: String, sender: MessageSenderModel, sentAt: Date,
        sourceOccurredAt: Date?, body: String, why: String?, importance: MessageImportanceModel,
        attentionType: MessageAttentionTypeModel, isOutstanding: Bool, shape: MessageShapeModel,
        actions: [MessageActionModel]
    ) {
        self.id = id
        self.sourcePaneId = sourcePaneId
        self.sourcePaneLabel = sourcePaneLabel
        self.sender = sender
        self.sentAt = sentAt
        self.sourceOccurredAt = sourceOccurredAt
        self.body = body
        self.why = why
        self.importance = importance
        self.attentionType = attentionType
        self.isOutstanding = isOutstanding
        self.shape = shape
        self.actions = actions
    }

}

package enum MessageSenderModel: Sendable, Equatable {
    case session(provider: String, sessionRef: String, bindingGeneration: UUID)
    case pane(UUID)
}
package enum MessageImportanceModel: Sendable, Equatable {
    case info
    case attention
    case done
    case failure
}
package enum MessageAttentionTypeModel: Sendable, Equatable {
    case needsApproval
    case needsReply
    case attention
    case informational
}
package enum MessageShapeModel: Sendable, Equatable {
    case notice(NoticeStateModel)
    case ask(reason: AskReasonModel, form: AskFormModel, waiting: AskWaitingModel, state: AskStateModel)
}
package enum NoticeStateModel: Sendable, Equatable {
    case unread
    case read
    case dismissed
    case withdrawn
}
package enum MessageActionModel: Sendable, Equatable {
    case openFile(path: String, line: Int?)
    case openPullRequest(PullRequestIdentityModel)
    case goToPane(UUID)
}
package struct PullRequestIdentityModel: Sendable, Equatable {
    package let host: String
    package let owner: String
    package let repository: String
    package let number: Int

    package init(host: String, owner: String, repository: String, number: Int) {
        self.host = host
        self.owner = owner
        self.repository = repository
        self.number = number
    }

}
