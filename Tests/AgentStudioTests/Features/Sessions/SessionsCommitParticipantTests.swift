import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioSessions

@Suite("Sessions commit participant")
struct SessionsCommitParticipantTests {
    enum MutationCase: Sendable {
        case bind
        case message
    }

    @Test(
        "a throwing participant rolls back the operation, effect and cursor", arguments: [MutationCase.bind, .message])
    func participantFailureRollsBackEveryWrite(mutationCase: MutationCase) async throws {
        let fixture = try await makeParticipantFixture()
        defer { fixture.removeFiles() }
        let submission = fixture.submission(mutationCase: mutationCase)
        let participant = TestCursorCommitParticipant(storeID: fixture.storeID, position: 1, failsAfterWrite: true)

        await #expect(throws: TestParticipantFailure.self) {
            _ = try await fixture.repository.apply(
                operation: submission.operation, commitParticipant: participant
            ) { context in
                try SessionsEvidenceReducer.reduce(mutation: submission.mutation, against: context)
            }
        }

        let state = try await fixture.state()
        #expect(state.operationCount == 0)
        #expect(state.bindingCount == 0)
        #expect(state.messageCount == 0)
        #expect(state.cursor == 0)
    }

    @Test("operation replay still advances the participating cursor without reducing again")
    func operationReplayRunsParticipant() async throws {
        let fixture = try await makeParticipantFixture()
        defer { fixture.removeFiles() }
        let submission = fixture.submission(mutationCase: .bind)
        let original = try await fixture.apply(submission)

        let replay = try await fixture.repository.apply(
            operation: submission.operation,
            commitParticipant: TestCursorCommitParticipant(storeID: fixture.storeID, position: 2)
        ) { _ in
            Issue.record("Operation replay reached reduction")
            return SessionsRepositoryReduction(outcome: original.outcome)
        }

        #expect(replay.disposition == .replayed)
        #expect(replay.outcome == original.outcome)
        let state = try await fixture.state()
        #expect(state.operationCount == 1)
        #expect(state.bindingCount == 1)
        #expect(state.cursor == 2)
    }

    @Test("occurrence replay still advances the participating cursor without a second effect")
    func occurrenceReplayRunsParticipant() async throws {
        let fixture = try await makeParticipantFixture()
        defer { fixture.removeFiles() }
        let submission = fixture.submission(mutationCase: .bind)
        let original = try await fixture.apply(submission)

        let replay = try await fixture.repository.apply(
            operation: fixture.aliasOperation(for: submission.operation),
            commitParticipant: TestCursorCommitParticipant(storeID: fixture.storeID, position: 3)
        ) { _ in
            Issue.record("Occurrence replay reached reduction")
            return SessionsRepositoryReduction(outcome: original.outcome)
        }

        #expect(replay.disposition == .replayed)
        #expect(replay.outcome == original.outcome)
        let state = try await fixture.state()
        #expect(state.operationCount == 2)
        #expect(state.bindingCount == 1)
        #expect(state.cursor == 3)
    }

    @Test("participant failure on operation replay preserves the original effect and cursor")
    func operationReplayFailureRollsBackParticipant() async throws {
        let fixture = try await makeParticipantFixture()
        defer { fixture.removeFiles() }
        let submission = fixture.submission(mutationCase: .bind)
        let original = try await fixture.apply(submission)
        let participant = TestCursorCommitParticipant(storeID: fixture.storeID, position: 4, failsAfterWrite: true)

        await #expect(throws: TestParticipantFailure.self) {
            _ = try await fixture.repository.apply(
                operation: submission.operation,
                commitParticipant: participant
            ) { _ in
                Issue.record("Operation replay reached reduction")
                return SessionsRepositoryReduction(outcome: original.outcome)
            }
        }

        let state = try await fixture.state()
        #expect(state.operationCount == 1)
        #expect(state.bindingCount == 1)
        #expect(state.cursor == 0)
    }

    @Test("participant failure on occurrence replay rolls back its operation alias too")
    func occurrenceReplayFailureRollsBackAlias() async throws {
        let fixture = try await makeParticipantFixture()
        defer { fixture.removeFiles() }
        let submission = fixture.submission(mutationCase: .bind)
        let original = try await fixture.apply(submission)
        let participant = TestCursorCommitParticipant(storeID: fixture.storeID, position: 5, failsAfterWrite: true)

        await #expect(throws: TestParticipantFailure.self) {
            _ = try await fixture.repository.apply(
                operation: fixture.aliasOperation(for: submission.operation), commitParticipant: participant
            ) { _ in
                Issue.record("Occurrence replay reached reduction")
                return SessionsRepositoryReduction(outcome: original.outcome)
            }
        }

        let state = try await fixture.state()
        #expect(state.operationCount == 1)
        #expect(state.bindingCount == 1)
        #expect(state.cursor == 0)
    }

    @Test("live nil-participant submissions preserve the existing effect")
    func nilParticipantPreservesLiveSubmission() async throws {
        let fixture = try await makeParticipantFixture()
        defer { fixture.removeFiles() }

        let inserted = try await fixture.apply(fixture.submission(mutationCase: .message))

        #expect(inserted.disposition == .inserted)
        let state = try await fixture.state()
        #expect(state.operationCount == 1)
        #expect(state.messageCount == 1)
        #expect(state.cursor == 0)
    }

    @Test("ingestion carries the participant through its normal FIFO submission")
    func ingestionPreservesParticipant() async throws {
        let fixture = try await makeParticipantFixture()
        defer { fixture.removeFiles() }
        let submission = fixture.submission(mutationCase: .message)
        try await withSessionsIngestion(repository: fixture.repository) { ingestion in
            _ = try await ingestion.submit(
                correlationId: submission.operation.correlationId, mutation: submission.mutation,
                commitParticipant: TestCursorCommitParticipant(storeID: fixture.storeID, position: 6))
        }

        let state = try await fixture.state()
        #expect(state.messageCount == 1)
        #expect(state.cursor == 6)
    }
}

