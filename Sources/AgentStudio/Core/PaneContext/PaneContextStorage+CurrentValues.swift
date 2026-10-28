import AgentStudioInfrastructure
import Foundation
import GRDB

enum PaneContextEpochClaimCommit: Sendable {
    case created(UInt64)
    case existing(UInt64)
    case refused(PaneContextWriteRefusal)
}

extension PaneContextStorage {
    static func title(_ database: Database, paneId: PaneId) throws -> String? {
        let statement = try database.cachedStatement(
            sql: "SELECT title FROM pane_state WHERE pane_id = ? AND kind = 'agentTitle'")
        return try String.fetchOne(
            statement,
            arguments: [paneId.uuidString])
    }

    static func line(_ database: Database, paneId: PaneId) throws -> AgentLineDetail? {
        guard
            let row = try PaneContextReadLayout.line.fetchOne(
                database, from: "pane_state WHERE pane_id = ? AND kind = 'agentLine' AND summary IS NOT NULL",
                arguments: [paneId.uuidString])
        else { return nil }
        return AgentLineDetail(
            summary: try required(row, .summary),
            refs: try loadActions(database, table: "pane_state_action", parentId: uuid(row, .id)),
            writer: try sender(row, writer: true), updatedAt: try date(row, .updatedAt))
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
        fields["summary"] = sqlValue(request.line?.summary)
        fields["write_epoch"] = sqlValue(try integer(request.writeNumber.epoch, field: "write_epoch"))
        fields["write_counter"] = sqlValue(String(request.writeNumber.counter))
        fields["updated_at"] = sqlValue(try timestamp(now))
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
        -> PaneContextEpochClaimCommit
    {
        if let existing = try Row.fetchOne(
            database, sql: "SELECT * FROM pane_epoch_claim WHERE claim_id = ?", arguments: [request.claimId.uuidString])
        {
            guard try required(existing, "pane_id") as String == request.paneId.uuidString,
                try required(existing, "writer_key") as String == writerKey(request.writer),
                try required(existing, "stream") as String == streamName(request.stream)
            else { return .refused(.conflict) }
            return .existing(try unsigned(existing, "epoch"))
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
        return .created(UInt64(next))
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
