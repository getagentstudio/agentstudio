import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioSessions

extension SessionsRepositoryTests {
    @Test("the new handling migration leaves a retained permission null and restores it as reportOnly")
    func retainedPermissionDefaultsToReportOnly() async throws {
        let database = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "AgentStudio.sqlite.permission-migration")
        try WorkspaceLocalMigrations.migrator.migrate(database, upTo: "020_sessions_status_and_replay")
        let access = TestSessionsSQLiteAccess(databaseQueue: database)
        let repository = SessionsRepository(sqliteAccess: access)
        let paneId = UUIDv7.generate()
        let sourceId = UUIDv7.generate()
        let occurrenceId = UUIDv7.generate()
        let attentionId = UUIDv7.generate()
        try await withSessionsIngestion(repository: repository) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: SessionsMutation.bind(
                    makeQualifiedBindMutation(
                        paneId: paneId, providerConversationId: "legacy", sourceGenerationId: sourceId, reportedAt: 1)))
        }
        try await access.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO sessions_attention(
                        id, conversation_id, binding_generation_id, source_generation_id, source_kind,
                        subject_key, request_id, attention_kind, origin, freshness, disposition,
                        opened_occurrence_id, opened_at, committed_revision
                    ) SELECT ?, conversation_id, binding_generation_id, source_generation_id, 'provider',
                        'root', 'legacy-permission', 'permission', 'reported', 'live', 'current', ?, 2, committed_revision
                      FROM sessions_pane_binding WHERE pane_id = ?
                    """,
                arguments: [attentionId.uuidString, occurrenceId.uuidString, paneId.uuidString])
            try connection.execute(
                sql: """
                    INSERT INTO sessions_evidence(
                        occurrence_id, conversation_id, binding_generation_id, source_generation_id,
                        subject_kind, evidence_kind, attention_id, origin, freshness, occurred_at,
                        committed_revision, admission_sequence, provider_event, tool_name
                    ) SELECT ?, conversation_id, binding_generation_id, source_generation_id,
                        'root', 'needsYouOpened', ?, 'reported', 'live', 2,
                        committed_revision, committed_revision, 'permission', 'Bash'
                      FROM sessions_pane_binding WHERE pane_id = ?
                    """,
                arguments: [occurrenceId.uuidString, attentionId.uuidString, paneId.uuidString])
        }
        try WorkspaceLocalMigrations.migrate(database)
        let context = try await repository.statusContext(paneId: paneId)
        let firstEvidence = context.evidence.first
        let evidence = try #require(firstEvidence)
        let expectedSignal = SessionProviderSignal.permission(
            toolName: "Bash", questions: nil, handling: SessionPermissionHandling.reportOnly)
        #expect(evidence.providerSignal == expectedSignal)
        let remainsNull = try await access.read { connection in
            try Bool.fetchOne(
                connection, sql: "SELECT permission_handling IS NULL FROM sessions_evidence WHERE occurrence_id = ?",
                arguments: [occurrenceId.uuidString])
        }
        #expect(remainsNull == true)
        try await withSessionsIngestion(repository: repository) { ingestion in
            let summary = try await ingestion.sessionSummary(paneId: paneId)
            #expect(summary?.status == .needsYou(.approval))
            #expect(summary?.providerPrompts.count == 1)
        }
    }

}
