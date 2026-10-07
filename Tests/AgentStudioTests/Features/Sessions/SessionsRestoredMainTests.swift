import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions restored main confirmation")
struct SessionsRestoredMainTests {
    @Test(
        "restored-main confirmation and takeover rows apply through lazy SQLite restore",
        arguments: RestoredMainScenario.allCases)
    func restoredMainScenarioApplies(scenario: RestoredMainScenario) async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        if scenario == .liveChildIgnored {
            try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
                _ = try await submitScenarioHook(.toolActivity, session: "S1", paneId: pane, ingestion: ingestion)
                try await expectLiveMain(ingestion, paneId: pane, session: "S1")
                let before = try await ingestion.repository.statusContext(paneId: pane)
                let child = try await submitScenarioHook(
                    .sessionStart, session: "S3", paneId: pane, ingestion: ingestion)
                #expect(child == .ignored)
                #expect(try await ingestion.repository.statusContext(paneId: pane) == before)
            }
            return
        }
        try await seedPersistedMain(scenario: scenario, fixture: fixture, paneId: pane)

        let expected = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            try await expectLiveMain(ingestion, paneId: pane, session: "S1")
            switch scenario {
            case .restoredSessionStartTakeover:
                _ = try await submitScenarioHook(.sessionStart, session: "S2", paneId: pane, ingestion: ingestion)
            case .restoredUserPromptTakeover:
                _ = try await submitScenarioHook(.turnStart, session: "S2", paneId: pane, ingestion: ingestion)
            case .restoredParentConfirmsThenChildIgnored:
                _ = try await submitScenarioHook(.toolActivity, session: "S1", paneId: pane, ingestion: ingestion)
                let child = try await submitScenarioHook(
                    .sessionStart, session: "S3", paneId: pane, ingestion: ingestion)
                #expect(child == .ignored)
            case .childFirstAfterRestore:
                _ = try await submitScenarioHook(.sessionStart, session: "S3", paneId: pane, ingestion: ingestion)
            case .restoredEndedSessionResume:
                _ = try await submitScenarioHook(.sessionStart, session: "S2", paneId: pane, ingestion: ingestion)
            case .restoredCommandExit:
                let closed = try await ingestion.submitCommandFinished(
                    paneId: pane, reportedAt: ContinuousClock.now)
                #expect(closed != nil)
            case .liveChildIgnored:
                Issue.record("Handled before scenario matrix")
            }
            let context = try await ingestion.repository.statusContext(paneId: pane)
            if scenario == .restoredSessionStartTakeover || scenario == .restoredUserPromptTakeover
                || scenario == .childFirstAfterRestore || scenario == .restoredEndedSessionResume
            {
                #expect(context.bindings.contains { $0.providerConversationId == "S1" && $0.status == .ended })
                #expect(context.currentBinding?.status == .active)
            }
            let summary = try await ingestion.sessionSummary(paneId: pane)
            return summary
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let restored = try await ingestion.sessionSummary(paneId: pane)
            switch scenario {
            case .restoredSessionStartTakeover, .restoredUserPromptTakeover, .restoredEndedSessionResume:
                #expect(restored?.sessionRef.value == "S2")
                #expect(restored?.status != .idle(.ended))
            case .childFirstAfterRestore:
                #expect(restored?.sessionRef.value == "S3")
                #expect(restored?.status != .idle(.ended))
            case .restoredParentConfirmsThenChildIgnored:
                #expect(restored?.sessionRef.value == "S1")
                #expect(restored?.status == .working(.active))
            case .restoredCommandExit:
                #expect(restored?.sessionRef.value == "S1")
                #expect(restored?.status == .idle(.ended))
            case .liveChildIgnored:
                Issue.record("Handled before scenario matrix")
            }
            #expect(restored == expected)
        }
    }
}

enum RestoredMainScenario: CaseIterable, Equatable, Sendable {
    case restoredSessionStartTakeover
    case restoredUserPromptTakeover
    case restoredParentConfirmsThenChildIgnored
    case liveChildIgnored
    case childFirstAfterRestore
    case restoredEndedSessionResume
    case restoredCommandExit
}

private func seedPersistedMain(
    scenario: RestoredMainScenario, fixture: SessionsFileDatabaseFixture, paneId: UUID
) async throws {
    try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
        if scenario == .restoredEndedSessionResume {
            _ = try await submitScenarioHook(.sessionStart, session: "S2", paneId: paneId, ingestion: ingestion)
            _ = try await submitScenarioHook(.sessionEnd, session: "S2", paneId: paneId, ingestion: ingestion)
        }
        _ = try await submitScenarioHook(.toolActivity, session: "S1", paneId: paneId, ingestion: ingestion)
    }
}

private func expectLiveMain(_ ingestion: SessionsIngestion, paneId: UUID, session: String) async throws {
    let summary = try #require(try await ingestion.sessionSummary(paneId: paneId))
    #expect(summary.sessionRef.value == session)
}

private func submitScenarioHook(
    _ signalName: SessionProviderSignalName, session: String, paneId: UUID, ingestion: SessionsIngestion
) async throws -> SessionsHookOutcome {
    let signal: SessionProviderSignal =
        switch signalName {
        case .sessionStart: .sessionStart
        case .sessionEnd: .sessionEnd
        case .turnStart: .turnStart
        case .toolActivity: .toolActivity(toolName: nil)
        default: throw SessionsRepositoryError.invalidStoredValue("restored main test signal")
        }
    return try await ingestion.submitHook(
        makeHookAdmission(
            paneId: paneId, sessionId: session, eventName: signalName, signal: signal,
            turnId: signalName == .sessionStart || signalName == .sessionEnd ? nil : "turn"))
}
