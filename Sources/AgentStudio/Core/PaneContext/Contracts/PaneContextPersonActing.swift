import Foundation

package struct AnswerAskRequest: Sendable, Equatable {
    package let messageId: AgentMessageId
    package let paneId: PaneId
    package let by: PersonActor
    package let value: AskAnswerValue

    package init(
        messageId: AgentMessageId,
        paneId: PaneId,
        by: PersonActor,
        value: AskAnswerValue
    ) {
        self.messageId = messageId
        self.paneId = paneId
        self.by = by
        self.value = value
    }
}

package struct MessageActionRequest: Sendable, Equatable {
    package let messageId: AgentMessageId
    package let paneId: PaneId
    package let action: MessageAction

    package init(
        messageId: AgentMessageId,
        paneId: PaneId,
        action: MessageAction
    ) {
        self.messageId = messageId
        self.paneId = paneId
        self.action = action
    }
}

package protocol PaneContextPersonActing: Sendable {
    func answer(_ request: AnswerAskRequest) async -> AnswerAskResult
    func dismiss(messageId: AgentMessageId, paneId: PaneId) async -> DismissResult
    func dismissAllNotices(paneId: PaneId, includingDrawers: Bool) async -> DismissAllNoticesResult
    func markRead(messageId: AgentMessageId, paneId: PaneId) async -> MarkReadResult
    func runAction(_ request: MessageActionRequest) async -> MessageActionResult
}
package enum PersonActor: Sendable, Equatable {
    case localUser
}
package enum AnswerAskResult: Sendable, Equatable {
    case answered
    case refused(AnswerRefusal)
    case unavailable(StorageFailureSummary)
}
package enum AnswerRefusal: Sendable, Equatable {
    case alreadyAnswered
    case handedBack
    case dismissed
    case expired
    case withdrawn
    case stale
    case notFound
    case invalidAnswer(AnswerInvalidity)
}
package enum AnswerInvalidity: Sendable, Equatable {
    case formMismatch
    case unknownChoice(AskChoiceId)
    case choiceCount
    case textTooLarge
    case invalidField(String)
}
package enum DismissResult: Sendable, Equatable {
    case done
    case alreadySettled(AskOrNoticeTerminal)
    case notFound
    case unavailable(StorageFailureSummary)
}
package enum DismissAllNoticesResult: Sendable, Equatable {
    case dismissed(count: Int)
    case unavailable(StorageFailureSummary)
}
package enum AskOrNoticeTerminal: Sendable, Equatable {
    case ask(AskTerminalState)
    case notice(NoticeTerminalState)
}
package enum AskTerminalState: Sendable, Equatable {
    case answered(by: PersonActor, value: AskAnswerValue, receipt: AnswerReceipt)
    case handedBack
    case dismissed
    case expired
    case withdrawn
    case stale
}
package enum NoticeTerminalState: Sendable, Equatable {
    case dismissed
    case withdrawn
}
package enum MarkReadResult: Sendable, Equatable {
    case done
    case alreadyRead
    case notFound
    case unavailable(StorageFailureSummary)
}
package enum MessageActionResult: Sendable, Equatable {
    case openPullRequest(ForgeOpenOutcome)
    case goToPane(PaneFocusOutcome)
    case openFile(BridgeAgentShowResult)
    case notFound
    case unavailable(StorageFailureSummary)
}
package enum ForgeOpenOutcome: Sendable, Equatable {
    case opened
    case notFound
    case failed
}
package enum PaneFocusOutcome: Sendable, Equatable {
    case focused
    case paneGone
}
/// The PD's contract name reuses Bridge's existing five-case show reply.
package typealias BridgeAgentShowResult = BridgeAgentShowReply
package enum StorageFailureSummary: Sendable, Equatable {
    case databaseUnavailable
    case commitFailed
    case decodeFailed(String)
}
