import Foundation

package struct AnswerPosition: Sendable, Equatable {
    package let value: UInt64

    package init(
        _ value: UInt64
    ) {
        self.value = value
    }
}

package struct PaneMessageChangesRequest: Sendable, Equatable {
    package let paneId: PaneId
    package let writer: AgentMessageSender
    package let after: AnswerPosition

    package init(
        paneId: PaneId,
        writer: AgentMessageSender,
        after: AnswerPosition
    ) {
        self.paneId = paneId
        self.writer = writer
        self.after = after
    }
}

package struct PaneMessageChangesPage: Sendable, Equatable {
    package let entries: [PaneMessageChangeEntry]
    package let nextPosition: AnswerPosition
    package let more: Bool

    package init(
        entries: [PaneMessageChangeEntry],
        nextPosition: AnswerPosition,
        more: Bool
    ) {
        self.entries = entries
        self.nextPosition = nextPosition
        self.more = more
    }
}

package struct PaneMessageChangeEntry: Sendable, Equatable {
    package let id: UUID
    package let position: AnswerPosition
    package let messageId: AgentMessageId
    package let kind: PaneMessageChangeKind

    package init(
        id: UUID,
        position: AnswerPosition,
        messageId: AgentMessageId,
        kind: PaneMessageChangeKind
    ) {
        self.id = id
        self.position = position
        self.messageId = messageId
        self.kind = kind
    }
}

package enum PaneMessageChangeKind: Sendable, Equatable {
    case answer(AskAnswerValue)
    case dismissal
    case withdrawal
}
package enum PaneMessageChangesResult: Sendable, Equatable {
    case page(PaneMessageChangesPage)
    case refused(PaneContextWriteRefusal)
    case unavailable(StorageFailureSummary)
}
