import Foundation

package struct PaneMessageSendRequest: Sendable, Equatable {
    package let paneId: PaneId
    package let messageId: AgentMessageId
    package let sender: AgentMessageSender
    package let sourceOccurredAt: Date?
    package let importance: MessageImportance
    package let body: String
    package let why: String?
    package let actions: [MessageAction]
    package let shape: PaneMessageSendShape

    package init(
        paneId: PaneId,
        messageId: AgentMessageId,
        sender: AgentMessageSender,
        sourceOccurredAt: Date?,
        importance: MessageImportance,
        body: String,
        why: String?,
        actions: [MessageAction],
        shape: PaneMessageSendShape
    ) {
        self.paneId = paneId
        self.messageId = messageId
        self.sender = sender
        self.sourceOccurredAt = sourceOccurredAt
        self.importance = importance
        self.body = body
        self.why = why
        self.actions = actions
        self.shape = shape
    }
}

package enum PaneMessageSendShape: Sendable, Equatable {
    case notice
    case ask(reason: AskReason, form: AskForm, waiting: AskWaiting)
}
package enum PaneMessageSendResult: Sendable, Equatable {
    case created(AgentMessageId)
    case existing(AgentMessageId)
    case refused(PaneContextWriteRefusal)
    case unavailable(StorageFailureSummary)
}
package enum PaneContextWriteRefusal: Sendable, Equatable {
    case conflict
    case bindingRequired
    case writerReplaced
    case paneGone
    case notSender
    case noticeAlreadyRead
    case tooLarge(PaneContextLimitField)
    case invalidField(PaneContextLimitField)
}
package enum PaneContextLimitField: Sendable, Equatable {
    case body
    case why
    case choices
    case choiceLabel
    case form
    case answer
    case actions
    case agentLine
    case title
    case openAsks
    case unreadNotices
}
package enum AskOutcome: Sendable, Equatable {
    case answered(AskAnswerValue)
    case handedBack
    case expired
    case withdrawn
    case stale
}
package enum AskSettlementCause: Sendable, Equatable {
    case answer(by: PersonActor, value: AskAnswerValue)
    case dismiss
    case deadline
    case withdraw(writer: AgentMessageSender)
    case callerGone
    case appStopping
}
package enum AskSettlementResult: Sendable, Equatable {
    case stillOpen
    case settled(AskState)
    case alreadySettled(AskState)
    case refused(AnswerRefusal)
    case notFound
    case unavailable(StorageFailureSummary)
}
package enum PaneMessageWithdrawResult: Sendable, Equatable {
    case withdrawn
    case alreadySettled(AskOrNoticeTerminal)
    case notFound
    case refused(PaneContextWriteRefusal)
    case unavailable(StorageFailureSummary)
}
