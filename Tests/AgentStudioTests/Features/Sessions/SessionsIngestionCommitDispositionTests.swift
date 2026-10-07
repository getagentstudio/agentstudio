import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions commit disposition")
struct SessionsIngestionCommitDispositionTests {
    @Test(
        "a first Stop, permission or tool fact binds and applies, live and after reload",
        arguments: FirstBindingFact.allCases)
    private func firstBindingFactKeepsItsStatusEffect(fact: FirstBindingFact) async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let expected = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let before = try await ingestion.readSessionStatus(paneId: pane)
            #expect(before == .unbound)
            let outcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, eventName: fact.signal.name, signal: fact.signal))
            let committed = try #require(committedHookCommit(from: outcome))
            #expect(committed.disposition == .bound)
            #expect(committed.binding.status == .active)
            #expect(committed.evidence.statusEffect == .applied)
            #expect(committed.evidence.providerSignal == fact.signal)
            let summaryRead = try await ingestion.sessionSummary(paneId: pane)
            let summary = try #require(summaryRead)
            #expect(summary.status == fact.expectedStatus)
            let liveRead = try await ingestion.readSessionStatus(paneId: pane)
            guard case .live(let live) = liveRead else {
                Issue.record("The first fact must leave a live main binding")
                return summary
            }
            #expect(live == summary)
            return summary
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restarted in
            let restoredRead = try await restarted.readSessionStatus(paneId: pane)
            guard case .live(let restored) = restoredRead else {
                Issue.record("The first fact's main binding must stay live after reload")
                return
            }
            #expect(restored == expected)
            #expect(restored.status == fact.expectedStatus)
        }
    }

    @Test("status effect is decided at admission and persisted for reload")
    func recordOnlyIsNotALiveFact() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let boundOutcome = try await ingestion.submitHook(makeHookAdmission(paneId: pane))
            let bound = try #require(committedHookCommit(from: boundOutcome))
            #expect(bound.disposition == .bound)
            let endOutcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .sessionEnd, signal: .sessionEnd))
            _ = try #require(committedHookCommit(from: endOutcome))
            let recordedOutcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read")))
            let recorded = try #require(committedHookCommit(from: recordedOutcome))
            #expect(recorded.disposition == .recordedOnly)
            #expect(recorded.evidence.statusEffect == .recordedOnly)
            #expect(recorded.evidence.recordId != bound.evidence.recordId)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .idle(.ended))
        }
    }

    @Test("commandFinished is a no-op without a live main and a late SessionEnd records only")
    func commandFinishedEndsOnlyTheLiveMain() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        let startInstant = ContinuousClock.now
        let exitInstant = startInstant + .milliseconds(1)
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let noLiveMain = try await ingestion.submitCommandFinished(paneId: pane, reportedAt: startInstant)
            #expect(noLiveMain == nil)

            let startOutcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, sessionId: "main", admissionInstant: startInstant))
            let start = try #require(committedHookCommit(from: startOutcome))
            let equalTimestampExit = try await ingestion.submitCommandFinished(
                paneId: pane, reportedAt: startInstant)
            #expect(equalTimestampExit == nil)
            let stillLive = try await ingestion.repository.statusContext(paneId: pane)
            #expect(stillLive.currentBinding?.bindingGenerationId == start.binding.bindingGenerationId)
            #expect(stillLive.currentBinding?.status == .active)

            let endOutcome = try await ingestion.submitCommandFinished(paneId: pane, reportedAt: exitInstant)
            let ended = try #require(endOutcome)
            #expect(ended.binding.bindingGenerationId == start.binding.bindingGenerationId)
            #expect(ended.binding.status == .ended)

            let lateEndOutcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, sessionId: "main", eventName: .sessionEnd, signal: .sessionEnd))
            let lateEnd = try #require(committedHookCommit(from: lateEndOutcome))
            #expect(lateEnd.disposition == .recordedOnly)
            #expect(lateEnd.evidence.statusEffect == .recordedOnly)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .idle(.ended))
        }
    }

    @Test("commandFinished ends a restored live main without a process-local bind instant")
    func commandFinishedEndsRestoredBinding() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let bindingId = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let outcome = try await ingestion.submitHook(makeHookAdmission(paneId: pane, sessionId: "restored"))
            let commit = try #require(committedHookCommit(from: outcome))
            return commit.binding.bindingGenerationId
        }
        let (ended, summary) = try await withSessionsIngestion(repository: fixture.makeRepository()) { restarted in
            let endOutcome = try await restarted.submitCommandFinished(
                paneId: pane, reportedAt: ContinuousClock.now)
            let end = try #require(endOutcome)
            let summary = try await restarted.sessionSummary(paneId: pane)
            return (end, summary)
        }
        #expect(ended.binding.bindingGenerationId == bindingId)
        #expect(ended.binding.status == .ended)
        #expect(summary?.status == .idle(.ended))
    }
}

private enum FirstBindingFact: CaseIterable, Sendable {
    case stop, permission, tool

    var signal: SessionProviderSignal {
        switch self {
        case .stop: .turnDone
        case .permission: .permission(toolName: "Bash", questions: nil)
        case .tool: .toolActivity(toolName: "Read")
        }
    }

    var expectedStatus: AgentSessionStatus {
        switch self {
        case .stop: .idle(.done)
        case .permission: .needsYou(.approval)
        case .tool: .working(.active)
        }
    }
}
