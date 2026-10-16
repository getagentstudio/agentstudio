import Foundation
import GRDB

/// Stack-local child rows for one full message read; no Row crosses the SQLite closure.
struct PaneContextMessageChildren {
    enum Selection {
        case visiblePane(PaneId)
        case message(UUID)

        var predicate: String {
            switch self {
            case .visiblePane: "pane_id = ? AND display_hidden = 0"
            case .message: "id = ?"
            }
        }

        var arguments: StatementArguments {
            switch self {
            case .visiblePane(let pane): [pane.uuidString]
            case .message(let id): [id.uuidString]
            }
        }
    }

    let requestActions: [UUID: [PaneContextReadRow]]
    let noticeActions: [UUID: [PaneContextReadRow]]
    let choices: [UUID: [PaneContextReadRow]]
    let properties: [UUID: [PaneContextReadRow]]
    let propertyChoices: [UUID: [PaneContextReadRow]]
    let requiredNames: [UUID: [PaneContextReadRow]]
    let answers: [UUID: [PaneContextReadRow]]

    init(_ database: Database, selection: Selection, requests: [PaneContextReadRow], notices: [PaneContextReadRow])
        throws
    {
        requestActions =
            requests.isEmpty
            ? [:]
            : try Self.fetch(
                database, selection: selection, table: "pane_request_action", parentColumn: "parent_id",
                parentTable: "pane_request")
        noticeActions =
            notices.isEmpty
            ? [:]
            : try Self.fetch(
                database, selection: selection, table: "pane_event_action", parentColumn: "parent_id",
                parentTable: "pane_event", parentFilter: " AND kind = 'notice'")
        let hasChoices = try requests.contains {
            try PaneContextStorage.formKind($0) == .choice
        }
        let hasProperties = try requests.contains {
            try PaneContextStorage.formKind($0) == .elicitation
        }
        choices =
            hasChoices
            ? try Self.fetch(
                database, selection: selection, table: "pane_request_choice", parentColumn: "request_id",
                parentTable: "pane_request", parentFilter: " AND form_kind = 'choice'") : [:]
        properties =
            hasProperties
            ? try Self.fetch(
                database, selection: selection, table: "pane_request_property", parentColumn: "request_id",
                parentTable: "pane_request", parentFilter: " AND form_kind = 'elicitation'") : [:]
        let choiceRows =
            hasProperties
            ? try Self.fetch(
                database, selection: selection, table: "pane_request_property_choice", parentColumn: "request_id",
                parentTable: "pane_request", parentFilter: " AND form_kind = 'elicitation'") : [:]
        propertyChoices = choiceRows
        requiredNames =
            hasProperties
            ? try Self.fetch(
                database, selection: selection, table: "pane_request_required", parentColumn: "request_id",
                parentTable: "pane_request", parentFilter: " AND form_kind = 'elicitation'") : [:]
        let hasAnswers = try requests.contains {
            let state: String = try PaneContextStorage.required($0, .state)
            guard state == "answered" else { return false }
            let kind: String = try PaneContextStorage.required($0, .answerKind)
            return kind != "text"
        }
        answers =
            hasAnswers
            ? try Self.fetch(
                database, selection: selection, table: "pane_request_answer_value", parentColumn: "request_id",
                parentTable: "pane_request", parentFilter: " AND state = 'answered' AND answer_kind != 'text'") : [:]
    }

    private static func fetch(
        _ database: Database, selection: Selection, table: String, parentColumn: String,
        parentTable: String, parentFilter: String = ""
    ) throws -> [UUID: [PaneContextReadRow]] {
        // The subquery binds one pane/id instead of an unbounded list of message IDs.
        // SQL and parameter count stay fixed even for a long persisted backlog.
        let layout: PaneContextReadLayout
        switch table {
        case "pane_request_action", "pane_event_action": layout = .action
        case "pane_request_choice": layout = .choice
        case "pane_request_property": layout = .property
        case "pane_request_property_choice": layout = .propertyChoice
        case "pane_request_required": layout = .requiredName
        case "pane_request_answer_value": layout = .answer
        default: throw PaneContextStorageFailure.decode("child.table")
        }
        let rows = try layout.fetchAll(
            database,
            from: """
                \(table) WHERE \(parentColumn) IN (
                    SELECT id FROM \(parentTable) WHERE \(selection.predicate)\(parentFilter)
                ) ORDER BY ordinal
                """, arguments: selection.arguments)
        var grouped: [UUID: [PaneContextReadRow]] = [:]
        for row in rows {
            let parentId = try PaneContextStorage.uuid(row, parentColumn == "parent_id" ? .parentId : .requestId)
            grouped[parentId, default: []].append(row)
        }
        return grouped
    }
}
