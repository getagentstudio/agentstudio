import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionsProviderTraceIntegrationTests {
    @Test(
        "the pane main-session table applies through the real adapter live and after reload",
        arguments: MainSessionAdapterScenario.allCases)
    func mainSessionTableIsPaneLocal(scenario: MainSessionAdapterScenario) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pane = UUIDv7.generate()
        let secondPane = UUIDv7.generate()
        let submitted = Mutex<[PaneActivityOccurrence]>([])
        let admissionTime = Mutex(ContinuousClock.now)
        let clock = PaneActivityClock(
            submissionObserver: { fact in submitted.withLock { $0.append(fact) } }, sink: { _ in })
        do {
            let expected = try await fixture.withIngestion(
                activityClock: clock,
                continuousNow: {
                    admissionTime.withLock { instant in
                        let admitted = instant
                        instant = instant.advanced(by: .seconds(1))
                        return admitted
                    }
                },
                operation: { ingestion, adapter in
                    try await submitMainSessionHook(adapter, pane: pane, session: "main", event: .toolActivity)
                    let initial = try await ingestion.sessionSummary(paneId: pane)
                    let repository = await ingestion.repository
                    switch scenario {
                    case .childIgnored:
                        let before = try await repository.statusContext(paneId: pane)
                        let counts = try await mainSessionRowCounts(fixture)
                        let activityCount = submitted.withLock { $0.count }
                        for event in [IPCSessionEventName.sessionStart, .toolActivity, .permission, .sessionEnd] {
                            try await submitMainSessionHook(adapter, pane: pane, session: "child", event: event)
                        }
                        let after = try await repository.statusContext(paneId: pane)
                        let afterCounts = try await mainSessionRowCounts(fixture)
                        let afterSummary = try await ingestion.sessionSummary(paneId: pane)
                        #expect(after == before)
                        #expect(afterCounts == counts)
                        #expect(afterSummary == initial)
                        #expect(submitted.withLock { $0.count } == activityCount)
                    case .nextMainAfterEnd:
                        try await submitMainSessionHook(adapter, pane: pane, session: "main", event: .sessionEnd)
                        try await submitMainSessionHook(adapter, pane: pane, session: "next", event: .permission)
                        let successor = try await ingestion.sessionSummary(paneId: pane)
                        #expect(successor?.sessionRef.value == "next")
                        #expect(successor?.status == .needsYou(.approval))
                    case .earlyStartHeals:
                        let counts = try await mainSessionRowCounts(fixture)
                        try await submitMainSessionHook(adapter, pane: pane, session: "next", event: .sessionStart)
                        let afterIgnoredStart = try await ingestion.sessionSummary(paneId: pane)
                        let afterIgnoredCounts = try await mainSessionRowCounts(fixture)
                        #expect(afterIgnoredStart == initial)
                        #expect(afterIgnoredCounts == counts)
                        try await submitMainSessionHook(adapter, pane: pane, session: "main", event: .sessionEnd)
                        try await submitMainSessionHook(adapter, pane: pane, session: "next", event: .toolActivity)
                        let healed = try await ingestion.sessionSummary(paneId: pane)
                        #expect(healed?.sessionRef.value == "next")
                        #expect(healed?.status == .working(.active))
                    case .sameConversationIndependent:
                        let before = try await repository.statusContext(paneId: pane)
                        let paneActivity = submitted.withLock { $0.filter { $0.paneId == pane } }
                        try await submitMainSessionHook(
                            adapter, pane: secondPane, session: "main", event: .sessionStart)
                        try await submitMainSessionHook(adapter, pane: secondPane, session: "main", event: .permission)
                        let after = try await repository.statusContext(paneId: pane)
                        #expect(after.bindings == before.bindings)
                        #expect(after.sources == before.sources)
                        #expect(after.evidence == before.evidence)
                        #expect(submitted.withLock { $0.filter { $0.paneId == pane } } == paneActivity)
                        let firstPaneSummary = try await ingestion.sessionSummary(paneId: pane)
                        let secondPaneSummary = try await ingestion.sessionSummary(paneId: secondPane)
                        #expect(firstPaneSummary == initial)
                        #expect(secondPaneSummary?.status == .needsYou(.approval))
                    case .knownEndedDoesNotAffectNewMain:
                        try await assertEndedFactsLeaveLiveMain(
                            fixture: fixture, ingestion: ingestion, adapter: adapter, pane: pane,
                            activityCount: { submitted.withLock { $0.count } })
                    case .commandExit:
                        try await assertCommandExitKeepsSuccessor(
                            fixture: fixture, ingestion: ingestion, adapter: adapter, pane: pane,
                            exitAt: admissionTime.withLock { $0 }, activityCount: { submitted.withLock { $0.count } })
                    }
                    return (
                        first: try await ingestion.sessionSummary(paneId: pane),
                        second: try await ingestion.sessionSummary(paneId: secondPane)
                    )
                })
            try await fixture.withIngestion { ingestion, _ in
                let first = try await ingestion.sessionSummary(paneId: pane)
                let second = try await ingestion.sessionSummary(paneId: secondPane)
                #expect(first == expected.first)
                #expect(second == expected.second)
            }
            await clock.shutdown()
        } catch {
            await clock.shutdown()
            throw error
        }
    }
    @Test("an ended main's SessionStart resumes its binding after the newer main ends, live and after reload")
    func endedMainResumesOnItsOwnPane() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pane = UUIDv7.generate()
        let expected = try await fixture.withIngestion { ingestion, adapter in
            try await submitMainSessionHook(adapter, pane: pane, session: "A", event: .toolActivity)
            let initialRead = try await ingestion.sessionSummary(paneId: pane)
            let initial = try #require(initialRead)
            try await submitMainSessionHook(adapter, pane: pane, session: "A", event: .sessionEnd)
            try await submitMainSessionHook(adapter, pane: pane, session: "B", event: .toolActivity)
            try await submitMainSessionHook(adapter, pane: pane, session: "B", event: .sessionEnd)
            try await submitMainSessionHook(adapter, pane: pane, session: "A", event: .sessionStart)
            let resumedRead = try await ingestion.sessionSummary(paneId: pane)
            let resumed = try #require(resumedRead)
            #expect(resumed.bindingGeneration == initial.bindingGeneration)
            #expect(resumed.sessionRef.value == "A")
            #expect(resumed.status == .unknown)
            guard case .live = try await ingestion.readSessionStatus(paneId: pane) else {
                Issue.record("SessionStart must reopen A as this pane's live main")
                return resumed
            }
            return resumed
        }
        try await fixture.withIngestion { ingestion, _ in
            let restored = try await ingestion.sessionSummary(paneId: pane)
            #expect(restored == expected)
            guard case .live = try await ingestion.readSessionStatus(paneId: pane) else {
                Issue.record("The resumed pane binding must remain live after reload")
                return
            }
        }
    }

    @Test("a held old exit cannot close the newer main, and an old SessionEnd is recorded-only")
    func delayedExitFenceUsesControlledInstants() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pane = UUIDv7.generate()
        let origin = ContinuousClock.now
        let time = Mutex(origin)
        let held = HeldStep<Void>("old agent exit delivery")
        let result = try await fixture.withIngestion(
            continuousNow: { time.withLock { $0 } },
            operation: { ingestion, adapter in
                try await submitMainSessionHook(adapter, pane: pane, session: "A", event: .toolActivity)
                let oldExitAt = origin.advanced(by: .milliseconds(100))
                let exit = Task {
                    try await held.arrive(())
                    return try await ingestion.submitCommandFinished(paneId: pane, reportedAt: oldExitAt)
                }
                do {
                    try await held.firstArrival()
                    time.withLock { $0 = origin.advanced(by: .milliseconds(200)) }
                    try await submitMainSessionHook(adapter, pane: pane, session: "A", event: .sessionEnd)
                    time.withLock { $0 = origin.advanced(by: .milliseconds(300)) }
                    try await submitMainSessionHook(adapter, pane: pane, session: "B", event: .toolActivity)
                    let before = try await ingestion.sessionSummary(paneId: pane)
                    held.release()
                    let exitResult = try await exit.value
                    let afterExit = try await ingestion.sessionSummary(paneId: pane)
                    #expect(exitResult == nil)
                    #expect(afterExit == before)
                    try await submitMainSessionHook(adapter, pane: pane, session: "A", event: .sessionEnd)
                    let afterLateEnd = try await ingestion.sessionSummary(paneId: pane)
                    #expect(afterLateEnd == before)
                    let context = try await ingestion.repository.statusContext(paneId: pane)
                    #expect(context.evidence.last?.statusEffect == .recordedOnly)
                    return before
                } catch {
                    held.retire()
                    _ = try? await exit.value
                    throw error
                }
            })
        try await fixture.withIngestion { ingestion, _ in
            let restored = try await ingestion.sessionSummary(paneId: pane)
            #expect(restored == result)
        }
    }

}

