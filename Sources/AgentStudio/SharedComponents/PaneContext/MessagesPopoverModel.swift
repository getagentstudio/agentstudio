import Foundation

package struct MessagesPopoverModel: Sendable, Equatable {
    package let partitions: MessagePartitionModel
    package let pages: [MessagePageCursorModel]
    package let remainingLiveSources: Int
    package let nextSourcesAfter: UUID?

    package init(
        partitions: MessagePartitionModel, pages: [MessagePageCursorModel], remainingLiveSources: Int,
        nextSourcesAfter: UUID?
    ) {
        self.partitions = partitions
        self.pages = pages
        self.remainingLiveSources = remainingLiveSources
        self.nextSourcesAfter = nextSourcesAfter
    }

}
package struct MessagePartitionModel: Sendable, Equatable {
    package let all: [MessageSourceGroupModel]
    package let needsApproval: [MessageSourceGroupModel]
    package let needsReply: [MessageSourceGroupModel]
    package let attention: [MessageSourceGroupModel]
    package let informational: [MessageSourceGroupModel]

    package init(
        all: [MessageSourceGroupModel], needsApproval: [MessageSourceGroupModel], needsReply: [MessageSourceGroupModel],
        attention: [MessageSourceGroupModel], informational: [MessageSourceGroupModel]
    ) {
        self.all = all
        self.needsApproval = needsApproval
        self.needsReply = needsReply
        self.attention = attention
        self.informational = informational
    }

    /// A UI filter selects one prepared value; it never filters message rows.
    package func groups(for attentionType: MessageAttentionTypeModel?) -> [MessageSourceGroupModel] {
        switch attentionType {
        case nil: all
        case .needsApproval: needsApproval
        case .needsReply: needsReply
        case .attention: attention
        case .informational: informational
        }
    }

}
package struct MessageSourceGroupModel: Sendable, Equatable {
    package let sourcePaneId: UUID
    package let sourceLabel: String
    package let rows: [MessageRowModel]

    package init(sourcePaneId: UUID, sourceLabel: String, rows: [MessageRowModel]) {
        self.sourcePaneId = sourcePaneId
        self.sourceLabel = sourceLabel
        self.rows = rows
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
