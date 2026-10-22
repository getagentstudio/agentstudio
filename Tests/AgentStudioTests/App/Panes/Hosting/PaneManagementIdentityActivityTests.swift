import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityActivityTests {
    @Test("card activity follows the active, minute and recency-tier deadlines")
    func activityChangesAtSidebarDeadlines() async throws {
        let reference = ContinuousClock.now
        let input = activityInput(
            .init(orderingInstant: reference, wallTime: wallReference, source: .terminal))
        try await withActivityRun(input, reference: reference) { run in
            try await run.facts.expectNext(in: 0, .published("Now", .strongBlue, true))
            try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(60))))
            #expect(run.clock.pendingSleepCount == 1)

            run.clock.advance(by: .seconds(60))

            try await run.facts.expectNext(in: 0, .published("1m", .strongBlue, false))
            try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(120))))
            #expect(run.clock.pendingSleepCount == 1)

            // A suspended host may resume after several deadlines: project its current age once.
            run.clock.advance(to: run.start.advanced(by: .seconds(600)))

            try await run.facts.expectNext(in: 0, .published("10m", .mediumBlue, false))
            try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(660))))
            #expect(run.clock.pendingSleepCount == 1)
        }
    }

    @Test("a card with no activity publishes the sidebar placeholder and schedules nothing")
    func missingActivityDoesNotScheduleRefresh() async throws {
        try await withActivityRun(activityInput(nil), reference: .now) { run in
            try await run.facts.expectNext(in: 0, .published("—", .grey, false))
            try await run.facts.expectNext(in: 0, .finished)
            await run.task.value
            run.didStop = true
            #expect(run.clock.pendingSleepCount == 0)
        }
    }

    @Test("a sidebar bucket deadline does not republish equal card chips")
    func bucketOnlyDeadlineSuppressesEqualPresentation() async throws {
        let reference = ContinuousClock.now
        let justBeforeMidnight = Date(timeIntervalSince1970: 1_700_006_399)
        let input = activityInput(
            .init(
                orderingInstant: reference.advanced(by: .seconds(-6000)),
                wallTime: justBeforeMidnight.addingTimeInterval(-6000), source: .terminal))
        try await withActivityRun(input, reference: reference, wallNow: justBeforeMidnight) { run in
            try await run.facts.expectNext(in: 0, .published("1h", .mutedBlue, false))
            try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(1))))

            run.clock.advance(by: .seconds(1))

            // The next exact owner fact is a new deadline, with no equal publication between them.
            try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(1200))))
            #expect(run.clock.pendingSleepCount == 1)
        }
    }

    @Test("retiring the host task cancels its deadline and excludes later publications")
    func cancelledHostCannotPublishAfterDeadline() async throws {
        let reference = ContinuousClock.now
        let input = activityInput(
            .init(
                orderingInstant: reference.advanced(by: .seconds(-59)), wallTime: wallReference,
                source: .hook))
        try await withActivityRun(input, reference: reference) { run in
            try await run.facts.expectNext(in: 0, .published("Now", .strongBlue, true))
            try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(1))))
            let opening = await run.facts.mark(0)

            run.task.cancel()
            await run.task.value

            try await run.facts.expectNone(
                of: {
                    if case .published = $0 { return true }
                    return false
                },
                "retired card publication", from: opening, closedBy: { $0 == .finished })
            run.didStop = true
            #expect(run.clock.pendingSleepCount == 0)
            run.clock.advance(by: .seconds(120))
        }
    }

    @Test("replacement activity starts a fresh deadline after the previous snapshot retires")
    func replacementInputReschedulesFromItsOwnActivity() async throws {
        let reference = ContinuousClock.now
        let oldInput = activityInput(
            .init(
                orderingInstant: reference.advanced(by: .seconds(-59)), wallTime: wallReference,
                source: .hook))
        try await withActivityRun(oldInput, reference: reference) { old in
            try await old.facts.expectNext(in: 0, .published("Now", .strongBlue, true))
            try await old.facts.expectNext(in: 0, .sleep(old.start.advanced(by: .seconds(1))))
            try await old.stop()
            #expect(old.clock.pendingSleepCount == 0)

            let replacement = activityInput(
                .init(orderingInstant: reference, wallTime: wallReference, source: .terminal))
            try await withActivityRun(replacement, reference: reference) { current in
                try await current.facts.expectNext(in: 0, .published("Now", .strongBlue, true))
                try await current.facts.expectNext(in: 0, .sleep(current.start.advanced(by: .seconds(60))))
                #expect(current.clock.pendingSleepCount == 1)
                old.clock.advance(by: .seconds(120))
                #expect(old.clock.pendingSleepCount == 0)
            }
        }
    }

    @Test("card input observes only its pane's canonical activity time")
    func capturesKeyedCanonicalActivity() async {
        await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Terminal")
            let other = store.createPane(title: "Other")
            let context = PaneManagementContext.project(paneId: pane.id, store: store)
            let initial = PaneManagementIdentityCapture.input(
                context: context, store: store, readers: nil)
            #expect(initial.activityTime == nil)
            let time = PaneActivityTime(orderingInstant: .now, wallTime: wallReference, source: .terminal)

            atoms.paneActivityTime.apply([.set(other.id, time)])

            #expect(
                PaneManagementIdentityCapture.input(context: context, store: store, readers: nil) == initial
            )
            atoms.paneActivityTime.apply([.set(pane.id, time)])
            #expect(
                PaneManagementIdentityCapture.input(context: context, store: store, readers: nil)
                    .activityTime == time)
        }
    }

    private var wallReference: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func activityInput(_ time: PaneActivityTime?) -> PaneManagementIdentityCapture.LineInput {
        .init(
            paneId: UUIDv7.generate(), terminalTitle: "Terminal", cwd: nil,
            shellExecutablePath: nil, agentTitle: nil, note: nil, isDrawer: false,
            agentLine: nil, sessionPresentation: nil, activityTime: time)
    }

    private func withActivityRun(
        _ input: PaneManagementIdentityCapture.LineInput, reference: ContinuousClock.Instant,
        wallNow: Date? = nil,
        body: (ActivityRun) async throws -> Void
    ) async throws {
        let run = ActivityRun(input: input, reference: reference, wallNow: wallNow ?? wallReference)
        do {
            try await body(run)
            try await run.stop()
            try await run.facts.finish()
        } catch {
            run.task.cancel()
            await run.task.value
            try? await run.facts.finish()
            throw error
        }
    }
}

