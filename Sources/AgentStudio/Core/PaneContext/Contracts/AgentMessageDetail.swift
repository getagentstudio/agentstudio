import Foundation

package struct AgentMessageDetail: Sendable, Equatable {
    package let id: AgentMessageId
    package let sourcePaneId: PaneId
    package let sender: AgentMessageSender
    package let sentAt: Date
    package let sourceOccurredAt: Date?
    package let importance: MessageImportance
    package let body: String
    package let why: String?
    package let actions: [MessageAction]
    package let shape: AgentMessageShape

    package init(
        id: AgentMessageId,
        sourcePaneId: PaneId,
        sender: AgentMessageSender,
        sentAt: Date,
        sourceOccurredAt: Date?,
        importance: MessageImportance,
        body: String,
        why: String?,
        actions: [MessageAction],
        shape: AgentMessageShape
    ) {
        self.id = id
        self.sourcePaneId = sourcePaneId
        self.sender = sender
        self.sentAt = sentAt
        self.sourceOccurredAt = sourceOccurredAt
        self.importance = importance
        self.body = body
        self.why = why
        self.actions = actions
        self.shape = shape
    }
}

package struct AskChoice: Sendable, Equatable {
    package let id: AskChoiceId
    package let label: String

    package init(
        id: AskChoiceId,
        label: String
    ) {
        self.id = id
        self.label = label
    }
}

package enum AgentMessageSender: Sendable, Equatable {
    case session(provider: BridgeAgentProviderName, sessionRef: BridgeAgentSessionRef, bindingGeneration: UUID)
    case pane(PaneId)
}
package enum MessageImportance: Sendable, Equatable {
    case info
    case attention
    case done
    case failure
}
package enum MessageAction: Sendable, Equatable {
    case openFile(path: String, line: Int?)
    case openPullRequest(ForgePullRequestIdentity)
    case goToPane(PaneId)
}
package enum AgentMessageShape: Sendable, Equatable {
    case notice(NoticeState)
    case ask(AskReason, AskForm, AskWaiting, AskState)
}
package enum NoticeState: Sendable, Equatable {
    case unread
    case read
    case dismissed
    case withdrawn
}
package enum AskReason: Sendable, Equatable {
    case approval
    case question
    case blocked
}
package enum AskForm: Sendable, Equatable {
    case choice(options: [AskChoice], allowsMultiple: Bool)
    case freeText(placeholder: String?)
    case elicitation(ElicitationSchema)
}
package enum AskWaiting: Sendable, Equatable {
    case nonBlocking
    case blocking(deadline: Date)
}
package enum AskState: Sendable, Equatable {
    case open
    case answered(by: PersonActor, value: AskAnswerValue, receipt: AnswerReceipt)
    case handedBack
    case dismissed
    case expired
    case withdrawn
    case stale
}
package enum AnswerReceipt: Sendable, Equatable {
    case notYetConfirmed
    case confirmed(at: Date)
    case unconfirmed
}
package enum AskAnswerValue: Sendable, Equatable {
    case choices([AskChoiceId])
    case text(String)
    case form(ElicitationValues)
}
