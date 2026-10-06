import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions remaining contracts")
struct SessionsRemainingContractTests {
    @Test("ended sessions stay readable and an ordinary hook cannot revive them after reload")
    func endedRecordsStayOutOfRestore() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submitHook(makeHookAdmission(paneId: pane))
            _ = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .sessionEnd, signal: .sessionEnd))
            let delayed = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, eventName: .permission,
                    signal: .permission(toolName: "Read", questions: nil)))
            #expect(delayed.disposition == .recordedOnly)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .idle(.ended))
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restored in
            #expect(try await restored.sessionSummary(paneId: pane)?.status == .idle(.ended))
            let rebound = try await restored.submitHook(makeHookAdmission(paneId: pane))
            #expect(rebound.disposition == .bound)
            #expect(try await restored.sessionSummary(paneId: pane)?.status == .unknown)
        }
    }

    @Test("an active-elsewhere hook stays record-only after both pane owners reload")
    func elsewhereRecordsStayOutOfRestore() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let first = UUIDv7.generate()
        let moved = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submitHook(makeHookAdmission(paneId: first))
            _ = try await ingestion.submitHook(makeHookAdmission(paneId: moved))
            _ = try await ingestion.submitHook(
                makeHookAdmission(paneId: moved, eventName: .toolActivity, signal: .toolActivity(toolName: "Read")))
            let stale = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: first, eventName: .permission,
                    signal: .permission(toolName: "Read", questions: nil)))
            #expect(stale.disposition == .recordedOnly)
            #expect(try await ingestion.sessionSummary(paneId: first)?.status == .idle(.ended))
            #expect(try await ingestion.sessionSummary(paneId: moved)?.status == .working(.active))
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let firstSummary = try await ingestion.sessionSummary(paneId: first)
            let movedSummary = try await ingestion.sessionSummary(paneId: moved)
            #expect(firstSummary?.status == .idle(.ended))
            #expect(movedSummary?.status == .working(.active))
            #expect(movedSummary?.providerPrompts.isEmpty == true)
        }
    }
}
