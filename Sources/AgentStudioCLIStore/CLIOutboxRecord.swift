import Foundation
import GRDB

enum CLIOutboxKind: String {
    case notice, sessionLifecycle
}

/// SQL is decoded here once; callers receive immutable, typed domain entries.
struct CLIOutboxRecord: FetchableRecord {
    let entry: CLIOutboxEntry

    init(row: Row) throws {
        let rowID = try row.decode(Int64.self, forColumn: "id")
        let kindValue: String = try Self.decodeColumn(row, rowID: rowID, field: .kind)
        guard let kind = CLIOutboxKind(rawValue: kindValue) else {
            throw CLIStoreDecodeIssue(rowID: rowID, field: .kind)
        }
        let paneValue: String = try Self.decodeColumn(row, rowID: rowID, field: .paneID)
        guard let paneID = UUID(uuidString: paneValue) else {
            throw CLIStoreDecodeIssue(rowID: rowID, field: .paneID)
        }
        let messageValue: String = try Self.decodeColumn(row, rowID: rowID, field: .messageID)
        guard let messageID = UUID(uuidString: messageValue) else {
            throw CLIStoreDecodeIssue(rowID: rowID, field: .messageID)
        }
        let payloadJSON: String = try Self.decodeColumn(row, rowID: rowID, field: .payloadJSON)
        let milliseconds: Int64 = try Self.decodeColumn(row, rowID: rowID, field: .createdAt)
        let capturedAt = Date(timeIntervalSince1970: Double(milliseconds) / CLIStorePolicy.millisecondsPerSecond)
        switch kind {
        case .notice:
            entry = .notice(
                .init(id: rowID, paneID: paneID, messageID: messageID, payloadJSON: payloadJSON, createdAt: capturedAt))
        case .sessionLifecycle:
            entry = .sessionLifecycle(
                .init(id: rowID, paneID: paneID, messageID: messageID, payloadJSON: payloadJSON, reportedAt: capturedAt)
            )
        }
    }

    private static func decodeColumn<Value: DatabaseValueConvertible>(
        _ row: Row,
        rowID: Int64,
        field: CLIStoreDecodeIssue.Field
    ) throws -> Value {
        do {
            return try row.decode(Value.self, forColumn: field.rawValue)
        } catch {
            throw CLIStoreDecodeIssue(rowID: rowID, field: field)
        }
    }
}
