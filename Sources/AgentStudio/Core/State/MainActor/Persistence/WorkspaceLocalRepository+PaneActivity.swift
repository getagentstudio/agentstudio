import Foundation
import GRDB
import OSLog

private let paneActivityPersistenceLogger = Logger(subsystem: "com.agentstudio", category: "PaneActivityPersistence")

extension WorkspaceLocalRepository {
    func commitPaneActivity(_ commit: PaneActivityCommit) throws {
        try databaseWriter.write { database in
            for mutation in commit.mutations {
                switch mutation {
                case .set(let paneId, let time):
                    try database.execute(
                        sql: """
                            INSERT INTO local_pane_activity(pane_id, activity_at, source)
                            VALUES (?, ?, ?)
                            ON CONFLICT(pane_id) DO UPDATE SET
                                activity_at = excluded.activity_at,
                                source = excluded.source
                            """,
                        arguments: [paneId.uuidString, time.wallTime.timeIntervalSince1970, time.source.rawValue]
                    )
                case .remove(let paneId):
                    try database.execute(
                        sql: "DELETE FROM local_pane_activity WHERE pane_id = ?", arguments: [paneId.uuidString])
                }
            }
        }
    }

    func fetchPaneActivity() throws -> [PaneActivityRecord] {
        try databaseWriter.read { database in
            try Row.fetchAll(
                database, sql: "SELECT pane_id, activity_at, source FROM local_pane_activity ORDER BY pane_id"
            )
            .compactMap { row in
                do {
                    let storedPaneId: String = try row.decode(forColumn: "pane_id")
                    let storedSource: String = try row.decode(forColumn: "source")
                    let storedTimestamp: DatabaseValue = try row.decode(forColumn: "activity_at")
                    guard let paneId = UUID(uuidString: storedPaneId),
                        let source = PaneActivitySource(rawValue: storedSource),
                        let timestamp = Double.fromDatabaseValue(storedTimestamp), timestamp.isFinite
                    else {
                        paneActivityPersistenceLogger.warning("Skipping invalid persisted pane activity fields")
                        return nil
                    }
                    let record = PaneActivityRecord(
                        paneId: paneId,
                        wallTime: Date(timeIntervalSince1970: timestamp),
                        source: source
                    )
                    guard record.canRestore(relativeTo: Date.now) else {
                        paneActivityPersistenceLogger.warning("Skipping unrepresentable persisted pane activity time")
                        return nil
                    }
                    return record
                } catch {
                    paneActivityPersistenceLogger.warning("Skipping malformed persisted pane activity fields")
                    return nil
                }
            }
        }
    }

    func prunePaneActivity(retaining paneIds: Set<UUID>) throws {
        try databaseWriter.write { database in
            let storedIds = try String.fetchAll(database, sql: "SELECT pane_id FROM local_pane_activity")
            for storedId in storedIds where !(UUID(uuidString: storedId).map(paneIds.contains) ?? false) {
                try database.execute(sql: "DELETE FROM local_pane_activity WHERE pane_id = ?", arguments: [storedId])
            }
        }
    }
}
