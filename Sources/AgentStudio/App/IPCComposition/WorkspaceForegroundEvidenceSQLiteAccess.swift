import AgentStudioCore
import AgentStudioSessions
import AgentStudioTerminal
import Foundation
import GRDB

struct WorkspaceForegroundEvidenceSQLiteAccess: ForegroundEvidenceSQLiteAccess {
    let datastore: WorkspaceSQLiteDatastoreActor
    let latestBinding: @Sendable (Database, UUID) throws -> ForegroundLatestBinding? = { database, paneId in
        guard let binding = try SessionsRepositoryStorage.loadBindings(database: database, paneId: paneId).first else {
            return nil
        }
        return .init(bindingGenerationId: binding.bindingGenerationId, isLive: binding.status == .active)
    }

    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await datastore.performApplicationLocalRead(operation)
    }

    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await datastore.performApplicationLocalWrite(operation)
    }
}
