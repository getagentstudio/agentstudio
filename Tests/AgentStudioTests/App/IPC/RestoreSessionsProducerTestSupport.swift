import AgentStudioIPCClientCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions
@testable import AgentStudioTerminal

final class HeldResumeSessionsAccess: SessionsSQLiteAccess, Sendable {
    let database: DatabaseQueue
    private let nextHold = Mutex<HeldStep<Void>?>(nil)
    init(database: DatabaseQueue) { self.database = database }
    func holdNextWrite(_ hold: HeldStep<Void>) { nextHold.withLock { $0 = hold } }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await database.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        let hold = nextHold.withLock { held in
            defer { held = nil }
            return held
        }
        if let hold { try await hold.arrive(()) }
        return try await database.write(operation)
    }
}

struct AppResumeSessionsFixture: Sendable {
    let database: DatabaseQueue
    let access: HeldResumeSessionsAccess
    let repository: SessionsRepository
    let paneId = UUIDv7.generate()
    let sessionId = UUIDv7.generate().uuidString

    init() throws {
        database = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "resume-sessions-producers")
        try WorkspaceLocalMigrations.migrate(database)
        access = HeldResumeSessionsAccess(database: database)
        repository = SessionsRepository(sqliteAccess: access)
    }

    func makeIngestion() -> SessionsIngestion {
        SessionsIngestion(
            repository: repository, limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128),
            probe: { _ in }, terminalLeaderReader: MatchingTestPaneTerminalLeaderReader())
    }

    func context() async throws -> SessionsRepositoryContext {
        try await repository.statusContext(paneId: paneId)
    }

    func event(_ name: CodexHookEventName, version: String? = nil) throws -> IPCSessionEventParams {
        let payload = CodexHookPayload(
            sessionId: sessionId, turnId: "turn-proof", hookEventName: name.rawValue, codexVersion: version)
        let projected = try #require(CodexHookProjection.project(eventName: name, payload: payload))
        return .init(
            handle: paneId.uuidString, provider: projected.provider, event: projected.event,
            correlationId: UUIDv7.generate())
    }
}

func resumeProducerAdapter(ingestion: SessionsIngestion)
    -> AgentStudioIPCSessionsAdapter
{
    AgentStudioIPCSessionsAdapter(
        ingestion: ingestion, now: { Date(timeIntervalSince1970: 3) },
        processChainReader: EligibleTestProcessChainReader())
}