enum MainSessionAdapterScenario: CaseIterable, Sendable {
    case childIgnored, nextMainAfterEnd, earlyStartHeals, sameConversationIndependent, knownEndedDoesNotAffectNewMain,
        commandExit
}

private func submitMainSessionHook(
    _ adapter: AgentStudioIPCSessionsAdapter, pane: UUID, session: String, event: IPCSessionEventName
) async throws {
    let result = try await adapter.recordProviderEvent(
        paneId: pane,
        params: .init(
            handle: pane.uuidString, provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
            event: .init(
                name: event, conversationId: session, turnId: "turn", requestId: nil,
                toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
            correlationId: UUIDv7.generate()), provenance: .matchingPane)
    #expect(result.disposition == .admitted)
}

private func mainSessionRowCounts(_ fixture: RecordedStatusDatabase) async throws -> [Int] {
    let queue = try DatabaseQueue(path: fixture.databaseURL.path)
    return try await queue.read { database in
        try [
            "sessions_operation", "sessions_conversation", "sessions_pane_binding", "sessions_source",
            "sessions_evidence",
        ].map { tableName in
            let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(tableName)")
            return try #require(count)
        }
    }
}

private func assertEndedFactsLeaveLiveMain(
    fixture: RecordedStatusDatabase, ingestion: SessionsIngestion, adapter: AgentStudioIPCSessionsAdapter,
    pane: UUID, activityCount: @Sendable () -> Int
) async throws {
    let repository = await ingestion.repository
    try await submitMainSessionHook(adapter, pane: pane, session: "main", event: .sessionEnd)
    try await submitMainSessionHook(adapter, pane: pane, session: "next", event: .toolActivity)
    let before = try await repository.statusContext(paneId: pane)
    let mainBefore = try await ingestion.sessionSummary(paneId: pane)
    let beforeActivityCount = activityCount()
    for event in [IPCSessionEventName.sessionEnd, .toolActivity] {
        try await submitMainSessionHook(adapter, pane: pane, session: "main", event: event)
    }
    let recorded = try await repository.statusContext(paneId: pane)
    #expect(recorded.evidence.count == before.evidence.count + 2)
    #expect(recorded.evidence.suffix(2).allSatisfy { $0.statusEffect == .recordedOnly })
    let afterRecordedFacts = try await ingestion.sessionSummary(paneId: pane)
    #expect(afterRecordedFacts == mainBefore)
    let counts = try await mainSessionRowCounts(fixture)
    try await submitMainSessionHook(adapter, pane: pane, session: "main", event: .sessionStart)
    try await submitMainSessionHook(adapter, pane: pane, session: "child", event: .permission)
    let afterIgnoredCounts = try await mainSessionRowCounts(fixture)
    let afterIgnoredSummary = try await ingestion.sessionSummary(paneId: pane)
    #expect(afterIgnoredCounts == counts)
    #expect(afterIgnoredSummary == mainBefore)
    #expect(activityCount() == beforeActivityCount)
}

private func assertCommandExitKeepsSuccessor(
    fixture: RecordedStatusDatabase, ingestion: SessionsIngestion, adapter: AgentStudioIPCSessionsAdapter,
    pane: UUID, exitAt: ContinuousClock.Instant, activityCount: @Sendable () -> Int
) async throws {
    let repository = await ingestion.repository
    let closed = try await ingestion.submitCommandFinished(paneId: pane, reportedAt: exitAt)
    #expect(closed?.binding.status == .ended)
    let endedSummary = try await ingestion.sessionSummary(paneId: pane)
    #expect(endedSummary?.status == .idle(.ended))
    let counts = try await mainSessionRowCounts(fixture)
    let repeatedExit = try await ingestion.submitCommandFinished(paneId: pane, reportedAt: exitAt)
    let afterRepeatedCounts = try await mainSessionRowCounts(fixture)
    #expect(repeatedExit == nil)
    #expect(afterRepeatedCounts == counts)
    try await submitMainSessionHook(adapter, pane: pane, session: "next", event: .toolActivity)
    let before = try await repository.statusContext(paneId: pane)
    let mainBefore = try await ingestion.sessionSummary(paneId: pane)
    let beforeActivityCount = activityCount()
    let delayedExit = try await ingestion.submitCommandFinished(paneId: pane, reportedAt: exitAt)
    #expect(delayedExit == nil)
    try await submitMainSessionHook(adapter, pane: pane, session: "main", event: .sessionEnd)
    let after = try await repository.statusContext(paneId: pane)
    #expect(after.currentBinding == before.currentBinding)
    #expect(after.evidence.count == before.evidence.count + 1)
    #expect(after.evidence.last?.statusEffect == .recordedOnly)
    let afterLateEnd = try await ingestion.sessionSummary(paneId: pane)
    #expect(afterLateEnd == mainBefore)
    #expect(activityCount() == beforeActivityCount)
}
