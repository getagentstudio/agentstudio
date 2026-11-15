import Foundation

package struct MessageRowModel: Sendable, Equatable {
    package let id: UUID
    package let sourcePaneId: UUID
    package let sourceLabel: String?
    package let sender: MessageSenderModel
    package let sentAt: Date
    package let sourceOccurredAt: Date?
    package let body: String
    package let detailsTitle: String
    package let bodyFont: PaneContextMessageBodyFont
    package let bodyText: PaneContextMessageBodyText
    package private(set) var bodyLayout: PaneContextMessageBodyLayout = .pendingWidth
    package let why: String?
    package let importance: MessageImportanceModel
    package let shape: MessageShapeModel
    package let actions: [MessageActionModel]
    package let kind: MessageKindPresentationModel
    package let kindIcon: PaneContextControlModel.Icon
    package let isDimmed: Bool
    package let settledLabel: String?
    package let availability: RowActionAvailabilityModel
    package private(set) var age: AgeTextModel

    package struct Key: Hashable, Sendable {
        package let sourcePaneId: UUID
        package let messageId: UUID
        package init(sourcePaneId: UUID, messageId: UUID) {
            self.sourcePaneId = sourcePaneId
            self.messageId = messageId
        }
        package var controlScope: String { sourcePaneId.uuidString + "." + messageId.uuidString }
    }
    package var key: Key { .init(sourcePaneId: sourcePaneId, messageId: id) }

    package init(
        id: UUID, sourcePaneId: UUID, sourceLabel: String?, sender: MessageSenderModel, sentAt: Date,
        sourceOccurredAt: Date?, body: String, bodyFont: PaneContextMessageBodyFont, why: String?,
        importance: MessageImportanceModel,
        shape: MessageShapeModel, actions: [MessageActionModel], kind: MessageKindPresentationModel,
        kindIcon: PaneContextControlModel.Icon, age: AgeTextModel, isDimmed: Bool, settledLabel: String?,
        availability: RowActionAvailabilityModel
    ) {
        self.id = id
        self.sourcePaneId = sourcePaneId
        self.sourceLabel = sourceLabel
        self.sender = sender
        self.sentAt = sentAt
        self.sourceOccurredAt = sourceOccurredAt
        self.body = body
        self.bodyFont = bodyFont
        bodyText = .init(body, font: bodyFont)
        detailsTitle =
            bodyText.plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? bodyText.plainText
        self.why = why
        self.importance = importance
        self.shape = shape
        self.actions = actions
        self.kind = kind
        self.kindIcon = kindIcon
        self.age = age
        self.isDimmed = isDimmed
        self.settledLabel = settledLabel
        self.availability = availability
    }

    package func replacingAge(_ age: AgeTextModel) -> Self {
        var copy = self
        copy.age = age
        return copy
    }

    package func replacingBodyLayout(_ layout: PaneContextMessageBodyLayout) -> Self {
        var copy = self
        copy.bodyLayout = layout
        return copy
    }
}

package enum MessageKindPresentationModel: Sendable, Equatable {
    case notice(KindChipModel.Kind)
    case openAsk
    case settledAsk
}

package enum RowActionAvailabilityModel: Sendable, Equatable {
    // Settled rows have an explicit no-actions state.
    // swiftlint:disable:next discouraged_none_name
    case none
    case noticeActions
    case askForm
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
