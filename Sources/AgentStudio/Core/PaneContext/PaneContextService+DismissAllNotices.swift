import Foundation
import GRDB

private struct PaneContextDismissAllCommit: Sendable {
    let count: Int
    let affectedSources: Set<PaneId>
}

extension PaneContextService {
    package func dismissAllNotices(paneId: PaneId, includingDrawers: Bool) async -> DismissAllNoticesResult {
        do {
            try await ensureOpen()
            let membership = self.membership
            let admission = scopeAdmission()
            let now = wallNow
            let commit = try await sqliteAccess.write { database -> PaneContextDismissAllCommit in
                guard try admission(paneId, database), let currentSources = membership.sources(for: paneId) else {
                    return .init(count: 0, affectedSources: [])
                }
                let targets = includingDrawers ? currentSources : [paneId]
                let instant = now()
                var affectedSources = Set<PaneId>()
                var count = 0
                for source in Set(targets) {
                    guard try admission(source, database) else { continue }
                    let messageIds = try String.fetchAll(
                        database,
                        sql: """
                            SELECT message_id FROM pane_event
                            WHERE pane_id = ? AND kind = 'notice' AND notice_state IN ('unread', 'read')
                            ORDER BY position
                            """, arguments: [source.uuidString])
                    for value in messageIds {
                        guard let uuid = UUID(uuidString: value),
                            let message = try PaneContextStorage.message(
                                database, paneId: source, messageId: .init(existingUUID: uuid))
                        else { throw PaneContextStorageFailure.decode("message_id") }
                        try PaneContextStorage.transitionNoticeState(
                            database, message: message, state: "dismissed", change: "dismissal", now: instant)
                        count += 1
                    }
                    if !messageIds.isEmpty {
                        let retentionRows = try PaneContextStorage.messages(database, paneId: source)
                            .map(PaneContextRetentionMessage.init)
                        try PaneContextStorage.hideSettledRows(database, rows: retentionRows, now: instant)
                        try PaneContextStorage.bumpRevision(database, paneId: source)
                        affectedSources.insert(source)
                    }
                }
                return .init(count: count, affectedSources: affectedSources)
            }
            if !commit.affectedSources.isEmpty { await publishAffectedSources(commit.affectedSources) }
            return .dismissed(count: commit.count)
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }
}
