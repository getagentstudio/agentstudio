import AgentStudioInfrastructure
import Foundation
import GRDB

@testable import AgentStudioCore
@testable import AgentStudioSessions

struct SessionsDatabaseFixture {
    let databaseQueue: DatabaseQueue
    let sqliteAccess: TestSessionsSQLiteAccess

    init() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(
            label: "AgentStudio.sqlite.sessions-tests"
        )
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        self.databaseQueue = databaseQueue
        sqliteAccess = TestSessionsSQLiteAccess(databaseQueue: databaseQueue)
    }

    func makeRepository() -> SessionsRepository {
        SessionsRepository(sqliteAccess: sqliteAccess)
    }

}

struct SessionsFileDatabaseFixture {
    let rootDirectory: URL
    let databaseURL: URL

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-sessions-\(UUIDv7.generate())")
        databaseURL = rootDirectory.appending(path: "local.sqlite")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    func makeRepository() throws -> SessionsRepository {
        let databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        return SessionsRepository(
            sqliteAccess: TestSessionsSQLiteAccess(databaseQueue: databaseQueue)
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

struct TestSessionsSQLiteAccess: SessionsSQLiteAccess {
    let databaseQueue: DatabaseQueue

    func read<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await databaseQueue.read(operation)
    }

    func write<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await databaseQueue.write(operation)
    }
}

func withSessionsIngestion<Output: Sendable>(
    repository: SessionsRepository,
    operation: @Sendable (SessionsIngestion) async throws -> Output
) async throws -> Output {
    let ingestion = SessionsIngestion(
        repository: repository,
        limits: SessionsIngestionLimits(
            maximumPendingPerPane: 32,
            maximumPendingGlobal: 128
        ),
        probe: { _ in }
    )
    do {
        let output = try await operation(ingestion)
        await ingestion.finish()
        return output
    } catch {
        await ingestion.finish()
        throw error
    }
}

func makeHookAdmission(
    paneId: UUID, sessionId: String = "session-A", eventName: SessionProviderSignalName = .sessionStart,
    signal: SessionProviderSignal? = .sessionStart, recordId: UUID = UUIDv7.generate(),
    providerVersion: String = "9.9.9", turnId: String? = "turn-A"
) -> SessionsHookAdmission {
    .init(
        paneId: paneId, providerIdentifier: "codex", providerVersion: providerVersion,
        sessionId: sessionId, eventName: eventName, turnId: turnId,
        signal: signal, recordId: recordId, admittedAt: Date(timeIntervalSince1970: 1_800_000_000),
        resumeHint: "codex resume \(sessionId)")
}
