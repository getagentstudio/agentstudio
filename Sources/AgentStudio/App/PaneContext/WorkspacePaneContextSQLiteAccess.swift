import AgentStudioCore
import GRDB

/// Hands Core the prepared application-local transaction boundary.
struct WorkspacePaneContextSQLiteAccess: PaneContextSQLiteAccess {
    private let datastore: WorkspaceSQLiteDatastoreActor

    init(datastore: WorkspaceSQLiteDatastoreActor) {
        self.datastore = datastore
    }

    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await datastore.performApplicationLocalRead(operation)
    }

    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await datastore.performApplicationLocalWrite(operation)
    }
}
