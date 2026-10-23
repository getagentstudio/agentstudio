import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Closed-app narrow end from SR11b")
struct ClosedAppOutboxTests {
    @Test("equal UUID text from another provider is another session", arguments: ["codex", "claude-code"])
    func providerIsPartOfSessionIdentity(provider: String) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        _ = try await repository.applyHook(
            .init(
                paneId: pane, providerIdentifier: provider, providerVersion: "1.0", sessionId: session,
                eventName: .sessionStart, turnId: nil, signal: .sessionStart, recordId: UUIDv7.generate(),
                admittedAt: Date(timeIntervalSince1970: 1)))
        let original = try await repository.statusContext(paneId: pane).currentBinding
        let report = ClosedAppLifecycleReport(
            reportId: UUIDv7.generate(), paneId: pane,
            providerIdentifier: provider == "codex" ? "claude-code" : "codex",
            providerConversationId: session, event: .sessionEnd, reportedAt: Date(timeIntervalSince1970: 2),
            newerOrEqualSameSessionStartInRead: false, isNewestInRead: true)
        try await withSessionsIngestion(repository: repository) { ingestion in
            let outcome = try await ingestion.admitClosedAppOutboxItem(
                .report(report), restoreEvidence: NoClosedAppRestoreEffect(), participants: [])
            #expect(outcome == .unchanged(.otherSession))
            #expect(try await repository.statusContext(paneId: pane).currentBinding == original)
        }
    }

    @Test(arguments: ClosedAppPredicateCase.allCases)
    func narrowEndInputProduct(input: ClosedAppPredicateCase) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let ownSession = UUIDv7.generate().uuidString
        if input.binding != .absent {
            _ = try await repository.applyHook(
                .init(
                    paneId: pane, providerIdentifier: "codex", providerVersion: "1.0", sessionId: ownSession,
                    eventName: .sessionStart, turnId: nil, signal: .sessionStart, recordId: UUIDv7.generate(),
                    admittedAt: Date(timeIntervalSince1970: input.evidenceTime)))
            if input.binding == .ended {
                let binding = try #require(try await repository.statusContext(paneId: pane).currentBinding)
                _ = try await repository.endLiveBinding(
                    expectedBinding: binding, endedAt: Date(timeIntervalSince1970: 2))
            }
        }
        let original = try await repository.statusContext(paneId: pane).currentBinding
        let report = ClosedAppLifecycleReport(
            reportId: UUIDv7.generate(), paneId: pane, providerIdentifier: "codex",
            providerConversationId: input.own ? ownSession : UUIDv7.generate().uuidString,
            event: input.start ? .sessionStart : .sessionEnd, reportedAt: Date(timeIntervalSince1970: 3),
            newerOrEqualSameSessionStartInRead: input.laterStart, isNewestInRead: input.newest)
        try await withSessionsIngestion(repository: repository) { ingestion in
            let outcome = try await ingestion.admitClosedAppOutboxItem(
                .report(report), restoreEvidence: NoClosedAppRestoreEffect(), participants: [])
            let context = try await repository.statusContext(paneId: pane)
            // Literal SR11b predicate, not a call to the resolver or production admission.
            let mustEnd =
                !input.start && input.binding == .live && input.own && input.newest
                && !input.laterStart && input.evidenceTime < 3
            if mustEnd {
                #expect(outcome == .endedOwnMain(bindingGenerationId: try #require(original).bindingGenerationId))
                #expect(context.currentBinding?.status == .ended)
                #expect(context.currentBinding?.transitionOccurrenceId == report.reportId)
            } else {
                #expect(context.currentBinding == original)
                if case .endedOwnMain = outcome { Issue.record("Closed a main outside SR11b") }
            }
            if input.start && input.own, let original {
                let fact = try #require(context.evidence.first { $0.recordId == report.reportId })
                #expect(fact.kind == .activityStarted)
                #expect(fact.providerSignal == .sessionStart)
                #expect(fact.statusEffect == .recordedOnly)
                #expect(fact.origin == .reported)
                #expect(fact.bindingGenerationId == original.bindingGenerationId)
            }
        }
    }
}

struct ClosedAppPredicateCase: Sendable {
    enum BindingState: Sendable { case live, ended, absent }
    let binding: BindingState
    let start: Bool
    let own: Bool
    let newest: Bool
    let laterStart: Bool
    let evidenceTime: TimeInterval

    static let allCases: [Self] = {
        var cases: [Self] = []
        for binding in [BindingState.live, .ended, .absent] {
            for start in [false, true] {
                for own in [false, true] {
                    for newest in [false, true] {
                        for laterStart in [false, true] {
                            for time in [2.9996, 3.0006, 3.0016] {
                                cases.append(
                                    .init(
                                        binding: binding, start: start, own: own, newest: newest,
                                        laterStart: laterStart, evidenceTime: time))
                            }
                        }
                    }
                }
            }
        }
        return cases
    }()
}

struct NoClosedAppRestoreEffect: ClosedAppRestoreEvidenceParticipant {
    func commit(in database: Database, item: ClosedAppOutboxItem, latestBindings: SessionsLatestBindings) {}
}
