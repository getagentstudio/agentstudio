import Foundation

package struct MessagesPopoverModel: Sendable, Equatable {
    package let groups: [MessagesGroupModel]
    package let pages: [MessagePageCursorModel]
    package let remainingLiveSources: Int
    package let nextSourcesAfter: UUID?
    package let hasNotices: Bool
    package let unreadCount: Int
    package let filters: [MessagesFilterModel]

    package init(
        groups: [MessagesGroupModel], pages: [MessagePageCursorModel], remainingLiveSources: Int,
        nextSourcesAfter: UUID?, hasNotices: Bool, unreadCount: Int, filters: [MessagesFilterModel]
    ) {
        self.groups = groups
        self.pages = pages
        self.remainingLiveSources = remainingLiveSources
        self.nextSourcesAfter = nextSourcesAfter
        self.hasNotices = hasNotices
        self.unreadCount = unreadCount
        self.filters = filters
    }

    /// Age and body-layout changes replace rows without changing scoped counts or group membership.
    package func replacingGroups(_ groups: [MessagesGroupModel]) -> Self {
        let replacements = Dictionary(uniqueKeysWithValues: groups.map { ($0.kind, $0) })
        let filters = filters.map { filter in
            MessagesFilterModel(
                id: filter.id, control: filter.control,
                groups: filter.groups.compactMap { replacements[$0.kind] }, kind: filter.kind,
                isEnabled: filter.isEnabled,
                noLoadedContent: filter.noLoadedContent)
        }
        return .init(
            groups: groups, pages: pages, remainingLiveSources: remainingLiveSources,
            nextSourcesAfter: nextSourcesAfter, hasNotices: hasNotices, unreadCount: unreadCount, filters: filters)
    }
}

/// Each opening owns an include mask: all four bits show all types, zero shows no rows.
package struct MessagesFilterModel: Sendable, Equatable, Identifiable {
    package static let chipMemberships = [1, 2, 4, 8]
    package let id: Int
    package let control: PaneContextControlModel
    package let groups: [MessagesGroupModel]
    package let kind: KindChipModel.Kind?
    package let isEnabled: Bool
    package let bodyLayoutsAreReady: Bool
    package let noLoadedContent: PaneContextControlModel?
    package init(
        id: Int, control: PaneContextControlModel, groups: [MessagesGroupModel], kind: KindChipModel.Kind? = nil,
        isEnabled: Bool,
        noLoadedContent: PaneContextControlModel?
    ) {
        self.id = id
        self.control = control
        self.groups = groups
        bodyLayoutsAreReady = groups.allSatisfy { $0.items.allSatisfy(Self.hasPreparedBody) }
        self.kind = kind
        self.isEnabled = isEnabled
        self.noLoadedContent = noLoadedContent
    }

    private static func hasPreparedBody(_ item: MessagesListItemModel) -> Bool {
        let layout: PaneContextMessageBodyLayout
        switch item {
        case .message(let row): layout = row.bodyLayout
        case .providerPrompt(let prompt): layout = prompt.bodyLayout
        }
        if case .ready = layout { return true }
        return false
    }
}

package struct MessagesGroupModel: Sendable, Equatable {
    package enum Header: Sendable, Equatable {
        case plain
        case kindChip(KindChipModel, PaneContextControlModel)
    }
    package enum Kind: String, Hashable, Sendable {
        case failed, needsYou, done, info, resolved
        package var title: String {
            switch self {
            case .failed: "Failed"
            case .needsYou: "Needs you"
            case .done: "Done"
            case .info: "Info"
            case .resolved: "Resolved"
            }
        }
    }
    package let kind: Kind
    package let items: [MessagesListItemModel]
    package let omittedPromptCount: Int
    package let header: Header
    package init(kind: Kind, items: [MessagesListItemModel], omittedPromptCount: Int, header: Header = .plain) {
        self.kind = kind
        self.items = items
        self.omittedPromptCount = omittedPromptCount
        self.header = header
    }
}

package enum MessagesListItemModel: Sendable, Equatable, Identifiable {
    package enum ItemIdentity: Hashable, Sendable {
        case message(MessageRowModel.Key)
        case providerPrompt(source: UUID, ordinal: Int)
    }
    case message(MessageRowModel)
    case providerPrompt(ProviderPromptRowModel)
    package var id: ItemIdentity {
        switch self {
        case .message(let row): .message(row.key)
        case .providerPrompt(let row): .providerPrompt(source: row.sourcePaneId, ordinal: row.ordinal)
        }
    }
}

package struct MessagePageCursorModel: Sendable, Equatable {
    package let sourcePaneId: UUID
    package let rank: Int
    package let position: UInt64
    package let openAsks: Int
    package let unreadNotices: Int
    package init(sourcePaneId: UUID, rank: Int, position: UInt64, openAsks: Int, unreadNotices: Int) {
        self.sourcePaneId = sourcePaneId
        self.rank = rank
        self.position = position
        self.openAsks = openAsks
        self.unreadNotices = unreadNotices
    }
}
