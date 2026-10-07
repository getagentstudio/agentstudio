import Foundation
import GRDB

/// Typed columns and immutable layouts: hot decoders address GRDB rows by
/// integer index, without scanning column names for every field.
enum PaneContextReadColumn: Int, CaseIterable {
    case id
    case paneId
    case messageId
    case position
    case sentAt
    case sourceOccurredAt
    case settledAt
    case displayHidden
    case importance
    case senderKind
    case senderPaneId
    case senderProvider
    case senderSessionRef
    case senderBindingGeneration
    case body
    case why
    case waiting
    case deadline
    case state
    case reason
    case formKind
    case answeredBy
    case answerKind
    case receipt
    case receiptAt
    case answerText
    case placeholder
    case allowsMultiple
    case noticeState
    case summary
    case workKind
    case stepCurrent
    case stepTotal
    case workText
    case detail
    case expiresAt
    case stale
    case writerKind
    case writerPaneId
    case writerProvider
    case writerSessionRef
    case writerBindingGeneration
    case updatedAt
    case parentId
    case ordinal
    case kind
    case path
    case line
    case host
    case owner
    case repository
    case number
    case targetPaneId
    case requestId
    case choiceId
    case label
    case name
    case title
    case description
    case propertyKind
    case minimum
    case maximum
    case minLength
    case maxLength
    case format
    case enumPresent
    case propertyOrdinal
    case value
    case fieldName
    case valueKind
    case textValue
    case integerValue
    var sqlName: String { Self.names[rawValue] }
    private static let names = [
        "id", "pane_id", "message_id", "position", "sent_at", "source_occurred_at", "settled_at", "display_hidden",
        "importance", "sender_kind", "sender_pane_id", "sender_provider", "sender_session_ref",
        "sender_binding_generation", "body", "why", "waiting", "deadline", "state", "reason", "form_kind",
        "answered_by", "answer_kind", "receipt", "receipt_at", "answer_text", "placeholder", "allows_multiple",
        "notice_state", "summary", "work_kind", "step_current", "step_total", "work_text", "detail", "expires_at",
        "stale", "writer_kind", "writer_pane_id", "writer_provider", "writer_session_ref", "writer_binding_generation",
        "updated_at", "parent_id", "ordinal", "kind", "path", "line", "host", "owner", "repository", "number",
        "target_pane_id", "request_id", "choice_id", "label", "name", "title", "description", "property_kind",
        "minimum", "maximum", "min_length", "max_length", "format", "enum_present", "property_ordinal", "value",
        "field_name", "value_kind", "text_value", "integer_value",
    ]
}

struct PaneContextReadLayout: Sendable {
    let selection: String
    private let indices: [Int]

    private init(_ columns: [PaneContextReadColumn]) {
        selection = columns.map(\.sqlName).joined(separator: ", ")
        var indices = Array(repeating: -1, count: PaneContextReadColumn.allCases.count)
        for (index, column) in columns.enumerated() { indices[column.rawValue] = index }
        self.indices = indices
    }

    func index(of column: PaneContextReadColumn) -> Int { indices[column.rawValue] }

    func fetchAll(_ database: Database, from scope: String, arguments: StatementArguments) throws
        -> [PaneContextReadRow]
    {
        let statement = try database.cachedStatement(sql: "SELECT \(selection) FROM \(scope)")
        return try Row.fetchAll(statement, arguments: arguments).map { PaneContextReadRow(row: $0, layout: self) }
    }

    func fetchOne(_ database: Database, from scope: String, arguments: StatementArguments) throws
        -> PaneContextReadRow?
    {
        let statement = try database.cachedStatement(sql: "SELECT \(selection) FROM \(scope)")
        return try Row.fetchOne(statement, arguments: arguments).map { PaneContextReadRow(row: $0, layout: self) }
    }
    static let request = Self([
        .id, .paneId, .messageId, .position, .sentAt, .sourceOccurredAt, .settledAt, .displayHidden, .importance,
        .senderKind, .senderPaneId, .senderProvider, .senderSessionRef, .senderBindingGeneration, .body, .why, .waiting,
        .deadline, .state, .reason, .formKind, .answeredBy, .answerKind, .receipt, .receiptAt, .answerText,
        .placeholder, .allowsMultiple,
    ])
    static let notice = Self([
        .id, .paneId, .messageId, .position, .sentAt, .sourceOccurredAt, .settledAt, .displayHidden, .importance,
        .senderKind, .senderPaneId, .senderProvider, .senderSessionRef, .senderBindingGeneration, .body, .why,
        .noticeState,
    ])
    static let requestProjection = Self([
        .id, .paneId, .messageId, .position, .sentAt, .settledAt, .displayHidden, .importance, .senderKind,
        .senderPaneId, .senderProvider, .senderSessionRef, .senderBindingGeneration, .waiting, .deadline, .state,
        .reason, .formKind, .answeredBy, .answerKind, .receipt, .receiptAt,
    ])
    static let noticeProjection = Self([
        .id, .paneId, .messageId, .position, .sentAt, .settledAt, .displayHidden, .importance, .senderKind,
        .senderPaneId, .senderProvider, .senderSessionRef, .senderBindingGeneration, .noticeState,
    ])
    static let line = Self([
        .id, .summary, .workKind, .stepCurrent, .stepTotal, .workText, .detail, .expiresAt, .stale, .writerKind,
        .writerPaneId, .writerProvider, .writerSessionRef, .writerBindingGeneration, .updatedAt,
    ])
    static let action = Self([
        .parentId, .ordinal, .kind, .path, .line, .host, .owner, .repository, .number, .targetPaneId,
    ])
    static let choice = Self([.requestId, .ordinal, .choiceId, .label])
    static let property = Self([
        .requestId, .ordinal, .name, .title, .description, .propertyKind, .minimum, .maximum, .minLength, .maxLength,
        .format, .enumPresent,
    ])
    static let propertyChoice = Self([.requestId, .propertyOrdinal, .ordinal, .value])
    static let requiredName = Self([.requestId, .ordinal, .name])
    static let answer = Self([.requestId, .ordinal, .fieldName, .valueKind, .textValue, .integerValue])
}

