import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Cold end and B1 FIFO decision")
struct SessionsColdRestoreTests {
    @Test(arguments: [false, true])
    func coldEndReturnsConfirmedOrUnconfirmedMain(confirmed: Bool) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        let hook = makeHookAdmission(paneId: pane, sessionId: session)
        if !confirmed { _ = try await repository.applyHook(hook, eligibility: .eligible) }
        try await withSessionsIngestion(repository: repository) { ingestion in
            if confirmed { _ = try await ingestion.submitHook(hook) }
            let before = try #require(try await repository.statusContext(paneId: pane).currentBinding)
            let ended = try #require(try await ingestion.endLiveMainForColdRestore(paneId: pane))
            #expect(
                ended
                    == .init(
                        bindingGenerationId: before.bindingGenerationId,
                        providerIdentifier: "codex", providerConversationId: session))
            #expect(try await repository.statusContext(paneId: pane).currentBinding?.status == .ended)
            #expect(try await ingestion.commitColdResume(paneId: pane, bindingGenerationId: ended.bindingGenerationId))
            _ = try await ingestion.submitHook(makeHookAdmission(paneId: pane, sessionId: session))
            let reopened = try #require(try await repository.statusContext(paneId: pane).currentBinding)
            #expect(reopened.status == .active)
            #expect(reopened.bindingGenerationId == before.bindingGenerationId)
            #expect(try await repository.statusContext(paneId: pane).bindings.count == 1)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func coldRestorePreservesMainEligibility(eligible: Bool, sameSession: Bool) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        let incomingSession = sameSession ? session : UUIDv7.generate().uuidString
        try await withSessionsIngestion(repository: repository) { ingestion in
            _ = try await ingestion.submitHook(makeHookAdmission(paneId: pane, sessionId: session))
            let ended = try #require(try await ingestion.endLiveMainForColdRestore(paneId: pane))
            let incoming = SessionsHookAdmission(
                paneId: pane, providerIdentifier: "codex", providerVersion: "9.9.9", sessionId: incomingSession,
                eventName: .sessionStart, turnId: nil, signal: .sessionStart, recordId: UUIDv7.generate(),
                admittedAt: Date(timeIntervalSince1970: 1_800_000_001),
                chain: eligible ? TestMainAgentChain.observation : .unknown(.peerUnbound))
            let outcome = try await ingestion.submitHook(incoming)
            let expectedDisposition: SessionsHookDisposition? = eligible ? .bound : sameSession ? .recordedOnly : nil
            #expect(committedHookCommit(from: outcome)?.disposition == expectedDisposition)
            let stored = try await repository.statusContext(paneId: pane)
            #expect(stored.currentBinding?.status == (eligible ? .active : .ended))
            #expect(stored.currentBinding?.providerConversationId == (eligible ? incomingSession : session))
            #expect(stored.bindings.count == (eligible && !sameSession ? 2 : 1))
            #expect(
                try await ingestion.commitColdResume(paneId: pane, bindingGenerationId: ended.bindingGenerationId)
                    == (!eligible && !sameSession))
        }
    }

    @Test("a crash after cold end has no main to return on the next launch")
    func crashAfterColdEndMissesResume() async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        _ = try await repository.applyHook(makeHookAdmission(paneId: pane, sessionId: session), eligibility: .eligible)
        try await withSessionsIngestion(repository: repository) { ingestion in
            let ended = try await ingestion.endLiveMainForColdRestore(paneId: pane)
            #expect(ended != nil)
        }
        try await withSessionsIngestion(repository: repository) { ingestion in
            let ended = try await ingestion.endLiveMainForColdRestore(paneId: pane)
            #expect(ended == nil)
        }
    }

    @Test(arguments: ColdResumeAdmissionCase.allCases)
    func fifoDecisionHonorsLiveEvidenceIncludingRecordedOnly(admission: ColdResumeAdmissionCase) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        try await withSessionsIngestion(repository: repository) { ingestion in
            _ = try await ingestion.submitHook(makeHookAdmission(paneId: pane, sessionId: session))
            let ended = try #require(try await ingestion.endLiveMainForColdRestore(paneId: pane))
            switch admission {
            case .noNewAdmission: break
            case .end:
                let result = try await ingestion.submitHook(
                    makeHookAdmission(paneId: pane, sessionId: session, eventName: .sessionEnd, signal: .sessionEnd))
                #expect(committedHookCommit(from: result)?.disposition == .recordedOnly)
            case .activity:
                let result = try await ingestion.submitHook(
                    makeHookAdmission(
                        paneId: pane, sessionId: session, eventName: .toolActivity,
                        signal: .toolActivity(toolName: "Read")))
                #expect(committedHookCommit(from: result)?.disposition == .recordedOnly)
            case .reopen:
                _ = try await ingestion.submitHook(makeHookAdmission(paneId: pane, sessionId: session))
            case .newBinding:
                _ = try await ingestion.submitHook(
                    makeHookAdmission(paneId: pane, sessionId: UUIDv7.generate().uuidString))
            }
            #expect(
                try await ingestion.commitColdResume(
                    paneId: pane, bindingGenerationId: ended.bindingGenerationId) == (admission == .noNewAdmission))
            #expect(!(try await ingestion.commitColdResume(paneId: pane, bindingGenerationId: UUIDv7.generate())))
        }
    }
}

enum ColdResumeAdmissionCase: CaseIterable, Sendable { case noNewAdmission, end, activity, reopen, newBinding }
