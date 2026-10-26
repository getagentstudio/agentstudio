import AgentStudioCore
import AgentStudioSessions
import AgentStudioTerminal
import Foundation
import GRDB

struct WorkspaceForegroundEvidenceSQLiteAccess: ForegroundEvidenceSQLiteAccess {
    let sqliteAccess: any SessionsSQLiteAccess

    init(datastore: WorkspaceSQLiteDatastoreActor) {
        sqliteAccess = WorkspaceSessionsSQLiteAccess(datastore: datastore)
    }

    init(sqliteAccess: any SessionsSQLiteAccess) { self.sqliteAccess = sqliteAccess }
    let latestBinding: @Sendable (Database, UUID) throws -> ForegroundLatestBinding? = { database, paneId in
        guard let binding = try SessionsRepositoryStorage.loadBindings(database: database, paneId: paneId).first else {
            return nil
        }
        return .init(bindingGenerationId: binding.bindingGenerationId)
    }

    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await sqliteAccess.read(operation)
    }

    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await sqliteAccess.write(operation)
    }
}
