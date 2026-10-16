import AgentStudioInfrastructure
import Foundation
import GRDB

extension PaneContextStorage {
    static func title(_ database: Database, paneId: PaneId) throws -> String? {
        let statement = try database.cachedStatement(
            sql: "SELECT title FROM pane_state WHERE pane_id = ? AND kind = 'agentTitle'")
        return try String.fetchOne(
            statement,
            arguments: [paneId.uuidString])
    }

    static func line(_ database: Database, paneId: PaneId, now: Date) throws -> AgentLineDetail? {
        guard
            let row = try PaneContextReadLayout.line.fetchOne(
                database,
                from: "pane_state WHERE pane_id = ? AND kind = 'agentLine' AND summary IS NOT NULL",
                arguments: [paneId.uuidString])
        else { return nil }
        let kind: String = try required(row, .workKind)
        let work: AgentLineWork
        switch kind {
        case "working":
            let current: Int? = try optional(row, .stepCurrent)
            if let current {
                work = .working(.step(current: current, total: try required(row, .stepTotal)))
            } else {
                work = .working(.indeterminate)
            }
        case "monitoring": work = .monitoring(try required(row, .workText))
        case "blockedOnYou": work = .blockedOnYou(action: try required(row, .workText))
        case "done": work = .done
        case "failed": work = .failed(summary: try required(row, .workText))
        default: throw PaneContextStorageFailure.decode("work_kind")
        }
        let expiry = try optionalDate(row, .expiresAt)
        return AgentLineDetail(
            summary: try required(row, .summary), work: work, detail: try optional(row, .detail),
            refs: try loadActions(database, table: "pane_state_action", parentId: uuid(row, .id)),
            writer: try sender(row, writer: true), updatedAt: try date(row, .updatedAt),
            lifetime: expiry.map { .expires(at: $0) } ?? .untilReplaced,
            stale: try flag(row, .stale) || lineIsExpired(expiresAt: expiry, now: now)
        )
    }

    static func writeTitle(_ request: PaneTitleWriteRequest, database: Database, now: Date) throws {
        var fields = senderFields(request.writer, prefix: "writer")
        fields["title"] = sqlValue(request.text)
        fields["write_epoch"] = sqlValue(try integer(request.writeNumber.epoch, field: "write_epoch"))
        fields["write_counter"] = sqlValue(String(request.writeNumber.counter))
        fields["updated_at"] = sqlValue(try timestamp(now))
        _ = try upsertValue(database, paneId: request.paneId, kind: "agentTitle", fields: fields)
        try bumpRevision(database, paneId: request.paneId)
    }

    static func writeLine(_ request: PaneLineWriteRequest, database: Database, now: Date) throws {
        var fields = senderFields(request.writer, prefix: "writer")
        fields.merge(
            [
                "summary": sqlValue(request.line?.summary), "detail": sqlValue(request.line?.detail),
                "work_kind": .null, "work_text": .null, "step_current": .null, "step_total": .null,
                "expires_at": .null, "stale": sqlValue(0),
                "write_epoch": sqlValue(try integer(request.writeNumber.epoch, field: "write_epoch")),
                "write_counter": sqlValue(String(request.writeNumber.counter)),
                "updated_at": sqlValue(try timestamp(now)),
            ], uniquingKeysWith: { _, new in new })
        if let line = request.line {
            switch line.work {
            case .working(let progress):
                fields["work_kind"] = sqlValue("working")
                if case .step(let current, let total) = progress {
                    fields["step_current"] = sqlValue(current)
                    fields["step_total"] = sqlValue(total)
                }
            case .monitoring(let text):
                fields["work_kind"] = sqlValue("monitoring")
                fields["work_text"] = sqlValue(text)
            case .blockedOnYou(let text):
                fields["work_kind"] = sqlValue("blockedOnYou")
                fields["work_text"] = sqlValue(text)
            case .done: fields["work_kind"] = sqlValue("done")
            case .failed(let text):
                fields["work_kind"] = sqlValue("failed")
                fields["work_text"] = sqlValue(text)
            }
            if case .expires(let expiry) = line.lifetime {
                fields["expires_at"] = sqlValue(try timestamp(expiry))
                fields["stale"] = sqlValue(lineIsExpired(expiresAt: expiry, now: now) ? 1 : 0)
            }
        }
        let rowId = try upsertValue(database, paneId: request.paneId, kind: "agentLine", fields: fields)
        try database.execute(sql: "DELETE FROM pane_state_action WHERE parent_id = ?", arguments: [rowId.uuidString])
        try saveActions(request.line?.refs ?? [], database: database, table: "pane_state_action", parentId: rowId)
        try bumpRevision(database, paneId: request.paneId)
    }

