import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionMainEligibilityTests {
    @Test(
        "claim election is gated while its current main's own reports remain applicable",
        arguments: MainClaimScenario.allCases, [true, false])
    func claimBindingTable(scenario: MainClaimScenario, eligible: Bool) async throws {
        let fixture = try MainEligibilityDatabaseFixture()
        let pane = UUIDv7.generate()
        let reader = MainEligibilityTableLeaderReader(leader: TestMainAgentChain.shell, sessionID: .generateUUIDv7())
        let ingestion = fixture.makeIngestion(reader: reader)
        do {
            if scenario != .firstReport {
                _ = try await submitMainEligibilityClaim(
                    ingestion,
                    mainEligibilityHook(
                        pane: pane, session: "A", provider: scenario.provider,
                        signal: scenario == .cursorTakeover ? .turnStart : .toolActivity(toolName: "Read"),
                        chain: TestMainAgentChain.observation))
                if scenario == .reopenEnded || scenario == .releasedLate {
                    _ = try await submitMainEligibilityClaim(
                        ingestion,
                        mainEligibilityHook(
                            pane: pane, session: "A", provider: scenario.provider, signal: .sessionEnd,
                            chain: .unknown(.peerUnbound)))
                }
            }
            let hook = scenario.incoming(pane: pane, eligible: eligible)
            _ = try await submitMainEligibilityClaim(ingestion, hook)
            let stored = try await fixture.repository.statusContext(paneId: pane)
            #expect(stored.bindings.isEmpty)
            #expect(stored.evidence.isEmpty)
            #expect(
                await ingestion.unverifiedStatusRuntime.panes[pane]?.main?.sessionId
                    == scenario.expectedMain(eligible: eligible))
            let query = try await AgentStudioIPCSessionsAdapter(ingestion: ingestion).readSessionState(
                paneId: pane, params: .init(handle: pane.uuidString))
            #expect(query.sourceHealth == .unbound)
            #expect(query.session == nil)
            let batch = await ingestion.statusPublicationMailbox.takeBatch()
            let sidebar = SessionStatusAtom()
            sidebar.apply(batch)
            #expect(
                sidebar.value(for: .init(existingUUID: pane))?.status == scenario.expectedStatus(eligible: eligible))
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }
}

enum MainClaimScenario: CaseIterable, Sendable {
    case firstReport, cursorTakeover, ownEnd, reopenEnded, releasedLate, otherMain
    var provider: String { self == .cursorTakeover ? "cursor" : "claude-code" }

    func incoming(pane: UUID, eligible: Bool) -> SessionsHookAdmission {
        let signal: SessionProviderSignal
        let session: String
        switch self {
        case .firstReport, .otherMain:
            session = "B"
            signal = .toolActivity(toolName: "Read")
        case .cursorTakeover:
            session = "B"
            signal = .turnStart
        case .ownEnd:
            session = "A"
            signal = .sessionEnd
        case .reopenEnded:
            session = "A"
            signal = .sessionStart
        case .releasedLate:
            session = "A"
            signal = .toolActivity(toolName: "Read")
        }
        return mainEligibilityHook(
            pane: pane, session: session, provider: provider, signal: signal,
            chain: eligible ? TestMainAgentChain.observation : .unknown(.peerUnbound))
    }

    func expectedMain(eligible: Bool) -> String? {
        switch self {
        case .firstReport: eligible ? "B" : nil
        case .cursorTakeover: eligible ? "B" : "A"
        case .ownEnd, .releasedLate: nil
        case .reopenEnded: eligible ? "A" : nil
        case .otherMain: "A"
        }
    }

    func expectedStatus(eligible: Bool) -> AgentSessionStatus {
        switch self {
        case .firstReport: eligible ? .working(.active) : .unknown
        case .cursorTakeover, .otherMain: .working(.active)
        case .ownEnd, .releasedLate: .idle(.ended)
        case .reopenEnded: eligible ? .unknown : .idle(.ended)
        }
    }
}

func submitMainEligibilityClaim(_ ingestion: SessionsIngestion, _ hook: SessionsHookAdmission) async throws
    -> SessionsUnverifiedStatusOutcome
{
    try await ingestion.recordUnverifiedStatus(
        paneId: hook.paneId, hook: hook,
        refusal: .init(
            reason: .credentialNotRecognized, event: hook.eventName.rawValue, at: hook.admittedAt, intent: .status),
        remainsPresent: { true })
}
