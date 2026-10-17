import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions evidence reducer")
struct SessionsEvidenceReducerTests {
    @Test(
        "the binding table preserves pane ownership and applies its precedence",
        arguments: BindingTableScenario.allCases)
    func bindingTable(scenario: BindingTableScenario) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let otherPane = UUIDv7.generate()
        let timeline = BindingTableTimeline(startingAt: ContinuousClock.now)
        let context = try await prepareBindingTableContext(
            scenario: scenario, repository: repository, sqliteAccess: fixture.sqliteAccess,
            paneId: pane, otherPaneId: otherPane, timeline: timeline)

        let rowsBeforeDecision: [Int?]
        if scenario.isIgnored {
            rowsBeforeDecision = try await sessionsStorageRowCounts(fixture.sqliteAccess)
        } else {
            rowsBeforeDecision = []
        }
        let outcome = try await repository.applyHook(
            scenario.admission(paneId: pane, instant: timeline.decision))
        try await assertBindingTableOutcome(
            outcome, scenario: scenario, context: context, rowsBeforeDecision: rowsBeforeDecision)
    }
}

private struct BindingTableTimeline: Sendable {
    let first: ContinuousClock.Instant
    let ended: ContinuousClock.Instant
    let nextMain: ContinuousClock.Instant
    let decision: ContinuousClock.Instant

    init(startingAt first: ContinuousClock.Instant) {
        self.first = first
        ended = first + .milliseconds(1)
        nextMain = first + .milliseconds(2)
        decision = first + .milliseconds(3)
    }
}

private struct BindingTableContext: Sendable {
    let repository: SessionsRepository
    let sqliteAccess: TestSessionsSQLiteAccess
    let paneId: UUID
    let otherPaneId: UUID
    let decisionInstant: ContinuousClock.Instant
    let endedMain: SessionsHookCommit?
    let liveMain: SessionsHookCommit?
    let otherPaneMain: SessionsHookCommit?
}

private func prepareBindingTableContext(
    scenario: BindingTableScenario,
    repository: SessionsRepository,
    sqliteAccess: TestSessionsSQLiteAccess,
    paneId: UUID,
    otherPaneId: UUID,
    timeline: BindingTableTimeline
) async throws -> BindingTableContext {
    var endedMain: SessionsHookCommit?
    var liveMain: SessionsHookCommit?
    var otherPaneMain: SessionsHookCommit?
    switch scenario {
    case .firstStart, .firstActivity:
        break
    case .liveMainApplies, .unknownChildActivityIgnored, .unknownChildStartIgnored:
        let mainOutcome = try await repository.applyHook(
            makeHookAdmission(paneId: paneId, sessionId: "main", admissionInstant: timeline.first))
        liveMain = committedHookCommit(from: mainOutcome)
    case .endedLateFactWhileNewMainIsLive, .endedStartIgnoredWhileNewMainIsLive,
        .endedStartResumesAfterNewMainEnds:
        let oldMainOutcome = try await repository.applyHook(
            makeHookAdmission(paneId: paneId, sessionId: "A", admissionInstant: timeline.first))
        endedMain = committedHookCommit(from: oldMainOutcome)
        let endOutcome = try await repository.applyHook(
            makeHookAdmission(
                paneId: paneId, sessionId: "A", eventName: .sessionEnd, signal: .sessionEnd,
                admissionInstant: timeline.ended))
        _ = try #require(committedHookCommit(from: endOutcome))
        let newMainOutcome = try await repository.applyHook(
            makeHookAdmission(
                paneId: paneId, sessionId: "B", eventName: .toolActivity,
                signal: .toolActivity(toolName: "Read"), admissionInstant: timeline.nextMain))
        liveMain = committedHookCommit(from: newMainOutcome)
        if scenario == .endedStartResumesAfterNewMainEnds {
            let newMainEndOutcome = try await repository.applyHook(
                makeHookAdmission(
                    paneId: paneId, sessionId: "B", eventName: .sessionEnd, signal: .sessionEnd,
                    admissionInstant: timeline.decision))
            _ = try #require(committedHookCommit(from: newMainEndOutcome))
        }
    case .sameConversationInAnotherPane:
        let mainOutcome = try await repository.applyHook(
            makeHookAdmission(paneId: otherPaneId, sessionId: "shared", admissionInstant: timeline.first))
        otherPaneMain = committedHookCommit(from: mainOutcome)
    }
    return .init(
        repository: repository, sqliteAccess: sqliteAccess, paneId: paneId, otherPaneId: otherPaneId,
        decisionInstant: timeline.decision, endedMain: endedMain, liveMain: liveMain, otherPaneMain: otherPaneMain)
}

