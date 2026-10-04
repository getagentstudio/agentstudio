import AgentStudioInfrastructure
import Foundation
import GRDB

extension PaneContextStorage {
    static func message(_ database: Database, paneId: PaneId, messageId: AgentMessageId) throws
        -> PaneContextStoredMessage?
    {
        if let row = try Row.fetchOne(
            database, sql: "SELECT * FROM pane_request WHERE pane_id = ? AND message_id = ?",
            arguments: [paneId.uuidString, messageId.uuid.uuidString])
        {
            let children = try PaneContextMessageChildren(
                database, selection: .message(try uuid(row, "id")), requests: [row], notices: [])
            return try requestMessage(row, children: children)
        }
        if let row = try Row.fetchOne(
            database, sql: "SELECT * FROM pane_event WHERE pane_id = ? AND message_id = ? AND kind = 'notice'",
            arguments: [paneId.uuidString, messageId.uuid.uuidString])
        {
            let children = try PaneContextMessageChildren(
                database, selection: .message(try uuid(row, "id")), requests: [], notices: [row])
            return try noticeMessage(row, children: children)
        }
        return nil
    }

    static func messages(_ database: Database, paneId: PaneId) throws -> [PaneContextStoredMessage] {
        let requests = try Row.fetchAll(
            database, sql: "SELECT * FROM pane_request WHERE pane_id = ? AND display_hidden = 0",
            arguments: [paneId.uuidString]
        )
        let notices = try Row.fetchAll(
            database, sql: "SELECT * FROM pane_event WHERE pane_id = ? AND kind = 'notice' AND display_hidden = 0",
            arguments: [paneId.uuidString]
        )
        let children = try PaneContextMessageChildren(
            database, selection: .visiblePane(paneId), requests: requests, notices: notices)
        return try requests.map { try requestMessage($0, children: children) }
            + notices.map { try noticeMessage($0, children: children) }
    }

    static func requestMessage(_ row: Row, children: PaneContextMessageChildren) throws -> PaneContextStoredMessage {
        let rowId = try uuid(row, "id")
        let waiting = try askWaiting(row)
        return PaneContextStoredMessage(
            rowId: rowId, position: try unsigned(row, "position"),
            detail: AgentMessageDetail(
                id: AgentMessageId(existingUUID: try uuid(row, "message_id")),
                sourcePaneId: PaneId(existingUUID: try uuid(row, "pane_id")), sender: try sender(row, prefix: "sender"),
                sentAt: try date(row, "sent_at"), sourceOccurredAt: try optionalDate(row, "source_occurred_at"),
                importance: try importance(row), body: try required(row, "body"), why: try optional(row, "why"),
                actions: try actions(children.requestActions[rowId] ?? []),
                shape: .ask(
                    try reason(row), try form(row, children: children), waiting, try askState(row, children: children))
            ),
            settledAt: try optionalDate(row, "settled_at"), displayHidden: try flag(row, "display_hidden")
        )
    }

    static func noticeMessage(_ row: Row, children: PaneContextMessageChildren) throws -> PaneContextStoredMessage {
        let rowId = try uuid(row, "id")
        let state = try noticeState(row)
        return PaneContextStoredMessage(
            rowId: rowId, position: try unsigned(row, "position"),
            detail: AgentMessageDetail(
                id: AgentMessageId(existingUUID: try uuid(row, "message_id")),
                sourcePaneId: PaneId(existingUUID: try uuid(row, "pane_id")), sender: try sender(row, prefix: "sender"),
                sentAt: try date(row, "sent_at"), sourceOccurredAt: try optionalDate(row, "source_occurred_at"),
                importance: try importance(row), body: try required(row, "body"), why: try optional(row, "why"),
                actions: try actions(children.noticeActions[rowId] ?? []), shape: .notice(state)
            ),
            settledAt: try optionalDate(row, "settled_at"), displayHidden: try flag(row, "display_hidden")
        )
    }

