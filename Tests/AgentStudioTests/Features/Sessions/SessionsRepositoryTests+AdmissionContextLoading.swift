import AgentStudioInfrastructure
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioSessions

extension SessionsRepositoryTests {
    @Test("hydrated evidence is read for pane restore but not fetched again for the next hook")
    func bindContextDoesNotReadHydratedEvidenceHistory() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        let baseRepository = fixture.makeRepository()
        _ = try await baseRepository.applyHook(makeHookAdmission(paneId: pane))
        _ = try await baseRepository.applyHook(
            makeHookAdmission(
                paneId: pane, eventName: .question,
                signal: .question(
                    toolCallId: "question-call",
                    questions: [
                        SessionQuestion(
                            question: "Continue?", header: "Approval", options: [], multiSelect: false)
                    ]),
                kind: .needsYouOpened))

        let recorder = SessionsRepositorySQLStatementRecorder()
        let tracedAccess = TracingSessionsSQLiteAccess(base: fixture.sqliteAccess, recorder: recorder)
        let repository = SessionsRepository(sqliteAccess: tracedAccess)
        let bindContext = try await tracedAccess.read { database in
            try SessionsRepositoryStorage.loadContext(
                database: database,
                query: .bind(paneId: pane, providerIdentifier: "codex", providerConversationId: "session-A"))
        }
        #expect(bindContext.evidence.isEmpty)
        #expect(selectsFromHistoryTables(in: recorder.statements()).isEmpty)

        recorder.reset()
        try await withSessionsIngestion(repository: repository) { ingestion in
            let hydrated = try await ingestion.sessionSummary(paneId: pane)
            #expect(hydrated?.status == .needsYou(.question))
            #expect(hydrated?.providerPrompts.count == 1)
            #expect(selectedHistoryTables(in: recorder.statements()) == sessionsHistoryTableNames)

            recorder.reset()
            let nextHook = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read")))
            #expect(nextHook.disposition == .applied)
            #expect(selectsFromHistoryTables(in: recorder.statements()).isEmpty)
        }
    }
}

private final class SessionsRepositorySQLStatementRecorder: Sendable {
    private let recordedSQL = Mutex<[String]>([])

    func record(_ event: Database.TraceEvent) {
        guard case .statement(let statement) = event else { return }
        recordedSQL.withLock { $0.append(statement.sql) }
    }

    func statements() -> [String] {
        recordedSQL.withLock { $0 }
    }

    func reset() {
        recordedSQL.withLock { $0.removeAll(keepingCapacity: true) }
    }
}

private struct TracingSessionsSQLiteAccess: SessionsSQLiteAccess {
    let base: TestSessionsSQLiteAccess
    let recorder: SessionsRepositorySQLStatementRecorder

    func read<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await base.read { database in
            try withSQLTrace(database: database, recorder: recorder, operation: operation)
        }
    }

    func write<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await base.write { database in
            try withSQLTrace(database: database, recorder: recorder, operation: operation)
        }
    }
}

private func withSQLTrace<Output: Sendable>(
    database: Database,
    recorder: SessionsRepositorySQLStatementRecorder,
    operation: @Sendable (Database) throws -> Output
) throws -> Output {
    database.trace(options: .statement) { recorder.record($0) }
    defer { database.trace(options: []) }
    return try operation(database)
}

private func selectsFromHistoryTables(in statements: [String]) -> [String] {
    statements.filter { sql in
        let normalizedSQL = sql.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalizedSQL.hasPrefix("select ")
            && sessionsHistoryTableNames.contains { normalizedSQL.contains("from \($0)") }
    }
}

private func selectedHistoryTables(in statements: [String]) -> Set<String> {
    Set(
        statements.flatMap { (sql: String) -> [String] in
            let normalizedSQL = sql.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard normalizedSQL.hasPrefix("select ") else { return [] }
            return Array(sessionsHistoryTableNames.filter { normalizedSQL.contains("from \($0)") })
        })
}

private let sessionsHistoryTableNames: Set<String> = [
    "sessions_evidence", "sessions_provider_question", "sessions_provider_question_option",
]