private func assertBindingTableOutcome(
    _ outcome: SessionsHookOutcome,
    scenario: BindingTableScenario,
    context: BindingTableContext,
    rowsBeforeDecision: [Int?]
) async throws {
    switch scenario {
    case .unknownChildActivityIgnored, .unknownChildStartIgnored:
        try await assertIgnoredHook(
            outcome, context: context, rowsBeforeDecision: rowsBeforeDecision, expectedStatus: .unknown)
    case .endedStartIgnoredWhileNewMainIsLive:
        try await assertIgnoredHook(
            outcome, context: context, rowsBeforeDecision: rowsBeforeDecision, expectedStatus: .working(.active))
    case .endedLateFactWhileNewMainIsLive:
        try await assertLateEndedSessionFacts(outcome, context: context)
    case .endedStartResumesAfterNewMainEnds:
        try assertResumedEndedSession(outcome, context: context)
    case .sameConversationInAnotherPane:
        try await assertIndependentPaneBindings(outcome, context: context)
    case .firstStart, .firstActivity:
        try assertFirstHookBinds(outcome, paneId: context.paneId)
    case .liveMainApplies:
        let applied = try #require(committedHookCommit(from: outcome))
        #expect(applied.disposition == .applied)
        #expect(applied.binding.bindingGenerationId == context.liveMain?.binding.bindingGenerationId)
    }
}

private func assertIgnoredHook(
    _ outcome: SessionsHookOutcome,
    context: BindingTableContext,
    rowsBeforeDecision: [Int?],
    expectedStatus: AgentSessionStatus
) async throws {
    guard case .ignored = outcome else {
        Issue.record("A hook for a non-main session with a live main must be ignored")
        return
    }
    let rowsAfterDecision = try await sessionsStorageRowCounts(context.sqliteAccess)
    #expect(rowsAfterDecision == rowsBeforeDecision)
    let statusContext = try await context.repository.statusContext(paneId: context.paneId)
    #expect(statusContext.currentBinding?.bindingGenerationId == context.liveMain?.binding.bindingGenerationId)
    #expect(statusContext.currentBinding?.status == .active)
    let summary = try await withSessionsIngestion(repository: context.repository) { ingestion in
        try await ingestion.sessionSummary(paneId: context.paneId)
    }
    #expect(summary?.status == expectedStatus)
}

private func assertLateEndedSessionFacts(
    _ outcome: SessionsHookOutcome,
    context: BindingTableContext
) async throws {
    let lateActivity = try #require(committedHookCommit(from: outcome))
    #expect(lateActivity.disposition == .recordedOnly)
    #expect(lateActivity.binding.bindingGenerationId == context.endedMain?.binding.bindingGenerationId)
    #expect(lateActivity.evidence.statusEffect == .recordedOnly)
    let lateEndOutcome = try await context.repository.applyHook(
        makeHookAdmission(
            paneId: context.paneId, sessionId: "A", eventName: .sessionEnd, signal: .sessionEnd,
            admissionInstant: context.decisionInstant + .milliseconds(1)))
    let lateEnd = try #require(committedHookCommit(from: lateEndOutcome))
    #expect(lateEnd.disposition == .recordedOnly)
    #expect(lateEnd.binding.bindingGenerationId == context.endedMain?.binding.bindingGenerationId)
    #expect(lateEnd.evidence.statusEffect == .recordedOnly)
    let statusContext = try await context.repository.statusContext(paneId: context.paneId)
    #expect(statusContext.currentBinding?.bindingGenerationId == context.liveMain?.binding.bindingGenerationId)
    #expect(statusContext.currentBinding?.status == .active)
    let restoredSummary = try await withSessionsIngestion(repository: context.repository) { ingestion in
        try await ingestion.sessionSummary(paneId: context.paneId)
    }
    #expect(restoredSummary?.status == .working(.active))
}

