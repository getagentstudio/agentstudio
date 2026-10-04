import Foundation
import GRDB

extension PaneContextStorage {
    static func saveActions(_ actions: [MessageAction], database: Database, table: String, parentId: UUID) throws {
        for (ordinal, action) in actions.enumerated() {
            var fields: [String: DatabaseValue] = [
                "parent_id": sqlValue(parentId.uuidString), "ordinal": sqlValue(ordinal),
                "path": .null, "line": .null, "host": .null, "owner": .null,
                "repository": .null, "number": .null, "target_pane_id": .null,
            ]
            switch action {
            case .openFile(let path, let line):
                fields["kind"] = sqlValue("openFile")
                fields["path"] = sqlValue(path)
                fields["line"] = sqlValue(line)
            case .openPullRequest(let identity):
                fields["kind"] = sqlValue("openPullRequest")
                fields["host"] = sqlValue(identity.host)
                fields["owner"] = sqlValue(identity.owner)
                fields["repository"] = sqlValue(identity.repository)
                fields["number"] = sqlValue(identity.number)
            case .goToPane(let paneId):
                fields["kind"] = sqlValue("goToPane")
                fields["target_pane_id"] = sqlValue(paneId.uuidString)
            }
            try insert(database, table: table, fields: fields)
        }
    }

    static func loadActions(_ database: Database, table: String, parentId: UUID) throws -> [MessageAction] {
        let statement = try database.cachedStatement(sql: "SELECT * FROM \(table) WHERE parent_id = ? ORDER BY ordinal")
        return try actions(Row.fetchAll(statement, arguments: [parentId.uuidString]))
    }

    static func actions(_ rows: [Row]) throws -> [MessageAction] {
        try rows.map { row in
            let kind: String = try required(row, "kind")
            switch kind {
            case "openFile": return .openFile(path: try required(row, "path"), line: try optional(row, "line"))
            case "openPullRequest":
                do {
                    return .openPullRequest(
                        try ForgePullRequestIdentity(
                            host: required(row, "host"), owner: required(row, "owner"),
                            repository: required(row, "repository"), number: required(row, "number")))
                } catch { throw PaneContextStorageFailure.decode("action.pullRequest") }
            case "goToPane": return .goToPane(PaneId(existingUUID: try uuid(row, "target_pane_id")))
            default: throw PaneContextStorageFailure.decode("action.kind")
            }
        }
    }

    static func importanceName(_ importance: MessageImportance) -> String {
        switch importance {
        case .info: "info"
        case .attention: "attention"
        case .done: "done"
        case .failure: "failure"
        }
    }

    static func importance(_ row: Row) throws -> MessageImportance {
        let name: String = try required(row, "importance")
        switch name {
        case "info": return .info
        case "attention": return .attention
        case "done": return .done
        case "failure": return .failure
        default: throw PaneContextStorageFailure.decode("importance")
        }
    }

    static func reasonName(_ reason: AskReason) -> String {
        switch reason {
        case .approval: "approval"
        case .question: "question"
        case .blocked: "blocked"
        }
    }

    static func reason(_ row: Row) throws -> AskReason {
        let name: String = try required(row, "reason")
        switch name {
        case "approval": return .approval
        case "question": return .question
        case "blocked": return .blocked
        default: throw PaneContextStorageFailure.decode("reason")
        }
    }
}