/// Confined to the owning SQLite closure, just like the copied GRDB Row.
struct PaneContextReadRow {
    private let row: Row
    private let layout: PaneContextReadLayout

    fileprivate init(row: Row, layout: PaneContextReadLayout) {
        self.row = row
        self.layout = layout
    }

    func value(_ column: PaneContextReadColumn) throws -> DatabaseValue {
        let index = layout.index(of: column)
        guard index >= 0 else { throw PaneContextStorageFailure.decode(column.sqlName) }
        return row[index]
    }
}

extension PaneContextStorage {
    static func required<Value: DatabaseValueConvertible>(_ row: PaneContextReadRow, _ field: PaneContextReadColumn)
        throws -> Value
    {
        guard let value = Value.fromDatabaseValue(try row.value(field)) else {
            throw PaneContextStorageFailure.decode(field.sqlName)
        }
        return value
    }

    static func optional<Value: DatabaseValueConvertible>(_ row: PaneContextReadRow, _ field: PaneContextReadColumn)
        throws -> Value?
    {
        let raw = try row.value(field)
        if raw.isNull { return nil }
        guard let value = Value.fromDatabaseValue(raw) else { throw PaneContextStorageFailure.decode(field.sqlName) }
        return value
    }

    static func uuid(_ row: PaneContextReadRow, _ field: PaneContextReadColumn) throws -> UUID {
        let text: String = try required(row, field)
        guard let value = UUID(uuidString: text) else { throw PaneContextStorageFailure.decode(field.sqlName) }
        return value
    }

    static func unsigned(_ row: PaneContextReadRow, _ field: PaneContextReadColumn) throws -> UInt64 {
        let value: Int64 = try required(row, field)
        guard let value = UInt64(exactly: value) else { throw PaneContextStorageFailure.decode(field.sqlName) }
        return value
    }

    static func date(_ row: PaneContextReadRow, _ field: PaneContextReadColumn) throws -> Date {
        let value: Int64 = try required(row, field)
        return Date(timeIntervalSince1970: Double(value) / 1_000_000)
    }

    static func optionalDate(_ row: PaneContextReadRow, _ field: PaneContextReadColumn) throws -> Date? {
        let value: Int64? = try optional(row, field)
        return value.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
    }

    static func flag(_ row: PaneContextReadRow, _ field: PaneContextReadColumn) throws -> Bool {
        let value: Int = try required(row, field)
        guard value == 0 || value == 1 else { throw PaneContextStorageFailure.decode(field.sqlName) }
        return value == 1
    }

    static func sender(_ row: PaneContextReadRow, writer: Bool = false) throws -> AgentMessageSender {
        let prefix = writer ? "writer" : "sender"
        let kind: String = try required(row, writer ? .writerKind : .senderKind)
        switch kind {
        case "pane":
            return .pane(PaneId(existingUUID: try uuid(row, writer ? .writerPaneId : .senderPaneId)))
        case "session":
            do {
                return .session(
                    provider: try BridgeAgentProviderName(required(row, writer ? .writerProvider : .senderProvider)),
                    sessionRef: try BridgeAgentSessionRef(
                        required(row, writer ? .writerSessionRef : .senderSessionRef)),
                    bindingGeneration: try uuid(row, writer ? .writerBindingGeneration : .senderBindingGeneration))
            } catch { throw PaneContextStorageFailure.decode("\(prefix)_session") }
        default: throw PaneContextStorageFailure.decode("\(prefix)_kind")
        }
    }
}