private func assertResumedEndedSession(_ outcome: SessionsHookOutcome, context: BindingTableContext) throws {
    let resumed = try #require(committedHookCommit(from: outcome))
    #expect(resumed.disposition == .bound)
    #expect(resumed.binding.bindingGenerationId == context.endedMain?.binding.bindingGenerationId)
    #expect(resumed.binding.status == .active)
}

private func assertIndependentPaneBindings(
    _ outcome: SessionsHookOutcome,
    context: BindingTableContext
) async throws {
    let secondPaneCommit = try #require(committedHookCommit(from: outcome))
    #expect(secondPaneCommit.disposition == .bound)
    #expect(secondPaneCommit.binding.paneId == context.paneId)
    #expect(secondPaneCommit.binding.bindingGenerationId != context.otherPaneMain?.binding.bindingGenerationId)
    let firstPaneContext = try await context.repository.statusContext(paneId: context.otherPaneId)
    let secondPaneContext = try await context.repository.statusContext(paneId: context.paneId)
    #expect(firstPaneContext.currentBinding?.bindingGenerationId == context.otherPaneMain?.binding.bindingGenerationId)
    #expect(firstPaneContext.currentBinding?.status == .active)
    #expect(secondPaneContext.currentBinding?.bindingGenerationId == secondPaneCommit.binding.bindingGenerationId)
    #expect(secondPaneContext.currentBinding?.status == .active)
}

private func assertFirstHookBinds(_ outcome: SessionsHookOutcome, paneId: UUID) throws {
    let first = try #require(committedHookCommit(from: outcome))
    #expect(first.disposition == .bound)
    #expect(first.binding.paneId == paneId)
    #expect(first.binding.status == .active)
}

private func sessionsStorageRowCounts(_ access: TestSessionsSQLiteAccess) async throws -> [Int?] {
    try await access.read { database in
        try [
            "sessions_operation", "sessions_conversation", "sessions_pane_binding", "sessions_source",
            "sessions_evidence",
        ].map { tableName in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(tableName)")
        }
    }
}

enum BindingTableScenario: CaseIterable, Equatable, Sendable {
    case firstStart
    case firstActivity
    case liveMainApplies
    case unknownChildActivityIgnored
    case unknownChildStartIgnored
    case endedLateFactWhileNewMainIsLive
    case endedStartIgnoredWhileNewMainIsLive
    case endedStartResumesAfterNewMainEnds
    case sameConversationInAnotherPane

    var isIgnored: Bool {
        switch self {
        case .unknownChildActivityIgnored, .unknownChildStartIgnored, .endedStartIgnoredWhileNewMainIsLive:
            return true
        case .firstStart, .firstActivity, .liveMainApplies, .endedLateFactWhileNewMainIsLive,
            .endedStartResumesAfterNewMainEnds, .sameConversationInAnotherPane:
            return false
        }
    }

    func admission(paneId: UUID, instant: ContinuousClock.Instant) -> SessionsHookAdmission {
        switch self {
        case .firstStart:
            return makeHookAdmission(paneId: paneId, sessionId: "main", admissionInstant: instant)
        case .firstActivity, .liveMainApplies, .unknownChildActivityIgnored, .endedLateFactWhileNewMainIsLive,
            .sameConversationInAnotherPane:
            return makeHookAdmission(
                paneId: paneId, sessionId: sessionId,
                eventName: .toolActivity, signal: .toolActivity(toolName: "Read"), admissionInstant: instant)
        case .unknownChildStartIgnored, .endedStartIgnoredWhileNewMainIsLive,
            .endedStartResumesAfterNewMainEnds:
            return makeHookAdmission(paneId: paneId, sessionId: sessionId, admissionInstant: instant)
        }
    }

    private var sessionId: String {
        switch self {
        case .unknownChildActivityIgnored, .unknownChildStartIgnored:
            return "child"
        case .endedLateFactWhileNewMainIsLive, .endedStartIgnoredWhileNewMainIsLive,
            .endedStartResumesAfterNewMainEnds:
            return "A"
        case .firstActivity, .sameConversationInAnotherPane:
            return "shared"
        case .liveMainApplies:
            return "main"
        case .firstStart:
            return "main"
        }
    }
}
