import Foundation
import GRDB

extension PaneContextStorage {
    static func presentationRevisions(_ database: Database) throws -> [PaneId: PaneContextRevision] {
        let rows = try Row.fetchAll(
            database, sql: "SELECT pane_id, detail_revision FROM pane_state WHERE kind = 'agentTitle'")
        return try Dictionary(
            uniqueKeysWithValues: rows.map { row in
                (
                    PaneId(existingUUID: try uuid(row, "pane_id")),
                    PaneContextRevision(try unsigned(row, "detail_revision"))
                )
            })
    }

    static func changedPresentationSources(
        _ database: Database, since previous: [PaneId: PaneContextRevision]
    ) throws -> Set<PaneId> {
        let current = try presentationRevisions(database)
        return Set(previous.keys).union(current.keys).filter { previous[$0] != current[$0] }
    }
}
