import Foundation
import GRDB

struct PaneContextDisplaySnapshot: Sendable {
    let title: String?
    let line: AgentLineDetail?
    let sourceRevisions: [PaneContextRevision]
    let messages: [[PaneMessageCountInput]]
}

private struct PaneContextMessageProjection: Sendable {
    let counts: PaneMessageCountInput
    let retention: PaneContextRetentionMessage
}

func capturePaneContextDisplay(
    _ database: Database, paneId: PaneId, sources: [PaneId], now: @Sendable () -> Date
) throws -> PaneContextDisplaySnapshot? {
    guard try !PaneContextStorage.isRetired(database, paneId: paneId) else { return nil }
    try PaneContextStorage.expireLines(database, now: now(), sources: sources)
    let messages: [[PaneMessageCountInput]] = try sources.map { source in
        guard try !PaneContextStorage.isRetired(database, paneId: source) else { return [] }
        let rows = try PaneContextStorage.messageProjections(database, paneId: source)
        let hidden = try PaneContextStorage.hideSettled(
            database, paneId: source, rows: rows.map(\.retention), now: now())
        return rows.filter { !$0.retention.displayHidden && !hidden.contains($0.retention.key) }.map(\.counts)
    }
    return PaneContextDisplaySnapshot(
        title: try PaneContextStorage.title(database, paneId: paneId),
        line: try PaneContextStorage.line(database, paneId: paneId),
        sourceRevisions: try sources.map { try PaneContextStorage.revision(database, paneId: $0) },
        messages: messages)
}

extension PaneContextStorage {
    fileprivate static func messageProjections(_ database: Database, paneId: PaneId) throws
        -> [PaneContextMessageProjection]
    {
        let common = """
            id, pane_id, message_id, position, sent_at, settled_at, display_hidden, importance,
            sender_kind, sender_pane_id, sender_provider, sender_session_ref, sender_binding_generation
            """
        let requests = try database.cachedStatement(
            sql: """
                SELECT \(common), waiting, deadline, state, reason, form_kind, answered_by, answer_kind, receipt, receipt_at
                FROM pane_request WHERE pane_id = ? AND display_hidden = 0
                """)
        let notices = try database.cachedStatement(
            sql: """
                SELECT \(common), notice_state FROM pane_event
                WHERE pane_id = ? AND kind = 'notice' AND display_hidden = 0
                """)
        return try Row.fetchAll(requests, arguments: [paneId.uuidString]).map {
            try messageProjection($0, table: .request)
        }
            + Row.fetchAll(notices, arguments: [paneId.uuidString]).map { try messageProjection($0, table: .notice) }
    }

    private static func messageProjection(_ row: Row, table: PaneContextRetentionMessage.ParentTable) throws
        -> PaneContextMessageProjection
    {
        let importance = try importance(row)
        _ = try sender(row, prefix: "sender")
        let kind: AgentMessageAttentionType.ClassificationShape
        let outstanding: Bool
        switch table {
        case .request:
            _ = try reason(row)
            _ = try formKind(row)
            let waiting = try askWaiting(row)
            if case .blocking = waiting { kind = .blockingAsk } else { kind = .nonBlockingAsk }
            let state: String = try required(row, "state")
            switch state {
            case "open": outstanding = true
            case "answered":
                guard try required(row, "answered_by") as String == "localUser" else {
                    throw PaneContextStorageFailure.decode("answered_by")
                }
                let answerKind: String = try required(row, "answer_kind")
                guard ["text", "choices", "form"].contains(answerKind) else {
                    throw PaneContextStorageFailure.decode("answer_kind")
                }
                _ = try answerReceipt(row)
                outstanding = false
            case "handedBack", "dismissed", "expired", "withdrawn", "stale": outstanding = false
            default: throw PaneContextStorageFailure.decode("state")
            }
        case .notice:
            kind = .notice
            outstanding = try noticeState(row) == .unread
        }
        let position = try unsigned(row, "position")
        let displayHidden = try flag(row, "display_hidden")
        return PaneContextMessageProjection(
            counts: PaneMessageCountInput(
                id: AgentMessageId(existingUUID: try uuid(row, "message_id")),
                sourcePaneId: PaneId(existingUUID: try uuid(row, "pane_id")), sentAt: try date(row, "sent_at"),
                position: position, displayHidden: displayHidden,
                attention: outstanding ? AgentMessageAttentionType.classify(kind: kind, importance: importance) : nil),
            retention: PaneContextRetentionMessage(
                rowId: try uuid(row, "id"), position: position, settledAt: try optionalDate(row, "settled_at"),
                displayHidden: displayHidden, table: table))
    }

    static func askWaiting(_ row: Row) throws -> AskWaiting {
        let kind: String = try required(row, "waiting")
        switch kind {
        case "nonBlocking": return .nonBlocking
        case "blocking": return .blocking(deadline: try date(row, "deadline"))
        default: throw PaneContextStorageFailure.decode("waiting")
        }
    }

    static func noticeState(_ row: Row) throws -> NoticeState {
        let kind: String = try required(row, "notice_state")
        switch kind {
        case "unread": return .unread
        case "read": return .read
        case "dismissed": return .dismissed
        case "withdrawn": return .withdrawn
        default: throw PaneContextStorageFailure.decode("notice_state")
        }
    }
}
