import Foundation

struct PaneContextRetentionMessage: Sendable {
    enum ParentTable: Hashable, Sendable {
        case request
        case notice

        var name: String {
            switch self {
            case .request: "pane_request"
            case .notice: "pane_event"
            }
        }
    }

    struct Key: Hashable, Sendable {
        let table: ParentTable
        let rowId: UUID
    }

    var key: Key { Key(table: table, rowId: rowId) }

    let rowId: UUID
    let position: UInt64
    let settledAt: Date?
    let displayHidden: Bool
    let table: ParentTable
}

extension PaneContextRetentionMessage {
    init(_ message: PaneContextStoredMessage) {
        rowId = message.rowId
        position = message.position
        settledAt = message.settledAt
        displayHidden = message.displayHidden
        switch message.detail.shape {
        case .ask: table = .request
        case .notice: table = .notice
        }
    }
}
