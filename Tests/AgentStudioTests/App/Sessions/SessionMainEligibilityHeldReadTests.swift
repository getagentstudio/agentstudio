import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionMainEligibilityTests {
    @Test(
        "held leader reads revalidate both admission routes", arguments: MainEligibilityRoute.allCases,
        HeldMainEligibilityScenario.allCases)
    func heldLeaderRevalidation(route: MainEligibilityRoute, scenario: HeldMainEligibilityScenario) async throws {
        let fixture = try MainEligibilityDatabaseFixture()
        let pane = UUIDv7.generate()
        let firstScope = UUIDv7.generate()
        let secondScope = UUIDv7.generate()
        let held = HeldStep<ZmxSessionID>("first candidate's terminal-leader observation")
        let facts = LocalFactSource<UUID, MainEligibilityQueueFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    switch fact {
                    case .firstEnded, .secondEnded: true
                    case .queued, .leaderRead: false
                    }
                }))
        let reader = HeldMainEligibilityLeaderReader(held: held, onRead: { facts.sink(firstScope, .leaderRead) })
        let recorder = try facts.attach()
        let ingestion = SessionsIngestion(
            repository: fixture.repository, limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128),
            probe: { statistics in
                if statistics.event == .depthChanged, statistics.paneId == pane, statistics.pendingGlobal == 2 {
                    facts.sink(secondScope, .queued)
                }
            }, terminalLeaderReader: reader)
        let first = Task {
            defer {
                held.retire()
                facts.sink(firstScope, .firstEnded)
            }
            do {
                return Result<MainEligibilityRouteOutcome, any Error>.success(
                    try await route.submit(ingestion, pane: pane, session: "A"))
            } catch { return .failure(error) }
        }
        var second: Task<Result<MainEligibilityRouteOutcome, any Error>, Never>?
        let sidebar = SessionStatusAtom()
        do {
            try await recorder.expectNext(in: firstScope, .leaderRead)
            sidebar.apply(await ingestion.statusPublicationMailbox.takeBatch())
            #expect(sidebar.value(for: .init(existingUUID: pane))?.status == .unknown)
            switch scenario {
            case .competing:
                second = Task {
                    defer { facts.sink(secondScope, .secondEnded) }
                    do { return .success(try await route.submit(ingestion, pane: pane, session: "B")) } catch {
                        return .failure(error)
                    }
                }
                try await recorder.expectNext(in: secondScope, .queued)
            case .retirement: ingestion.paneViewedMailbox.retire([pane])
            case .sessionChange: reader.changeSession()
            }
            held.release()
            let firstOutcome = try (await first.value).get()
            if scenario == .competing {
                switch firstOutcome {
                case .verified(.committed(let commit)): #expect(commit.disposition == .bound)
                case .claim(let outcome): #expect(outcome == .hookApplied)
                default: Issue.record("First queued candidate did not elect: \(firstOutcome)")
                }
            } else {
                #expect(firstOutcome == route.refusedElection(retired: scenario == .retirement))
            }
            if let second {
                #expect(try (await second.value).get() == route.refusedElection(retired: false))
            }
            try await assertHeldEligibilityState(
                fixture: fixture, ingestion: ingestion, sidebar: sidebar, pane: pane, route: route, scenario: scenario)
            #expect(reader.readCount == 1)
            await ingestion.finish()
            facts.end()
            try await recorder.finish()
        } catch {
            held.retire()
            _ = await first.value
            if let second { _ = await second.value }
            await ingestion.finish()
            facts.end()
            try? await recorder.finish()
            throw error
        }
    }
}

enum HeldMainEligibilityScenario: CaseIterable, Sendable { case competing, retirement, sessionChange }
enum MainEligibilityQueueFact: Equatable, Sendable {
    case queued, leaderRead, firstEnded, secondEnded
}
enum MainEligibilityRouteOutcome: Equatable, Sendable {
    case verified(SessionsHookOutcome)
    case claim(SessionsUnverifiedStatusOutcome)
}

enum MainEligibilityRoute: CaseIterable, Sendable {
    case verified, claim
    func submit(_ ingestion: SessionsIngestion, pane: UUID, session: String) async throws -> MainEligibilityRouteOutcome
    {
        let hook = mainEligibilityHook(
            pane: pane, session: session, signal: .toolActivity(toolName: "Read"), chain: TestMainAgentChain.observation
        )
        switch self {
        case .verified: return .verified(try await ingestion.submitHook(hook))
        case .claim: return .claim(try await submitMainEligibilityClaim(ingestion, hook))
        }
    }
    func refusedElection(retired: Bool) -> MainEligibilityRouteOutcome {
        switch self {
        case .verified: .verified(.ignored)
        case .claim: .claim(retired ? .notAccepted : .hookAcceptedWithoutStatus)
        }
    }
}

final class HeldMainEligibilityLeaderReader: PaneTerminalLeaderReading {
    private struct State {
        var sessionID = ZmxSessionID.generateUUIDv7()
        var readCount = 0
    }
    private let state = Mutex(State())
    let held: HeldStep<ZmxSessionID>
    let onRead: @Sendable () -> Void
    init(held: HeldStep<ZmxSessionID>, onRead: @escaping @Sendable () -> Void) {
        self.held = held
        self.onRead = onRead
    }
    var readCount: Int { state.withLock { $0.readCount } }
    func changeSession() { state.withLock { $0.sessionID = .generateUUIDv7() } }
    func terminalSessionID(for paneId: UUID) async -> ZmxSessionID? { state.withLock { $0.sessionID } }
    func terminalLeader(for sessionID: ZmxSessionID) async -> ZmxProcessIncarnation? {
        let isFirst = state.withLock { state in
            state.readCount += 1
            return state.readCount == 1
        }
        if isFirst {
            onRead()
            do { try await held.arrive(sessionID) } catch { return nil }
        }
        // The read result stays matching even if the persisted association changes while held.
        return TestMainAgentChain.shell
    }
}

@MainActor
private func assertHeldEligibilityState(
    fixture: MainEligibilityDatabaseFixture, ingestion: SessionsIngestion, sidebar: SessionStatusAtom,
    pane: UUID, route: MainEligibilityRoute, scenario: HeldMainEligibilityScenario
) async throws {
    let hasVerifiedMain = scenario == .competing && route == .verified
    let context = try await fixture.repository.statusContext(paneId: pane)
    #expect(context.currentBinding?.providerConversationId == (hasVerifiedMain ? "A" : nil))
    #expect(context.evidence.count == (hasVerifiedMain ? 1 : 0))
    let claimMain = await ingestion.unverifiedStatusRuntime.panes[pane]?.main?.sessionId
    #expect(claimMain == (scenario == .competing && route == .claim ? "A" : nil))
    let query = try await AgentStudioIPCSessionsAdapter(ingestion: ingestion).readSessionState(
        paneId: pane, params: .init(handle: pane.uuidString))
    #expect(query.sourceHealth == (hasVerifiedMain ? .live : .unbound))
    #expect(query.session?.conversationId == (hasVerifiedMain ? "A" : nil))
    let mailbox = await ingestion.statusPublicationMailbox.takeBatch()
    let key = PaneId(existingUUID: pane)
    if scenario == .retirement { #expect(mailbox[key] == .remove) }
    sidebar.apply(mailbox)
    switch scenario {
    case .competing: #expect(sidebar.value(for: key)?.status == .working(.active))
    case .retirement: #expect(sidebar.value(for: key) == nil)
    case .sessionChange: #expect(sidebar.value(for: key)?.status == .unknown)
    }
}
