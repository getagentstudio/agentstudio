import AgentStudioInfrastructure
import Foundation
import GRDB

private struct PaneContextChangesCommit: Sendable {
    let result: PaneMessageChangesResult
    let didConfirmReceipt: Bool
}

extension PaneContextService {
    package func changes(_ request: PaneMessageChangesRequest) async -> PaneMessageChangesResult {
        do {
            try await ensureOpen()
            let admission = scopeAdmission()
            let now = wallNow
            let commit = try await sqliteAccess.write { database -> PaneContextChangesCommit in
                guard try admission(request.paneId, database) else {
                    return PaneContextChangesCommit(result: .refused(.paneGone), didConfirmReceipt: false)
                }
                let key = PaneContextStorage.writerKey(request.writer)
                let after = try PaneContextStorage.integer(request.after.value, field: "after")
                try database.execute(
                    sql: """
                        INSERT INTO pane_answer_position(pane_id, session_ref, last_reported_position) VALUES (?, ?, ?)
                        ON CONFLICT(pane_id, session_ref) DO UPDATE SET last_reported_position = MAX(last_reported_position, excluded.last_reported_position)
                        """, arguments: [request.paneId.uuidString, key, after])
                let instant = now()
                let position =
                    try Int64.fetchOne(
                        database,
                        sql:
                            "SELECT last_reported_position FROM pane_answer_position WHERE pane_id = ? AND session_ref = ?",
                        arguments: [request.paneId.uuidString, key]) ?? after
                let changed = try Self.confirmReceipts(
                    database, paneId: request.paneId, writerKey: key, position: position, instant: instant)
                let rows = try Row.fetchAll(
                    database, sql: "SELECT * FROM pane_event WHERE pane_id = ? AND kind != 'notice' ORDER BY position",
                    arguments: [request.paneId.uuidString])
                var entries: [PaneMessageChangeEntry] = []
                var bytes = 0
                var more = false
                for row in rows {
                    guard try PaneContextStorage.writerKey(PaneContextStorage.sender(row, prefix: "sender")) == key
                    else { continue }
                    let eventPosition = try PaneContextStorage.unsigned(row, "position")
                    if eventPosition <= UInt64(position),
                        try PaneContextStorage.date(row, "sent_at").addingTimeInterval(
                            AppPolicies.PaneContext.changeRetentionLifetime) < instant
                    {
                        try database.execute(
                            sql: "DELETE FROM pane_event WHERE id = ?",
                            arguments: [try PaneContextStorage.uuid(row, "id").uuidString])
                        continue
                    }
                    guard eventPosition > request.after.value else { continue }
                    let id = AgentMessageId(existingUUID: try PaneContextStorage.uuid(row, "subject_id"))
                    let kindName: String = try PaneContextStorage.required(row, "kind")
                    let kind: PaneMessageChangeKind
                    let cost: Int
                    switch kindName {
                    case "answer":
                        guard
                            let message = try PaneContextStorage.message(
                                database, paneId: request.paneId, messageId: id),
                            case .ask(_, _, _, .answered(_, let answer, _)) = message.detail.shape
                        else { throw PaneContextStorageFailure.decode("answer") }
                        kind = .answer(answer)
                        cost = PaneContextAdmission.answerBytes(answer) + AppPolicies.PaneContext.maximumActionBytes
                    case "dismissal":
                        kind = .dismissal
                        cost = AppPolicies.PaneContext.maximumActionBytes
                    case "withdrawal":
                        kind = .withdrawal
                        cost = AppPolicies.PaneContext.maximumActionBytes
                    default: throw PaneContextStorageFailure.decode("kind")
                    }
                    if entries.count == AppPolicies.PaneContext.maximumChangeEntries
                        || bytes + cost > AppPolicies.PaneContext.maximumChangeBytes
                    {
                        more = true
                        break
                    }
                    entries.append(
                        PaneMessageChangeEntry(
                            id: try PaneContextStorage.uuid(row, "id"), position: AnswerPosition(eventPosition),
                            messageId: id, kind: kind))
                    bytes += cost
                }
                return PaneContextChangesCommit(
                    result: .page(
                        PaneMessageChangesPage(
                            entries: entries, nextPosition: entries.last?.position ?? request.after, more: more)),
                    didConfirmReceipt: changed)
            }
            if commit.didConfirmReceipt { await publishAffectedSources([request.paneId]) }
            return commit.result
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }

    private nonisolated static func confirmReceipts(
        _ database: Database, paneId: PaneId, writerKey: String, position: Int64, instant: Date
    ) throws -> Bool {
        let receipts = try Row.fetchAll(
            database,
            sql:
                "SELECT * FROM pane_request WHERE pane_id = ? AND receipt = 'notYetConfirmed' AND answer_position <= ?",
            arguments: [paneId.uuidString, position])
        var changed = false
        for row in receipts
        where try PaneContextStorage.writerKey(PaneContextStorage.sender(row, prefix: "sender")) == writerKey {
            try database.execute(
                sql: "UPDATE pane_request SET receipt = 'confirmed', receipt_at = ? WHERE id = ?",
                arguments: [
                    try PaneContextStorage.timestamp(instant),
                    try PaneContextStorage.uuid(row, "id").uuidString,
                ])
            changed = true
        }
        if changed { try PaneContextStorage.bumpRevision(database, paneId: paneId) }
        return changed
    }
}