    private static func upsertValue(_ database: Database, paneId: PaneId, kind: String, fields: [String: DatabaseValue])
        throws -> UUID
    {
        let existing = try String.fetchOne(
            database, sql: "SELECT id FROM pane_state WHERE pane_id = ? AND kind = ?",
            arguments: [paneId.uuidString, kind])
        let rowId: UUID
        if let existing {
            guard let parsed = UUID(uuidString: existing) else { throw PaneContextStorageFailure.decode("state.id") }
            rowId = parsed
        } else {
            rowId = UUIDv7.generate()
        }
        var fields = fields
        fields["id"] = sqlValue(rowId.uuidString)
        fields["pane_id"] = sqlValue(paneId.uuidString)
        fields["kind"] = sqlValue(kind)
        let names = fields.keys.sorted()
        let updates = names.filter { !["id", "pane_id", "kind"].contains($0) }.map { "\($0) = excluded.\($0)" }.joined(
            separator: ",")
        try database.execute(
            sql:
                "INSERT INTO pane_state(\(names.joined(separator: ","))) VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ","))) ON CONFLICT(pane_id, kind) DO UPDATE SET \(updates)",
            arguments: StatementArguments(names.map { fields[$0] ?? .null })
        )
        return rowId
    }

    static func streamName(_ stream: PaneWriteStream) -> String {
        switch stream {
        case .line: "line"
        case .title: "title"
        }
    }

    static func claimEpoch(_ request: PaneEpochClaimRequest, database: Database, now: Date) throws
        -> PaneEpochClaimResult
    {
        if let existing = try Row.fetchOne(
            database, sql: "SELECT * FROM pane_epoch_claim WHERE claim_id = ?", arguments: [request.claimId.uuidString])
        {
            guard try required(existing, "pane_id") as String == request.paneId.uuidString,
                try required(existing, "writer_key") as String == writerKey(request.writer),
                try required(existing, "stream") as String == streamName(request.stream)
            else { return .refused(.conflict) }
            return .claimed(try unsigned(existing, "epoch"))
        }
        let arguments: StatementArguments = [
            request.paneId.uuidString, writerKey(request.writer), streamName(request.stream),
        ]
        let epoch =
            try Int64.fetchOne(
                database,
                sql: "SELECT current_epoch FROM pane_write_order WHERE pane_id = ? AND writer_key = ? AND stream = ?",
                arguments: arguments) ?? 0
        guard epoch >= 0 && epoch < Int64.max else { throw PaneContextStorageFailure.decode("epoch") }
        let next = epoch + 1
        try database.execute(
            sql: """
                INSERT INTO pane_write_order(pane_id, writer_key, stream, current_epoch, last_counter)
                VALUES (?, ?, ?, ?, 0) ON CONFLICT(pane_id, writer_key, stream)
                DO UPDATE SET current_epoch = excluded.current_epoch, last_counter = 0
                """,
            arguments: [request.paneId.uuidString, writerKey(request.writer), streamName(request.stream), next])
        try insert(
            database, table: "pane_epoch_claim",
            fields: [
                "claim_id": sqlValue(request.claimId.uuidString), "pane_id": sqlValue(request.paneId.uuidString),
                "writer_key": sqlValue(writerKey(request.writer)), "stream": sqlValue(streamName(request.stream)),
                "epoch": sqlValue(next), "claimed_at": sqlValue(try timestamp(now)),
            ])
        return .claimed(UInt64(next))
    }

    static func admitWrite(
        _ number: WriteNumber, paneId: PaneId, writer: AgentMessageSender, stream: PaneWriteStream, database: Database
    ) throws -> PaneWriteStaleness? {
        guard
            let row = try Row.fetchOne(
                database, sql: "SELECT * FROM pane_write_order WHERE pane_id = ? AND writer_key = ? AND stream = ?",
                arguments: [paneId.uuidString, writerKey(writer), streamName(stream)])
        else { return .epochSuperseded }
        let counterText: String = try required(row, "last_counter")
        guard let counter = UInt64(counterText), String(counter) == counterText else {
            throw PaneContextStorageFailure.decode("last_counter")
        }
        let current = WriteNumber(epoch: try unsigned(row, "current_epoch"), counter: counter)
        guard number.epoch == current.epoch else { return .epochSuperseded }
        guard number.counter > current.counter else { return .lastAccepted(current) }
        try database.execute(
            sql: "UPDATE pane_write_order SET last_counter = ? WHERE pane_id = ? AND writer_key = ? AND stream = ?",
            arguments: [String(number.counter), paneId.uuidString, writerKey(writer), streamName(stream)])
        return nil
    }
}

extension PaneContextStorage {
    static func lineIsExpired(expiresAt: Date?, now: Date) -> Bool {
        expiresAt.map { $0 <= now } == true
    }

    static func lineStaleness(_ database: Database, paneId: PaneId, now: Date) throws -> Bool? {
        let statement = try database.cachedStatement(
            sql: """
                SELECT stale, expires_at FROM pane_state
                WHERE pane_id = ? AND kind = 'agentLine' AND summary IS NOT NULL
                """)
        guard let row = try Row.fetchOne(statement, arguments: [paneId.uuidString]) else { return nil }
        let raw: Int? = Int.fromDatabaseValue(row[0])
        guard let raw, raw == 0 || raw == 1 else { throw PaneContextStorageFailure.decode("stale") }
        let expiryValue: DatabaseValue = row[1]
        let expiry: Date?
        if expiryValue.isNull {
            expiry = nil
        } else {
            guard let micros = Int64.fromDatabaseValue(expiryValue) else {
                throw PaneContextStorageFailure.decode("expires_at")
            }
            expiry = Date(timeIntervalSince1970: Double(micros) / 1_000_000)
        }
        return raw == 1 || lineIsExpired(expiresAt: expiry, now: now)
    }
}
