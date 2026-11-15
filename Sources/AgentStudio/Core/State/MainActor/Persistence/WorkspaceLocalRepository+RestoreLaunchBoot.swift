import Foundation
import GRDB

extension WorkspaceLocalRepository {
    package func replaceTerminalRestoreLaunchBoot(currentBootId: String, recordedAt: Date) async throws
        -> TerminalRestoreLaunchBoot
    {
        try await databaseWriter.write { database in
            let previous = try String.fetchOne(
                database, sql: "SELECT boot_id FROM terminal_restore_launch_boot WHERE singleton = 1")
            try database.execute(
                sql: """
                    INSERT INTO terminal_restore_launch_boot(singleton, boot_id, recorded_at) VALUES (1, ?, ?)
                    ON CONFLICT(singleton) DO UPDATE SET boot_id = excluded.boot_id, recorded_at = excluded.recorded_at
                    """,
                arguments: [currentBootId, recordedAt.ISO8601Format()])
            return .init(previousBootId: previous, currentBootId: currentBootId)
        }
    }
}
