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
            SessionsEvidenceReducer.evidenceOrder([second, legacy, first]).map(\.occurrenceId)
                == [legacy.occurrenceId, first.occurrenceId, second.occurrenceId])
        first.admissionSequence = nil
        second.admissionSequence = nil
        #expect(SessionsEvidenceReducer.admissionOrder(second, first))
        let ordered = SessionsEvidenceReducer.evidenceOrder([legacy, first, second])
        #expect(ordered.map(\.occurrenceId) == [second.occurrenceId, first.occurrenceId, legacy.occurrenceId])
    }

    @Test("source ordering keeps unstamped admission slots and breaks source ties by admission")
    func sourceOrderKeepsUnstampedAdmissionAndTies() {
        let conversation = UUIDv7.generate()
        let binding = UUIDv7.generate()
        let source = UUIDv7.generate()
        func record(_ sequence: Int64, sourceTime: TimeInterval?) -> SessionsEvidenceRecord {
            var evidence = makeSessionsEvidence(
                conversationId: conversation, bindingGenerationId: binding, sourceGenerationId: source,
                kind: .activityStarted, origin: .reported, timestamp: Double(100 - sequence))
            evidence.admissionSequence = sequence
            evidence.sourceOccurredAt = sourceTime.map(Date.init(timeIntervalSince1970:))
            return evidence
        }
        let newer = record(1, sourceTime: 10)
        let unstamped = record(2, sourceTime: nil)
        let earlier = record(3, sourceTime: 5)
        let tie = record(4, sourceTime: 10)
        let secondUnstamped = record(5, sourceTime: nil)
        let input = [secondUnstamped, tie, earlier, unstamped, newer]
        let ordered = SessionsEvidenceReducer.evidenceOrder(input)
        #expect(
            ordered.map(\.occurrenceId)
                == [earlier, unstamped, newer, tie, secondUnstamped].map(\.occurrenceId))
        #expect(SessionsEvidenceReducer.evidenceOrder(ordered) == ordered)
    }
}
