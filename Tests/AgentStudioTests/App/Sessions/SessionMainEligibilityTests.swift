import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

@MainActor
@Suite("Main agent eligibility in Sessions", .serialized)
struct SessionMainEligibilityTests {
    @Test(
        "the seven binding branches preserve reports while gating elections",
        arguments: MainElectionTableScenario.allCases, [true, false])
    func bindingTable(scenario: MainElectionTableScenario, eligible: Bool) async throws {
        let fixture = try MainEligibilityDatabaseFixture()
        let reader = MainEligibilityTableLeaderReader(leader: TestMainAgentChain.shell, sessionID: .generateUUIDv7())
        let pane = UUIDv7.generate()
        let ingestion = fixture.makeIngestion(reader: reader)
        do {
            let initialCount = try await scenario.seed(ingestion: ingestion, repository: fixture.repository, pane: pane)
            let readsBefore = reader.readCount
            let hook = scenario.incoming(pane: pane, eligible: eligible)
            let result = try await ingestion.submitHook(hook)
            let expected = scenario.expected(eligible: eligible)
            switch (result, expected.disposition) {
            case (.ignored, nil): break
            case (.committed(let commit), .some(let disposition)):
                #expect(commit.disposition == disposition)
            default: Issue.record("Binding disposition differs from the brief's table: \(result)")
            }
            let stored = try await fixture.repository.statusContext(paneId: pane)
            #expect(stored.currentBinding?.providerConversationId == expected.session)
            #expect(stored.currentBinding?.status == expected.bindingStatus)
            #expect(stored.evidence.count == initialCount + expected.additionalEvidence)
            let incomingEvidence = stored.evidence.first { $0.recordId == hook.recordId }
            #expect(incomingEvidence?.statusEffect == expected.effect)
            #expect(reader.readCount - readsBefore == (eligible && scenario.elects ? 1 : 0))
            let restored = fixture.makeIngestion(reader: reader)
            do {
                let query = try await AgentStudioIPCSessionsAdapter(
                    ingestion: restored, processChainReader: EligibleTestProcessChainReader()
                ).readSessionState(
                    paneId: pane, params: .init(handle: pane.uuidString))
                #expect(query.sourceHealth == expected.sourceHealth)
                #expect(query.session?.conversationId == expected.session)
                #expect(query.session?.status == expected.wireStatus)
                let publications = await restored.statusPublicationMailbox.takeBatch()
                let paneKey = PaneId(existingUUID: pane)
                #expect(publications[paneKey] == .set(.init(status: expected.status)))
                let sidebar = SessionStatusAtom()
                sidebar.apply(publications)
                #expect(sidebar.value(for: paneKey)?.status == expected.status)
                await restored.finish()
            } catch {
                await restored.finish()
                throw error
            }
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }
}
