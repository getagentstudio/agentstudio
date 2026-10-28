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
        self.kindIcon = kindIcon
        self.age = age
    }

    package func replacingAge(_ age: AgeTextModel) -> Self {
        var copy = self
        copy.age = age
        return copy
    }
}
