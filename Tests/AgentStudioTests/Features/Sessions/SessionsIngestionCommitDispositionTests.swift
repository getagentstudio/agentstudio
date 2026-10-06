import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions commit disposition")
struct SessionsIngestionCommitDispositionTests {
    @Test("status effect is decided at admission and persisted for reload")
    func recordOnlyIsNotALiveFact() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let bound = try await ingestion.submitHook(makeHookAdmission(paneId: pane))
            #expect(bound.disposition == .bound)
            _ = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .sessionEnd, signal: .sessionEnd))
            let recorded = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read")))
            #expect(recorded.disposition == .recordedOnly)
            #expect(recorded.evidence.statusEffect == .recordedOnly)
            #expect(recorded.evidence.recordId != bound.evidence.recordId)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .idle(.ended))
        }
    }
}
