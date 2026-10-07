import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions remaining contracts")
struct SessionsRemainingContractTests {
    @Test("ended sessions stay readable and only their SessionStart can revive them after reload")
    func endedRecordsStayOutOfRestore() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let endedBindingId = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let startOutcome = try await ingestion.submitHook(makeHookAdmission(paneId: pane))
            let start = try #require(committedHookCommit(from: startOutcome))
            let endOutcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .sessionEnd, signal: .sessionEnd))
            _ = try #require(committedHookCommit(from: endOutcome))
            let delayedOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, eventName: .permission,
                    signal: .permission(toolName: "Read", questions: nil)))
            let delayed = try #require(committedHookCommit(from: delayedOutcome))
            #expect(delayed.disposition == .recordedOnly)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .idle(.ended))
            return start.binding.bindingGenerationId
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restored in
            #expect(try await restored.sessionSummary(paneId: pane)?.status == .idle(.ended))
            let reboundOutcome = try await restored.submitHook(makeHookAdmission(paneId: pane))
            let rebound = try #require(committedHookCommit(from: reboundOutcome))
            #expect(rebound.disposition == .bound)
            #expect(rebound.binding.bindingGenerationId == endedBindingId)
            #expect(try await restored.sessionSummary(paneId: pane)?.status == .unknown)
        }
    }

    @Test("the same conversation has independent live bindings in two panes after reload")
    func sameConversationRemainsIndependentAcrossPanes() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let firstPane = UUIDv7.generate()
        let secondPane = UUIDv7.generate()
        let firstInstant = ContinuousClock.now
        let secondInstant = firstInstant + .milliseconds(1)
        let firstBindingId = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let firstOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: firstPane, sessionId: "shared", admissionInstant: firstInstant))
            let first = try #require(committedHookCommit(from: firstOutcome))
            let secondOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: secondPane, sessionId: "shared", eventName: .toolActivity,
                    signal: .toolActivity(toolName: "Read"), admissionInstant: secondInstant))
            let second = try #require(committedHookCommit(from: secondOutcome))
            #expect(second.disposition == .bound)
            #expect(second.binding.bindingGenerationId != first.binding.bindingGenerationId)
            #expect(try await ingestion.sessionSummary(paneId: firstPane)?.status == .unknown)
            #expect(try await ingestion.sessionSummary(paneId: secondPane)?.status == .working(.active))
            return first.binding.bindingGenerationId
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restored in
            let firstSummary = try await restored.sessionSummary(paneId: firstPane)
            let secondSummary = try await restored.sessionSummary(paneId: secondPane)
            #expect(firstSummary?.bindingGeneration == firstBindingId)
            #expect(secondSummary?.bindingGeneration != firstBindingId)
            #expect(firstSummary?.status == .unknown)
            #expect(secondSummary?.status == .working(.active))
        }
    }
}
