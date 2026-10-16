import AgentStudioInfrastructure
import Foundation
import GRDB

enum PaneContextStorageFailure: Error, Sendable {
    case decode(String)
}

struct PaneContextStoredMessage: Sendable {
    let rowId: UUID
    let position: UInt64
    let detail: AgentMessageDetail
    let settledAt: Date?
    let displayHidden: Bool
}

enum PaneContextStorage {
    static func sqlValue(_ value: (any DatabaseValueConvertible)?) -> DatabaseValue {
        value?.databaseValue ?? .null
    }

    static func required<Value: DatabaseValueConvertible>(_ row: Row, _ field: String) throws -> Value {
        guard row.hasColumn(field) else { throw PaneContextStorageFailure.decode(field) }
        let raw: DatabaseValue = row[field]
        guard let value = Value.fromDatabaseValue(raw) else { throw PaneContextStorageFailure.decode(field) }
        return value
    }

    static func optional<Value: DatabaseValueConvertible>(_ row: Row, _ field: String) throws -> Value? {
        guard row.hasColumn(field) else { throw PaneContextStorageFailure.decode(field) }
        let raw: DatabaseValue = row[field]
        if raw.isNull { return nil }
        guard let value = Value.fromDatabaseValue(raw) else { throw PaneContextStorageFailure.decode(field) }
        return value
    }

    static func uuid(_ row: Row, _ field: String) throws -> UUID {
        let text: String = try required(row, field)
        guard let value = UUID(uuidString: text) else { throw PaneContextStorageFailure.decode(field) }
        return value
    }

    static func unsigned(_ row: Row, _ field: String) throws -> UInt64 {
        let value: Int64 = try required(row, field)
        guard let value = UInt64(exactly: value) else { throw PaneContextStorageFailure.decode(field) }
        return value
    }

    static func integer(_ value: UInt64, field: String) throws -> Int64 {
        guard let value = Int64(exactly: value) else { throw PaneContextStorageFailure.decode(field) }
        return value
    }

    static func timestamp(_ date: Date) throws -> Int64 {
        guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000_000).rounded()) else {
            throw PaneContextStorageFailure.decode("timestamp")
        }
        return value
    }

    static func date(_ row: Row, _ field: String) throws -> Date {
        let value: Int64 = try required(row, field)
        return Date(timeIntervalSince1970: Double(value) / 1_000_000)
    }

    static func optionalDate(_ row: Row, _ field: String) throws -> Date? {
        let value: Int64? = try optional(row, field)
        return value.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
    }

    static func flag(_ row: Row, _ field: String) throws -> Bool {
        let value: Int = try required(row, field)
        guard value == 0 || value == 1 else { throw PaneContextStorageFailure.decode(field) }
        return value == 1
    }

    static func insert(_ database: Database, table: String, fields: [String: DatabaseValue]) throws {
        let names = fields.keys.sorted()
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        try database.execute(
            sql: "INSERT INTO \(table) (\(names.joined(separator: ","))) VALUES (\(placeholders))",
            arguments: StatementArguments(names.map { fields[$0] ?? .null })
        )
    }

    static func senderFields(_ sender: AgentMessageSender, prefix: String) -> [String: DatabaseValue] {
        var fields = [
            "\(prefix)_pane_id": DatabaseValue.null,
            "\(prefix)_provider": .null,
            "\(prefix)_session_ref": .null,
            "\(prefix)_binding_generation": .null,
        ]
        switch sender {
        case .pane(let paneId):
            fields["\(prefix)_kind"] = sqlValue("pane")
            fields["\(prefix)_pane_id"] = sqlValue(paneId.uuidString)
        case .session(let provider, let reference, let generation):
            fields["\(prefix)_kind"] = sqlValue("session")
            fields["\(prefix)_provider"] = sqlValue(provider.value)
            fields["\(prefix)_session_ref"] = sqlValue(reference.value)
            fields["\(prefix)_binding_generation"] = sqlValue(generation.uuidString)
        }
        return fields
    }

    static func sender(_ row: Row, prefix: String) throws -> AgentMessageSender {
        let kind: String = try required(row, "\(prefix)_kind")
        switch kind {
        case "pane": return .pane(PaneId(existingUUID: try uuid(row, "\(prefix)_pane_id")))
        case "session":
            do {
                return .session(
                    provider: try BridgeAgentProviderName(required(row, "\(prefix)_provider")),
                    sessionRef: try BridgeAgentSessionRef(required(row, "\(prefix)_session_ref")),
                    bindingGeneration: try uuid(row, "\(prefix)_binding_generation")
                )
            } catch { throw PaneContextStorageFailure.decode("\(prefix)_session") }
        default: throw PaneContextStorageFailure.decode("\(prefix)_kind")
        }
    }

    static func writerKey(_ sender: AgentMessageSender) -> String {
        switch sender {
        case .pane(let pane): "pane:\(pane.uuidString)"
        case .session(let provider, let reference, _):
            BridgeLinkContributorKeyCodec.encode(
                .agent(BridgeAgentContributorIdentity(provider: provider, sessionRef: reference)))
        }
    }

    static func nextPosition(_ database: Database, paneId: PaneId) throws -> UInt64 {
        let current =
            try Int64.fetchOne(
                database,
                sql: """
                    SELECT COALESCE(MAX(position), 0) FROM (
                        SELECT position FROM pane_request WHERE pane_id = ?
                        UNION ALL SELECT position FROM pane_event WHERE pane_id = ?
                    )
                    """, arguments: [paneId.uuidString, paneId.uuidString]) ?? 0
        guard current >= 0, current < Int64.max else { throw PaneContextStorageFailure.decode("position") }
        return UInt64(current + 1)
    }

    static func bumpRevision(_ database: Database, paneId: PaneId) throws {
        try database.execute(
            sql: """
                INSERT OR IGNORE INTO pane_state(id, kind, pane_id)
                VALUES (?, 'agentTitle', ?)
                """, arguments: [UUIDv7.generate().uuidString, paneId.uuidString])
        try database.execute(
            sql: """
                UPDATE pane_state SET detail_revision = detail_revision + 1
                WHERE pane_id = ? AND kind = 'agentTitle'
                """, arguments: [paneId.uuidString])
    }

    static func revision(_ database: Database, paneId: PaneId) throws -> PaneContextRevision {
        let value =
            try Int64.fetchOne(
                database.cachedStatement(
                    sql: "SELECT detail_revision FROM pane_state WHERE pane_id = ? AND kind = 'agentTitle'"),
                arguments: [paneId.uuidString]) ?? 0
        guard let value = UInt64(exactly: value) else { throw PaneContextStorageFailure.decode("detail_revision") }
        return PaneContextRevision(value)
    }

    static func isRetired(_ database: Database, paneId: PaneId) throws -> Bool {
        try Bool.fetchOne(
            database.cachedStatement(sql: "SELECT EXISTS(SELECT 1 FROM pane_retirement WHERE pane_id = ?)"),
            arguments: [paneId.uuidString]) == true
    }
}
