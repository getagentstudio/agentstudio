import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions repository")
struct SessionsRepositoryTests {
    @Test("provider prompt text is exact and only a matching resolution changes its state")
    func exactPromptAndMatchingResolution() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let source = UUIDv7.generate()
        let exactText = "  Preserve this\nline  "
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId, providerConversationId: "prompt", sourceGenerationId: source, reportedAt: 1)))
            for (request, explanation) in [("first", exactText), ("second", "Unrelated prompt")] {
                _ = try await ingestion.submit(
                    correlationId: UUIDv7.generate(),
                    mutation: .recordEvidence(
                        makeSessionsEvidenceMutation(
                            paneId: paneId, sourceGenerationId: source,
                            kind: .needsYouOpened(requestId: request, explanation: explanation), at: 2)))
            }
            let before = try await self.context(fixture, paneId: paneId)
            let first = try #require(before.attention.first { $0.requestId == "first" })
            #expect(first.explanation == exactText)
            #expect(first.disposition == .current)
            _ = try await ingestion.sessionSummary(paneId: paneId)
            _ = try await ingestion.snapshot(makeSessionsSnapshotQuery(paneId: paneId))
            let afterReads = try await self.context(fixture, paneId: paneId)
            #expect(afterReads.attention == before.attention)
            for time in [3.0, 4.0] {
                _ = try await ingestion.submit(
                    correlationId: UUIDv7.generate(),
                    mutation: .recordEvidence(
                        makeSessionsEvidenceMutation(
                            paneId: paneId, sourceGenerationId: source,
                            kind: .needsYouResolved(requestId: "first"), at: time)))
            }
            let after = try await self.context(fixture, paneId: paneId)
            #expect(after.attention.first { $0.requestId == "first" }?.disposition == .resolved)
            #expect(after.attention.first { $0.requestId == "second" }?.disposition == .current)
            #expect(after.attention.first { $0.requestId == "first" }?.explanation == exactText)
        }
    }

    @Test("equivalent correlation replay is one occurrence and conflicting reuse changes nothing")
    func correlationDeduplicationAndConflict() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let source = UUIDv7.generate()
        let occurrenceId = UUIDv7.generate()
        let correlationId = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId, providerConversationId: "replay", sourceGenerationId: source, reportedAt: 1)))
            let mutation = SessionsMutation.recordEvidence(
                makeSessionsEvidenceMutation(
                    paneId: paneId, sourceGenerationId: source, kind: .activityStarted, occurrenceId: occurrenceId,
                    at: 2))
            let first = try await ingestion.submit(correlationId: correlationId, mutation: mutation)
            let replay = try await ingestion.submit(correlationId: correlationId, mutation: mutation)
            #expect(replay == first)
            #expect(first == .evidenceRecorded(occurrenceId: occurrenceId))
            let before = try await self.context(fixture, paneId: paneId)
            #expect(before.evidence.map(\.occurrenceId) == [occurrenceId])
            await #expect(throws: SessionsRepositoryError.correlationConflict(correlationId)) {
                _ = try await ingestion.submit(
                    correlationId: correlationId,
                    mutation: .recordEvidence(
                        makeSessionsEvidenceMutation(
                            paneId: paneId, sourceGenerationId: source,
                            kind: .completed, occurrenceId: occurrenceId, at: 20)))
            }
            let afterConflict = try await self.context(fixture, paneId: paneId)
            #expect(afterConflict.evidence == before.evidence)
        }
    }

    @Test("domain and operation writes roll back together")
    func domainAndOperationWritesRollBackTogether() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let source = UUIDv7.generate()
        let correlationId = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId, providerConversationId: "rollback", sourceGenerationId: source, reportedAt: 1)))
            try await fixture.sqliteAccess.write { database in
                try database.execute(
                    sql: """
                        CREATE TRIGGER reject_sessions_evidence BEFORE INSERT ON sessions_evidence
                        BEGIN SELECT RAISE(ABORT, 'forced sessions rollback'); END
                        """)
            }
            await #expect(throws: DatabaseError.self) {
                _ = try await ingestion.submit(
                    correlationId: correlationId,
                    mutation: .recordEvidence(
                        makeSessionsEvidenceMutation(
                            paneId: paneId, sourceGenerationId: source, kind: .activityStarted, at: 2)))
            }
            let counts = try await fixture.sqliteAccess.read { database in
                (
                    operation: try Int.fetchOne(
                        database, sql: "SELECT COUNT(*) FROM sessions_operation WHERE correlation_id = ?",
                        arguments: [correlationId.uuidString]) ?? -1,
                    evidence: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_evidence") ?? -1
                )
            }
            #expect(counts.operation == 0)
            #expect(counts.evidence == 0)
        }
    }

    @Test("late provider evidence preserves provenance after database reopen")
    func lateProviderEvidenceSurvivesReopen() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let paneId = UUIDv7.generate()
        let source = UUIDv7.generate()
        let occurrenceId = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId, providerConversationId: "reopen", sourceGenerationId: source, reportedAt: 1)))
            var evidence = makeSessionsEvidenceMutation(
                paneId: paneId, sourceGenerationId: source,
                kind: .activityStarted, occurrenceId: occurrenceId, at: 2)
            evidence = SessionsEvidenceMutation(
                context: evidence.context, occurrenceId: occurrenceId,
                turnId: evidence.turnId, subject: evidence.subject, kind: evidence.kind, origin: .reported,
                freshness: .late, occurredAt: evidence.occurredAt, sourceCursor: nil)
            let outcome = try await ingestion.submit(
                correlationId: UUIDv7.generate(), mutation: .recordEvidence(evidence))
            #expect(outcome == .historical(occurrenceId: occurrenceId))
        }
        let repository = try fixture.makeRepository()
        let context = try await repository.statusContext(paneId: paneId)
        let evidence = try #require(context.evidence.first { $0.occurrenceId == occurrenceId })
        #expect(evidence.sourceGenerationId == source)
        #expect(evidence.freshness == .historical)
        #expect(evidence.origin == .reported)
        #expect(evidence.occurredAt == Date(timeIntervalSince1970: 2))
        #expect(evidence.kind == .activityStarted)
    }

    private func context(_ fixture: SessionsDatabaseFixture, paneId: UUID) async throws -> SessionsRepositoryContext {
        try await fixture.makeRepository().statusContext(paneId: paneId)
    }
}
