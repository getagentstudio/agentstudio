import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

extension SessionsIngestionTests {
    @Test("a named resume after terminal-only exit resets live and after reload without closing its new turn")
    func namedResumeKeepsResetAcrossReload() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let boundAt = ContinuousClock.now
        let resumeTurn = "resume-turn"
        let resume = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let firstOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "A", eventName: .toolActivity,
                    signal: .toolActivity(toolName: "Read"), admissionInstant: boundAt, turnId: "old-turn"))
            let first = try #require(committedHookCommit(from: firstOutcome))
            let exit = try await ingestion.submitCommandFinished(
                paneId: pane, reportedAt: boundAt.advanced(by: .seconds(1)))
            #expect(exit?.binding.status == .ended)
            let contextAfterExit = try await ingestion.repository.statusContext(paneId: pane)
            #expect(contextAfterExit.evidence.count == 1)
            #expect(contextAfterExit.evidence.allSatisfy { $0.providerSignal != .sessionEnd })
            let outcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "A", eventName: .sessionStart, signal: .sessionStart,
                    admissionInstant: boundAt.advanced(by: .seconds(2)), turnId: resumeTurn))
            let reopened = try #require(committedHookCommit(from: outcome))
            #expect(reopened.disposition == .bound)
            #expect(reopened.binding.bindingGenerationId == first.binding.bindingGenerationId)
            #expect(reopened.evidence.turnId == resumeTurn)
            let summary = try await ingestion.sessionSummary(paneId: pane)
            #expect(summary?.status == .unknown)
            return reopened
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restarted in
            let before = try await restarted.sessionSummary(paneId: pane)
            #expect(before?.bindingGeneration == resume.binding.bindingGenerationId)
            #expect(before?.sessionRef.value == "A")
            #expect(before?.status == .unknown)
            let stored = try await restarted.repository.statusContext(paneId: pane)
            #expect(stored.evidence.first { $0.recordId == resume.evidence.recordId }?.turnId == resumeTurn)
            let outcome = try await restarted.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "A", eventName: .toolActivity,
                    signal: .toolActivity(toolName: "Read"), turnId: resumeTurn))
            let applied = try #require(committedHookCommit(from: outcome))
            #expect(applied.disposition == .applied)
            let after = try await restarted.sessionSummary(paneId: pane)
            #expect(after?.status == .working(.active))
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restartedAgain in
            let summary = try await restartedAgain.sessionSummary(paneId: pane)
            #expect(summary?.bindingGeneration == resume.binding.bindingGenerationId)
            #expect(summary?.status == .working(.active))
            let stored = try await restartedAgain.repository.statusContext(paneId: pane)
            #expect(stored.evidence.first { $0.recordId == resume.evidence.recordId }?.turnId == resumeTurn)
        }
    }
}
