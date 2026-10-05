import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions ingestion")
struct SessionsIngestionTests {
    @Test("hooks share the FIFO and a full pane queue refuses without recording a loss")
    func queueCapacityIsBounded() async throws {
        let fixture = try SessionsDatabaseFixture()
        let held = HeldStep<Void>("first Sessions hook commit")
        let access = HeldHookSQLiteAccess(base: fixture.sqliteAccess, held: held)
        let ingestion = SessionsIngestion(
            repository: .init(sqliteAccess: access),
            limits: .init(maximumPendingPerPane: 1, maximumPendingGlobal: 2), probe: { _ in })
        let pane = UUIDv7.generate()
        let first = Task {
            do {
                return Result<SessionsHookCommit, any Error>.success(
                    try await ingestion.submitHook(makeHookAdmission(paneId: pane)))
            } catch { return .failure(error) }
        }
        do {
            try await held.firstArrival()
            await #expect(throws: SessionsRepositoryError.paneQueueFull(pane)) {
                try await ingestion.submitHook(
                    makeHookAdmission(paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read")))
            }
            held.release()
            let result = await first.value
            #expect(try result.get().disposition == .bound)
            let count = try await fixture.sqliteAccess.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions_evidence")
            }
            let losses = try await fixture.sqliteAccess.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions_loss")
            }
            #expect(count == 1)
            #expect(losses == 0)
            await ingestion.finish()
        } catch {
            held.release()
            if case .failure(let childError) = await first.value { Issue.record("Hook task failed: \(childError)") }
            await ingestion.finish()
            throw error
        }
    }

    @Test("a finished owner rejects hooks and app restart does not end an active session")
    func restartKeepsActiveBinding() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let initial = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read")))
            return try await ingestion.sessionSummary(paneId: pane)
        }
        let restarted = SessionsIngestion(
            repository: try fixture.makeRepository(),
            limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in })
        #expect(try await restarted.sessionSummary(paneId: pane) == initial)
        await restarted.finish()
        await #expect(throws: SessionsRepositoryError.ingestionFinished) {
            try await restarted.submitHook(makeHookAdmission(paneId: pane))
        }
    }
}

private actor HeldHookSQLiteAccess: SessionsSQLiteAccess {
    let base: TestSessionsSQLiteAccess
    let held: HeldStep<Void>
    var holdsNextWrite = true
    init(base: TestSessionsSQLiteAccess, held: HeldStep<Void>) {
        self.base = base
        self.held = held
    }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await base.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        if holdsNextWrite {
            holdsNextWrite = false
            try await held.arrive(())
        }
        return try await base.write(operation)
    }
}
