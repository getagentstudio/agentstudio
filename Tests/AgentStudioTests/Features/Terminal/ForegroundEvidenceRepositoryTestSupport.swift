import AgentStudioInfrastructure
import Foundation
import GRDB

@testable import AgentStudioCore
@testable import AgentStudioTerminal

struct TestForegroundEvidenceSQLiteAccess: ForegroundEvidenceSQLiteAccess {
    let databaseQueue: DatabaseQueue
    var latestBinding: @Sendable (Database, UUID) throws -> ForegroundLatestBinding? {
        { database, paneId in
            guard
                let row = try Row.fetchOne(
                    database, sql: "SELECT generation, is_live FROM fixture_latest_binding WHERE pane_id = ?",
                    arguments: [paneId.uuidString])
            else { return nil }
            guard let generation = UUID(uuidString: row["generation"]) else {
                throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
            }
            return .init(bindingGenerationId: generation, isLive: row["is_live"])
        }
    }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await databaseQueue.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await databaseQueue.write(operation)
    }
}

struct ForegroundEvidenceRepositoryFixture: Sendable {
    let database: DatabaseQueue
    let repository: SQLitePaneForegroundEvidenceRepository
    let paneId = UUIDv7.generate()
    let sessionId = ZmxSessionID.generateUUIDv7()
    let generation = UUIDv7.generate()
    let launchId = UUIDv7.generate()

    init() throws {
        database = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "foreground-evidence")
        try WorkspaceLocalMigrations.migrate(database)
        try database.write { database in
            try database.execute(
                sql: "CREATE TABLE fixture_latest_binding(pane_id TEXT PRIMARY KEY, generation TEXT, is_live INTEGER)")
        }
        repository = SQLitePaneForegroundEvidenceRepository(
            access: TestForegroundEvidenceSQLiteAccess(databaseQueue: database), observerLaunchId: launchId)
        try database.write { database in
            try database.execute(
                sql: "INSERT INTO fixture_latest_binding VALUES (?,?,1)",
                arguments: [paneId.uuidString, generation.uuidString])
        }
    }

    func bind(generation: UUID, isLive: Bool = true) async throws {
        try await database.write { database in
            try database.execute(
                sql: "UPDATE fixture_latest_binding SET generation = ?, is_live = ? WHERE pane_id = ?",
                arguments: [generation.uuidString, isLive, paneId.uuidString])
        }
    }

    func report(_ evidence: ForegroundEvidence, sequence: UInt64) async throws -> ForegroundEvidenceAdmission {
        try await database.write { database in
            try repository.write(
                in: database, evidence: evidence, paneId: paneId, bindingGenerationId: generation,
                sequence: sequence, observedAt: Date(timeIntervalSince1970: 100))
        }
    }

}
