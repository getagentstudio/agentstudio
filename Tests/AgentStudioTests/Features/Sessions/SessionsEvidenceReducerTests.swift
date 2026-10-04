import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions evidence reducer")
struct SessionsEvidenceReducerTests {
    @Test("turn context uses reported root evidence from the exact binding")
    func currentTurnUsesQualifiedRootEvidence() {
        let conversation = UUIDv7.generate()
        let binding = UUIDv7.generate()
        let source = UUIDv7.generate()
        func evidence(
            _ turn: String, subject: SessionsEvidenceSubject = .root,
            origin: SessionsEvidenceOrigin = .reported, freshness: SessionsEvidenceFreshness = .live,
            kind: SessionsEvidenceKind = .activityStarted, timestamp: TimeInterval = 1
        ) -> SessionsEvidenceRecord {
            makeSessionsEvidence(
                conversationId: conversation, bindingGenerationId: binding,
                sourceGenerationId: source, turnId: turn, subject: subject, kind: kind,
                origin: origin, freshness: freshness, timestamp: timestamp)
        }
        let root = evidence("reported")
        let records = [
            root,
            evidence("agent", origin: .agentReported, timestamp: 2),
            evidence("child", subject: .subagent("child"), timestamp: 3),
            evidence("historical", freshness: .historical, timestamp: 4),
            evidence("prompt", kind: .needsYouOpened(requestId: "request", explanation: nil), timestamp: 5),
        ]
        #expect(
            SessionsEvidenceReducer.currentTurnId(
                evidence: records,
                bindingGenerationId: binding, activeSourceGenerationIds: [source]) == "reported")
        #expect(
            SessionsEvidenceReducer.currentTurnId(
                evidence: records,
                bindingGenerationId: UUIDv7.generate(), activeSourceGenerationIds: [source]) == nil)
        #expect(
            SessionsEvidenceReducer.currentTurnId(
                evidence: records,
                bindingGenerationId: binding, activeSourceGenerationIds: []) == nil)
        #expect(
            SessionsEvidenceReducer.currentTurnId(
                evidence: [evidence("estimated", origin: .estimated), records[1]],
                bindingGenerationId: binding, activeSourceGenerationIds: [source]) == "agent")
    }

    @Test("admission order governs live evidence while legacy records retain timestamp and UUID ordering")
    func evidenceOrderingUsesAdmissionSequence() {
        let conversation = UUIDv7.generate()
        let binding = UUIDv7.generate()
        let source = UUIDv7.generate()
        var first = makeSessionsEvidence(
            conversationId: conversation, bindingGenerationId: binding,
            sourceGenerationId: source, kind: .activityStarted, origin: .reported, timestamp: 20)
        var second = makeSessionsEvidence(
            conversationId: conversation, bindingGenerationId: binding,
            sourceGenerationId: source, kind: .completed, origin: .reported, timestamp: 1)
        let legacy = makeSessionsEvidence(
            conversationId: conversation, bindingGenerationId: binding,
            sourceGenerationId: source, kind: .aborted, origin: .reported, timestamp: 100)
        first.admissionSequence = 1
        second.admissionSequence = 2
        #expect(
            [second, legacy, first].sorted(by: SessionsEvidenceReducer.evidenceOrder).map(\.occurrenceId)
                == [legacy.occurrenceId, first.occurrenceId, second.occurrenceId])
        first.admissionSequence = nil
        second.admissionSequence = nil
        #expect(SessionsEvidenceReducer.evidenceOrder(second, first))
        let ordered = [legacy, first, second].sorted(by: SessionsEvidenceReducer.evidenceOrder)
        #expect(ordered.map(\.occurrenceId) == [second.occurrenceId, first.occurrenceId, legacy.occurrenceId])
    }
}
