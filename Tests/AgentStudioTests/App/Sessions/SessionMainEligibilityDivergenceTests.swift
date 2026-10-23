import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionMainEligibilityTests {
    @Test("a database election that the confirmed in-memory main did not predict stays ineligible")
    func unpredictedDatabaseElection() async throws {
        let fixture = try MainEligibilityDatabaseFixture()
        let pane = UUIDv7.generate()
        let reader = MainEligibilityTableLeaderReader(leader: TestMainAgentChain.shell, sessionID: .generateUUIDv7())
        let ingestion = fixture.makeIngestion(reader: reader)
        do {
            let initial = try await ingestion.submitHook(
                mainEligibilityHook(
                    pane: pane, session: "A", signal: .toolActivity(toolName: "Read"),
                    chain: TestMainAgentChain.observation))
            guard case .committed(let first) = initial else {
                Issue.record("Expected the initial main to bind")
                await ingestion.finish()
                return
            }
            let ended = try await fixture.repository.endLiveBinding(expectedBinding: first.binding, endedAt: Date())
            #expect(ended?.binding.status == .ended)
            let readsBefore = reader.readCount
            let candidate = mainEligibilityHook(
                pane: pane, session: "B", signal: .toolActivity(toolName: "Read"), chain: TestMainAgentChain.observation
            )
            #expect(try await ingestion.submitHook(candidate) == .ignored)
            #expect(reader.readCount == readsBefore)
            let context = try await fixture.repository.statusContext(paneId: pane)
            #expect(context.bindings.count == 1)
            #expect(context.currentBinding?.providerConversationId == "A")
            #expect(context.currentBinding?.status == .ended)
            #expect(context.evidence.count == 1)
            #expect(!context.evidence.contains { $0.recordId == candidate.recordId })
            let restored = fixture.makeIngestion(reader: reader)
            do {
                let query = try await AgentStudioIPCSessionsAdapter(ingestion: restored).readSessionState(
                    paneId: pane, params: .init(handle: pane.uuidString))
                #expect(query.sourceHealth == .ended)
                #expect(query.session?.conversationId == "A")
                let sidebar = SessionStatusAtom()
                sidebar.apply(await restored.statusPublicationMailbox.takeBatch())
                #expect(sidebar.value(for: .init(existingUUID: pane))?.status == .idle(.ended))
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