private enum CardActivityFact: Sendable, Equatable {
    case published(String, RepoExplorerPaneRecencyTier, Bool)
    case sleep(TestPushClock.Instant)
    case finished
}

@MainActor
private final class ActivityRun {
    let facts: FactRecorder<Int, CardActivityFact>
    let clock: TestPushClock
    let start: TestPushClock.Instant
    let task: Task<Void, Never>
    var didStop = false

    init(
        input: PaneManagementIdentityCapture.LineInput, reference: ContinuousClock.Instant,
        wallNow: Date
    ) {
        let facts = FactRecorder<Int, CardActivityFact>(
            vocabulary: .init(
                describeScope: { String($0) }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .finished }))
        let clock = TestPushClock(pendingSleepFactSink: { fact in
            if case .registrationSettled(let deadline, _) = fact {
                facts.append(scope: 0, fact: .sleep(deadline))
            }
        })
        self.facts = facts
        self.clock = clock
        start = clock.now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let referenceCalendar = calendar
        task = Task {
            await PaneManagementIdentityCapture.watch(
                input, clock: clock, referenceInstant: reference, wallNow: wallNow,
                calendar: referenceCalendar
            ) { presentation in
                guard !Task.isCancelled else { return }
                facts.append(
                    scope: 0,
                    fact: .published(
                        presentation.recencyText, presentation.recencyTier, presentation.isActive))
            }
            facts.append(scope: 0, fact: .finished)
            facts.receive(.ended)
        }
    }

    func stop() async throws {
        guard !didStop else { return }
        task.cancel()
        await task.value
        try await facts.expectNext(in: 0, .finished)
        didStop = true
    }
}
