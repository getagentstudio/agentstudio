import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

extension SessionsIngestionTests {
    @Test("a first SessionEnd takeover ends both bindings and sources in one durable commit")
    func sessionEndTakeoverKeepsSupersededEnd() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let firstGeneration = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let outcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "A", eventName: .toolActivity,
                    signal: .toolActivity(toolName: "Read")))
            let committed = try #require(committedHookCommit(from: outcome))
            return committed.binding.bindingGenerationId
        }
        let incomingGeneration = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let initial = try await ingestion.sessionSummary(paneId: pane)
            #expect(initial?.sessionRef.value == "A")
            let repository = await ingestion.repository
            let before = try await repository.statusContext(paneId: pane)
            let outcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "B", eventName: .sessionEnd, signal: .sessionEnd, turnId: nil))
            let committed = try #require(committedHookCommit(from: outcome))
            #expect(committed.disposition == .bound)
            #expect(committed.binding.status == .ended)
            let after = try await repository.statusContext(paneId: pane)
            #expect(after.revision == before.revision + 1)
            #expect(after.bindings.count == 2)
            #expect(after.bindings.allSatisfy { $0.status == .ended })
            #expect(after.bindings.allSatisfy { $0.endedAt == committed.evidence.occurredAt })
            #expect(after.sources.count == 2)
            #expect(after.sources.allSatisfy { $0.status == .ended })
            #expect(after.currentBinding?.bindingGenerationId == committed.binding.bindingGenerationId)
            let bindingRevisions = try await repository.sqliteAccess.read { database in
                try Int64.fetchAll(
                    database,
                    sql: "SELECT committed_revision FROM sessions_pane_binding WHERE pane_id = ?",
                    arguments: [pane.uuidString])
            }
            #expect(bindingRevisions == [committed.revision, committed.revision])
            let summary = try await ingestion.sessionSummary(paneId: pane)
            #expect(summary?.sessionRef.value == "B")
            #expect(summary?.status == .idle(.ended))
            return committed.binding.bindingGenerationId
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restarted in
            let summary = try await restarted.sessionSummary(paneId: pane)
            #expect(summary?.sessionRef.value == "B")
            #expect(summary?.bindingGeneration == incomingGeneration)
            #expect(summary?.status == .idle(.ended))
            let context = try await restarted.repository.statusContext(paneId: pane)
            let firstBinding = try #require(context.bindings.first { $0.bindingGenerationId == firstGeneration })
            let firstSource = try #require(context.sources.first { $0.bindingGenerationId == firstGeneration })
            #expect(firstBinding.status == .ended)
            #expect(firstSource.status == .ended)
            #expect(firstBinding.endedAt == firstSource.endedAt)
            #expect(context.currentBinding?.bindingGenerationId == incomingGeneration)
        }
    }
}
