import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

extension SessionsIngestionTests {
    @Test("refusal overwrites per pane, clears on retirement, and never reaches SQLite")
    func refusalMemoryLifetime() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        let otherPane = UUIDv7.generate()
        let first = SessionsHookRefusal(reason: .noSessionId, event: "SessionStart", at: Date(timeIntervalSince1970: 1))
        let replacement = SessionsHookRefusal(
            reason: .undecodablePayload, event: nil, at: Date(timeIntervalSince1970: 2))
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            await ingestion.recordRefusal(paneId: pane, refusal: first)
            await ingestion.recordRefusal(paneId: otherPane, refusal: first)
            await ingestion.recordRefusal(paneId: pane, refusal: replacement)
            #expect(await ingestion.lastRefusal(paneId: pane) == replacement)
            #expect(await ingestion.lastRefusal(paneId: otherPane) == first)
            let status = try await ingestion.readSessionStatus(paneId: pane)
            #expect(status == .unbound)
            let counts = try await fixture.sqliteAccess.read { database in
                try ["sessions_pane_binding", "sessions_operation", "sessions_evidence"].map {
                    try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \($0)")
                }
            }
            #expect(counts == [0, 0, 0])
            ingestion.paneViewedMailbox.retire([pane])
            #expect(await ingestion.lastRefusal(paneId: pane) == nil)
            await ingestion.recordRefusal(paneId: pane, refusal: first)
            #expect(await ingestion.lastRefusal(paneId: pane) == nil)
            #expect(await ingestion.lastRefusal(paneId: otherPane) == first)
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let absent = await ingestion.lastRefusal(paneId: otherPane)
            #expect(absent == nil)
        }
    }
}
