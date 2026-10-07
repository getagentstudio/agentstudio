import AgentStudioInfrastructure
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

/// The read filter and persistent maintenance share this one visibility decision.
func hiddenPaneContextSettledKeys(
    _ rows: [PaneContextRetentionMessage], now: Date
) -> Set<PaneContextRetentionMessage.Key> {
    let settled = rows.filter { $0.settledAt != nil && !$0.displayHidden }.sorted { $0.position > $1.position }
    return Set(
        settled.enumerated().compactMap { index, message in
            let aged =
                message.settledAt.map {
                    $0.addingTimeInterval(AppPolicies.PaneContext.settledMessageLifetime) <= now
                } == true
            return index >= AppPolicies.PaneContext.maximumSettledMessages || aged ? message.key : nil
        })
}

/// Time-derived facts participate in the existing in-memory detail revision.
struct PaneContextReadTimeVersion: Sendable, Equatable {
    let lineStale: Bool?
    let visibleSettledIds: Set<PaneContextRetentionMessage.Key>
}
