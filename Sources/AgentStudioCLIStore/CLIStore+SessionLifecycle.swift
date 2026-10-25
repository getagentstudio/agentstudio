import Foundation
import GRDB

package struct CLISessionLifecycleEntry: Equatable, Sendable {
    package let id: Int64
    package let paneID: UUID
    package let messageID: UUID
    package let payloadJSON: String
    package let reportedAt: Date
}

extension CLIStore {
    /// Lifecycle order is the hook's captured time, never the delayed append time.
    package func appendSessionLifecycle(
        paneID: UUID, messageID: UUID, payloadJSON: String, reportedAt: Date
    ) -> Result<CLIOutboxEntry, CLIStoreFailure> {
        guard
            let milliseconds = Int64(
                exactly: (reportedAt.timeIntervalSince1970 * CLIStorePolicy.millisecondsPerSecond).rounded(.down))
        else { return .failure(.unavailable) }
        do {
            return .success(
                try budgetedWriteTransaction(stage: .append) { database in
                    if let existing = try CLIOutboxRecord.fetchOne(
                        database, sql: "SELECT * FROM cli_outbox WHERE message_id = ?",
                        arguments: [messageID.uuidString])
                    {
                        return existing.entry
                    }
                    try database.execute(
                        sql: """
                            INSERT INTO cli_outbox(kind, pane_id, message_id, payload_json, created_at)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            CLIOutboxKind.sessionLifecycle.rawValue, paneID.uuidString, messageID.uuidString,
                            payloadJSON, milliseconds,
                        ])
                    return .sessionLifecycle(
                        .init(
                            id: database.lastInsertedRowID, paneID: paneID, messageID: messageID,
                            payloadJSON: payloadJSON,
                            reportedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000)))
                })
        } catch { return .failure(Self.classifyFailure(error, stage: .append)) }
    }
}
