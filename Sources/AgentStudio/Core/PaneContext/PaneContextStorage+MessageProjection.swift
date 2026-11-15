import Foundation
import GRDB

struct PaneContextDisplaySnapshot: Sendable {
    let title: String?
    let line: AgentLineDetail?
    let sourceRevisions: [PaneContextRevision]
    let messages: [[PaneMessageCountInput]]
    let readTimeVersions: [PaneContextReadTimeVersion]
    let retentionChangedSources: Set<PaneId>
}

private struct PaneContextMessageProjection: Sendable {
    let counts: PaneMessageCountInput
    let retention: PaneContextRetentionMessage
}

func capturePaneContextDisplay(
    _ database: Database, paneId: PaneId, sources: [PaneId], now: @Sendable () -> Date
) throws -> PaneContextDisplaySnapshot? {
    guard try !PaneContextStorage.isRetired(database, paneId: paneId) else { return nil }
    let instant = now()
    var readTimeVersions: [PaneContextReadTimeVersion] = []
    var retentionChangedSources: Set<PaneId> = []
    let messages: [[PaneMessageCountInput]] = try sources.map { source in
        guard try !PaneContextStorage.isRetired(database, paneId: source) else {
            readTimeVersions.append(.init(visibleSettledIds: []))
            return []
        }
        let rows = try PaneContextStorage.messageProjections(database, paneId: source)
        let hidden = try PaneContextStorage.hideSettled(
            database, paneId: source, rows: rows.map(\.retention), now: instant)
        if !hidden.isEmpty { retentionChangedSources.insert(source) }
        let visible = rows.filter { !$0.retention.displayHidden && !hidden.contains($0.retention.key) }
        readTimeVersions.append(
            PaneContextReadTimeVersion(
                visibleSettledIds: Set(visible.filter { $0.retention.settledAt != nil }.map { $0.retention.key })))
        return visible.map(\.counts)
    }
    return PaneContextDisplaySnapshot(
        title: try PaneContextStorage.title(database, paneId: paneId),
        line: try PaneContextStorage.line(database, paneId: paneId),
        sourceRevisions: try sources.map { try PaneContextStorage.revision(database, paneId: $0) },
        messages: messages, readTimeVersions: readTimeVersions, retentionChangedSources: retentionChangedSources)
}

extension PaneContextStorage {
    fileprivate static func messageProjections(_ database: Database, paneId: PaneId) throws
        -> [PaneContextMessageProjection]
    {
        let requests = try PaneContextReadLayout.requestProjection.fetchAll(
            database, from: "pane_request WHERE pane_id = ? AND display_hidden = 0", arguments: [paneId.uuidString])
        let notices = try PaneContextReadLayout.noticeProjection.fetchAll(
            database, from: "pane_event WHERE pane_id = ? AND kind = 'notice' AND display_hidden = 0",
            arguments: [paneId.uuidString])
        return try requests.map { try messageProjection($0, table: .request) }
            + notices.map { try messageProjection($0, table: .notice) }
    }

    private static func messageProjection(_ row: PaneContextReadRow, table: PaneContextRetentionMessage.ParentTable)
        throws
        -> PaneContextMessageProjection
    {
        let importance = try importance(row)
        _ = try sender(row)
        let countedState: PaneMessageCountInput.CountedState
        switch table {
        case .request:
            _ = try reason(row)
            _ = try formKind(row)
            let waiting = try askWaiting(row)
            let state: String = try required(row, .state)
            switch state {
            case "open": countedState = .openAsk(waiting)
            case "answered":
                guard try required(row, .answeredBy) as String == "localUser" else {
                    throw PaneContextStorageFailure.decode("answered_by")
                }
                let answerKind: String = try required(row, .answerKind)
                guard ["text", "choices", "form", "decision"].contains(answerKind) else {
                    throw PaneContextStorageFailure.decode("answer_kind")
                }
                _ = try answerReceipt(row)
                countedState = .settled
            case "handedBack", "dismissed", "expired", "withdrawn", "stale": countedState = .settled
            default: throw PaneContextStorageFailure.decode("state")
            }
        case .notice:
            countedState = try noticeState(row) == .unread ? .unreadNotice(importance) : .settled
        }
        let position = try unsigned(row, .position)
        let displayHidden = try flag(row, .displayHidden)
        return PaneContextMessageProjection(
            counts: PaneMessageCountInput(
                id: AgentMessageId(existingUUID: try uuid(row, .messageId)),
                sourcePaneId: PaneId(existingUUID: try uuid(row, .paneId)), sentAt: try date(row, .sentAt),
                position: position, displayHidden: displayHidden,
                state: countedState),
            retention: PaneContextRetentionMessage(
                rowId: try uuid(row, .id), position: position, settledAt: try optionalDate(row, .settledAt),
                displayHidden: displayHidden, table: table))
    }

    static func askWaiting(_ row: PaneContextReadRow) throws -> AskWaiting {
        let kind: String = try required(row, .waiting)
        switch kind {
        case "nonBlocking": return .nonBlocking
        case "blocking": return .blocking(deadline: try date(row, .deadline))
        default: throw PaneContextStorageFailure.decode("waiting")
        }
    }

    static func noticeState(_ row: PaneContextReadRow) throws -> NoticeState {
        let kind: String = try required(row, .noticeState)
        switch kind {
        case "unread": return .unread
        case "read": return .read
        case "dismissed": return .dismissed
        case "withdrawn": return .withdrawn
        default: throw PaneContextStorageFailure.decode("notice_state")
        }
    }
}