private struct TestParticipantFailure: Error {}

private struct TestCursorCommitParticipant: SessionsCommitParticipant {
    let storeID: UUID
    let position: Int64
    var failsAfterWrite = false

    func commit(in database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO pane_context_cli_outbox_cursor (store_id, last_handled_id) VALUES (?, ?)
                ON CONFLICT(store_id) DO UPDATE SET last_handled_id = excluded.last_handled_id
                """,
            arguments: [storeID.uuidString, position])
        if failsAfterWrite { throw TestParticipantFailure() }
    }
}

private struct ParticipantDatabaseState: Sendable {
    let operationCount: Int
    let bindingCount: Int
    let messageCount: Int
    let cursor: Int64
}

private struct ParticipantSubmission: Sendable {
    let operation: SessionsRepositoryOperation
    let mutation: SessionsMutation
}

private func makeParticipantFixture() async throws -> SessionsParticipantFileFixture {
    try await valueFromDedicatedThread { try SessionsParticipantFileFixture() }
}

/// Real file, migrations, repository and transaction; only the participating
/// write may deliberately fail. The App-shaped table is test-owned here until
/// its production migration lands with S2 green.
private struct SessionsParticipantFileFixture: Sendable {
    let rootURL: URL
    let sqliteAccess: TestSessionsSQLiteAccess
    let repository: SessionsRepository
    let storeID = UUIDv7.generate()
    let paneID = UUIDv7.generate()

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: "sessions-participant-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let databaseQueue = try DatabaseQueue(path: rootURL.appending(path: "local.sqlite").path)
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS pane_context_cli_outbox_cursor (
                        store_id TEXT PRIMARY KEY NOT NULL,
                        last_handled_id INTEGER NOT NULL
                    )
                    """)
        }
        sqliteAccess = TestSessionsSQLiteAccess(databaseQueue: databaseQueue)
        repository = SessionsRepository(sqliteAccess: sqliteAccess)
    }

    func submission(mutationCase: SessionsCommitParticipantTests.MutationCase) -> ParticipantSubmission {
        let occurrenceID = UUIDv7.generate()
        let mutation: SessionsMutation
        let query: SessionsRepositoryContextQuery
        let providerOccurrence: SessionsProviderOccurrenceIdentity?
        let operationKind: String
        switch mutationCase {
        case .bind:
            mutation = .bind(
                makeQualifiedBindMutation(
                    paneId: paneID, providerConversationId: "participant-conversation",
                    sourceGenerationId: UUIDv7.generate(), occurrenceId: occurrenceID, reportedAt: 1))
            query = .bind(
                paneId: paneID, providerIdentifier: "qualified-test-provider",
                providerConversationId: "participant-conversation")
            providerOccurrence = .init(kind: .bind, occurrenceId: occurrenceID)
            operationKind = SessionsProviderOccurrenceKind.bind.rawValue
        case .message:
            mutation = .message(
                SessionsMessageMutation(
                    context: .unattributed(paneId: paneID), text: "participant message", freshness: .live,
                    receivedAt: Date(timeIntervalSince1970: 1)))
            query = .pane(paneID)
            providerOccurrence = nil
            operationKind = "message"
        }
        return ParticipantSubmission(
            operation: SessionsRepositoryOperation(
                correlationId: UUIDv7.generate(), operationScope: "pane:\(paneID.uuidString)",
                operationKind: operationKind, semanticFingerprint: "participant-\(operationKind)",
                providerOccurrence: providerOccurrence, contextQuery: query, createdAt: Date(timeIntervalSince1970: 1)),
            mutation: mutation)
    }

    func aliasOperation(for original: SessionsRepositoryOperation) -> SessionsRepositoryOperation {
        SessionsRepositoryOperation(
            correlationId: UUIDv7.generate(), operationScope: original.operationScope,
            operationKind: original.operationKind, semanticFingerprint: original.semanticFingerprint,
            providerOccurrence: original.providerOccurrence, contextQuery: original.contextQuery,
            createdAt: original.createdAt)
    }

    func apply(_ submission: ParticipantSubmission) async throws -> SessionsSubmissionResult {
        try await repository.apply(operation: submission.operation) { context in
            try SessionsEvidenceReducer.reduce(mutation: submission.mutation, against: context)
        }
    }

    func state() async throws -> ParticipantDatabaseState {
        let storeID = storeID
        return try await sqliteAccess.read { database in
            try ParticipantDatabaseState(
                operationCount: Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_operation") ?? 0,
                bindingCount: Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_pane_binding") ?? 0,
                messageCount: Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_message") ?? 0,
                cursor: Int64.fetchOne(
                    database,
                    sql: "SELECT last_handled_id FROM pane_context_cli_outbox_cursor WHERE store_id = ?",
                    arguments: [storeID.uuidString]) ?? 0)
        }
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
