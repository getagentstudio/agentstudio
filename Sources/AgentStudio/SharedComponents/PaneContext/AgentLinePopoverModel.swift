import AgentStudioInfrastructure
import Foundation

package struct AgentLinePopoverModel: Sendable, Equatable {
    package let summary: String
    package let refs: [MessageActionModel]
    package let writer: MessageSenderModel
    package let updatedAt: Date
    package private(set) var age: AgeTextModel

    package init(
        summary: String, refs: [MessageActionModel], writer: MessageSenderModel,
        updatedAt: Date, age: AgeTextModel
    ) {
        self.summary = summary
        self.refs = refs
        self.writer = writer
        self.updatedAt = updatedAt
        self.age = age
    }

    package func replacingAge(_ age: AgeTextModel) -> Self {
        var copy = self
        copy.age = age
        return copy
    }
}

package struct ProviderPromptRowModel: Sendable, Equatable {
    package let sourcePaneId: UUID
    package let sourceLabel: String?
    package let ordinal: Int
    package let reasonText: String
    package let observedAt: Date
    package let summary: String?
    package let body: String
    package let detailsTitle: String
    package let bodyFont: PaneContextMessageBodyFont
    package let bodyText: PaneContextMessageBodyText
    package private(set) var bodyLayout: PaneContextMessageBodyLayout = .pendingWidth
    package var textBodyKey: PaneContextTextBodyKey { .providerPrompt(source: sourcePaneId, ordinal: ordinal) }
    package let kindIcon: PaneContextControlModel.Icon
    package private(set) var age: AgeTextModel

    package init(
        sourcePaneId: UUID, sourceLabel: String?, ordinal: Int, reasonText: String, observedAt: Date,
        summary: String?, kindIcon: PaneContextControlModel.Icon, age: AgeTextModel
    ) {
        self.sourcePaneId = sourcePaneId
        self.sourceLabel = sourceLabel
        self.ordinal = ordinal
        self.reasonText = reasonText
        self.observedAt = observedAt
        self.summary = summary
        let body = summary.map { reasonText + ": " + $0 } ?? reasonText
        self.body = body
        bodyFont = .proportional(pointSize: AppStyles.General.Typography.textSm)
        bodyText = .init(body, font: bodyFont)
        detailsTitle =
            bodyText.plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? bodyText.plainText
        self.kindIcon = kindIcon
        self.age = age
    }

    package func replacingBodyLayout(_ layout: PaneContextMessageBodyLayout) -> Self {
        var copy = self
        copy.bodyLayout = layout
        return copy
    }

    package func replacingAge(_ age: AgeTextModel) -> Self {
        var copy = self
        copy.age = age
        return copy
    }
}
