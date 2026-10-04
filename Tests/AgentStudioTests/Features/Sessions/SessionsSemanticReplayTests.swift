import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions semantic replay")
struct SessionsSemanticReplayTests {
    @Test("live evidence and source end replay ignore later server receipt time")
    func liveMutationReplayUsesStableIntent() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let source = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId, providerConversationId: "semantic-replay", sourceGenerationId: source,
                        reportedAt: 1)))
            let occurrenceId = UUIDv7.generate()
            let correlationId = UUIDv7.generate()
            let first = try await ingestion.submit(
                correlationId: correlationId,
                mutation: .recordEvidence(
                    makeSessionsEvidenceMutation(
                        paneId: paneId, sourceGenerationId: source, kind: .completed, occurrenceId: occurrenceId, at: 2)
                ))
            let replay = try await ingestion.submit(
                correlationId: correlationId,
                mutation: .recordEvidence(
                    makeSessionsEvidenceMutation(
                        paneId: paneId, sourceGenerationId: source, kind: .completed, occurrenceId: occurrenceId, at: 20
                    )))
            #expect(replay == first)
            #expect(first == .evidenceRecorded(occurrenceId: occurrenceId))
            let endCorrelationId = UUIDv7.generate()
            let ended = try await ingestion.submit(
                correlationId: endCorrelationId,
                mutation: .sourceEnded(
                    SessionsSourceEndMutation(
                        paneId: paneId, sourceGenerationId: source, endedAt: Date(timeIntervalSince1970: 3))))
            let endedReplay = try await ingestion.submit(
                correlationId: endCorrelationId,
                mutation: .sourceEnded(
                    SessionsSourceEndMutation(
                        paneId: paneId, sourceGenerationId: source, endedAt: Date(timeIntervalSince1970: 30))))
            #expect(endedReplay == ended)
            #expect(ended == .sourceEnded(sourceGenerationId: source))
            let context = try await fixture.makeRepository().statusContext(paneId: paneId)
            #expect(context.evidence.map(\.occurrenceId) == [occurrenceId])
            #expect(context.results.count == 1)
            #expect(context.currentBinding?.status == .ended)
        }
    }
}