    static func recordMessage(_ request: PaneMessageSendRequest, database: Database, now: Date) throws {
        let rowId = UUIDv7.generate()
        let position = try nextPosition(database, paneId: request.paneId)
        let source = request.sourceOccurredAt.flatMap {
            $0.timeIntervalSince(now) <= AppPolicies.PaneContext.maximumSourceFutureSkew ? $0 : nil
        }
        var fields = senderFields(request.sender, prefix: "sender")
        fields.merge(
            [
                "id": sqlValue(rowId.uuidString), "pane_id": sqlValue(request.paneId.uuidString),
                "message_id": sqlValue(request.messageId.uuid.uuidString),
                "position": sqlValue(try integer(position, field: "position")),
                "importance": sqlValue(importanceName(request.importance)), "body": sqlValue(request.body),
                "why": sqlValue(request.why),
                "sent_at": sqlValue(try timestamp(now)), "source_occurred_at": sqlValue(try source.map(timestamp)),
                "intent_source_occurred_at": sqlValue(try request.sourceOccurredAt.map(timestamp)),
            ], uniquingKeysWith: { _, new in new })
        switch request.shape {
        case .notice:
            fields["kind"] = sqlValue("notice")
            fields["subject_id"] = sqlValue(request.messageId.uuid.uuidString)
            fields["notice_state"] = sqlValue("unread")
            try insert(database, table: "pane_event", fields: fields)
            try saveActions(request.actions, database: database, table: "pane_event_action", parentId: rowId)
        case .ask(let reason, let form, let waiting):
            fields["reason"] = sqlValue(reasonName(reason))
            fields["state"] = sqlValue("open")
            fields.merge(formFields(form), uniquingKeysWith: { _, new in new })
            switch waiting {
            case .nonBlocking: fields["waiting"] = sqlValue("nonBlocking")
            case .blocking(let deadline):
                fields["waiting"] = sqlValue("blocking")
                fields["deadline"] = sqlValue(try timestamp(deadline))
            }
            try insert(database, table: "pane_request", fields: fields)
            try saveForm(form, database: database, requestId: rowId)
            try saveActions(request.actions, database: database, table: "pane_request_action", parentId: rowId)
        }
        try bumpRevision(database, paneId: request.paneId)
    }

    static func sameIntent(_ request: PaneMessageSendRequest, stored: PaneContextStoredMessage, database: Database)
        throws -> Bool
    {
        let detail = stored.detail
        guard writerKey(detail.sender) == writerKey(request.sender), detail.importance == request.importance,
            detail.body == request.body, detail.why == request.why, detail.actions == request.actions
        else { return false }
        let table: String
        switch detail.shape {
        case .notice: table = "pane_event"
        case .ask: table = "pane_request"
        }
        guard
            let row = try Row.fetchOne(
                database, sql: "SELECT intent_source_occurred_at FROM \(table) WHERE id = ?",
                arguments: [stored.rowId.uuidString])
        else { return false }
        let storedSource: Int64? = try optional(row, "intent_source_occurred_at")
        guard storedSource == (try request.sourceOccurredAt.map(timestamp)) else { return false }
        switch (request.shape, detail.shape) {
        case (.notice, .notice): return true
        case (
            .ask(let reason, let form, let waiting), .ask(let existingReason, let existingForm, let existingWaiting, _)
        ):
            return reason == existingReason && form == existingForm && waiting == existingWaiting
        default: return false
        }
    }

    static func appendChange(_ database: Database, message: PaneContextStoredMessage, kind: String, now: Date) throws
        -> UInt64
    {
        let position = try nextPosition(database, paneId: message.detail.sourcePaneId)
        var fields = senderFields(message.detail.sender, prefix: "sender")
        fields.merge(
            [
                "id": sqlValue(UUIDv7.generate().uuidString), "kind": sqlValue(kind),
                "pane_id": sqlValue(message.detail.sourcePaneId.uuidString),
                "position": sqlValue(try integer(position, field: "position")),
                "subject_id": sqlValue(message.detail.id.uuid.uuidString), "sent_at": sqlValue(try timestamp(now)),
            ], uniquingKeysWith: { _, new in new })
        try insert(database, table: "pane_event", fields: fields)
        return position
    }
}
