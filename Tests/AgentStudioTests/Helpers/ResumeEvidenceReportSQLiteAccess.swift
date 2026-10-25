import AgentStudioCore
import AgentStudioSessions
import AgentStudioTerminal
import Foundation
import GRDB

struct TestForegroundSQLiteAccess: ForegroundEvidenceSQLiteAccess, SessionsSQLiteAccess {
    let databaseQueue: DatabaseQueue
    var latestBinding: @Sendable (Database, UUID) throws -> ForegroundLatestBinding? {
        { database, paneId in
            guard let binding = try SessionsRepositoryStorage.loadBindings(database: database, paneId: paneId).first
            else { return nil }
            return .init(bindingGenerationId: binding.bindingGenerationId, isLive: binding.status == .active)
        }
    }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await databaseQueue.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await databaseQueue.write(operation)
    }
}
