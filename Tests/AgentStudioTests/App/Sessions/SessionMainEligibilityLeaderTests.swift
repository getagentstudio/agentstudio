import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionMainEligibilityTests {
    @Test("a known chain still needs the exact live terminal leader", arguments: MainLeaderFailure.allCases)
    func leaderMustMatch(failure: MainLeaderFailure) async throws {
        let fixture = try MainEligibilityDatabaseFixture()
        let pane = UUIDv7.generate()
        let reader = MainEligibilityTableLeaderReader(
            leader: failure.leader, sessionID: failure == .missingAssociation ? nil : .generateUUIDv7())
        let ingestion = fixture.makeIngestion(reader: reader)
        do {
            let outcome = try await ingestion.submitHook(
                mainEligibilityHook(
                    pane: pane, session: "candidate", signal: .toolActivity(toolName: "Read"),
                    chain: TestMainAgentChain.observation))
            #expect(outcome == .ignored)
            let stored = try await fixture.repository.statusContext(paneId: pane)
            #expect(stored.bindings.isEmpty)
            #expect(stored.evidence.isEmpty)
            let query = try await AgentStudioIPCSessionsAdapter(ingestion: ingestion).readSessionState(
                paneId: pane, params: .init(handle: pane.uuidString))
            #expect(query.sourceHealth == .unbound)
            #expect(query.session == nil)
            let publications = await ingestion.statusPublicationMailbox.takeBatch()
            let sidebar = SessionStatusAtom()
            sidebar.apply(publications)
            #expect(sidebar.value(for: .init(existingUUID: pane))?.status == .unknown)
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }
}

enum MainLeaderFailure: CaseIterable, Sendable {
    case differentPID, differentStart, unavailable, missingAssociation
    var leader: ZmxProcessIncarnation? {
        switch self {
        case .differentPID: .init(pid: 59, startSeconds: 1, startMicroseconds: 0)
        case .differentStart: .init(pid: 58, startSeconds: 1, startMicroseconds: 1)
        case .unavailable: nil
        case .missingAssociation: TestMainAgentChain.shell
        }
    }
}
