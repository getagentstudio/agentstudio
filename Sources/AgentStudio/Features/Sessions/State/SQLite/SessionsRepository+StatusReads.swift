import Foundation
import GRDB

extension SessionsRepositoryStorage {
    /// The App supplies this read to Core's commit-time writer check; Sessions
    /// remains the sole owner of binding persistence.
    package static func currentBindingGeneration(paneId: UUID, in database: Database) throws -> UUID? {
        try String.fetchOne(
            database,
            sql: """
                SELECT binding_generation_id FROM sessions_pane_binding
                WHERE pane_id = ? AND status = 'active' ORDER BY committed_revision DESC LIMIT 1
                """, arguments: [paneId.uuidString]
        ).map(decodeUuid)
    }
}

extension SessionsRepository {
    package func statusContext(paneId: UUID) async throws -> SessionsRepositoryContext {
        try await sqliteAccess.read { try SessionsRepositoryStorage.loadContext(database: $0, query: .pane(paneId)) }
    }

    package func statusPaneIds() async throws -> [UUID] {
        try await sqliteAccess.read { database in
            try String.fetchAll(database, sql: "SELECT DISTINCT pane_id FROM sessions_pane_binding")
                .map(SessionsRepositoryStorage.decodeUuid)
        }
    }
}
