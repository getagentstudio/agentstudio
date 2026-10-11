import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Observation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

private enum PaneStatusPublicationScope: Hashable, Sendable {
    case scenario
}

private func makePaneStatusPublicationSource() -> LocalFactSource<
    PaneStatusPublicationScope, PaneActivityStatusAtom.PublicationOutcome
> {
    LocalFactSource(
        vocabulary: FactVocabulary(
            describeScope: { _ in "pane status publication scenario" },
            describeFact: { String(describing: $0) },
            isClosing: { _, outcome in outcome == .deadlineFired }
        )
    )
}

private final class PaneActivityStatusObservationCounter: @unchecked Sendable {
    private(set) var count = 0
    private(set) var didFire = false

    func record() {
        didFire = true
        count += 1
    }
}

@MainActor
private final class PaneActivityStatusOutcomeRecorder {
    private(set) var outcomes: [PaneActivityStatusAtom.PublicationOutcome] = []

    func record(_ outcome: PaneActivityStatusAtom.PublicationOutcome) {
        outcomes.append(outcome)
    }
}

@MainActor
private func observeStatus(
    for paneId: UUID,
    on atom: PaneActivityStatusAtom,
    counter: PaneActivityStatusObservationCounter
) {
    withObservationTracking {
        _ = atom.status(for: paneId)
    } onChange: {
        MainActor.assumeIsolated {
            counter.record()
            observeStatus(for: paneId, on: atom, counter: counter)
        }
    }
}

@MainActor
@Suite(.serialized)
struct PaneActivityStatusAtomTests {
    @Test("settled activity with a real line publishes the fact")
    func settledActivityWithRealLinePublishesFact() {
        let currentDate = Date(timeIntervalSince1970: 0)
        let atom = PaneActivityStatusAtom(now: { currentDate })
        let paneId = UUID()

        let didPublish = atom.recordSettledActivity(paneId: paneId, lastOutputLine: "seam-live-proof")

        #expect(didPublish)
        #expect(atom.status(for: paneId)?.lastOutputLine == "seam-live-proof")
        #expect(atom.status(for: paneId)?.observedAt == currentDate)
    }

    @Test("nil or empty last output line publishes nothing")
    func nilOrEmptyLastOutputLinePublishesNothing() {
        let atom = PaneActivityStatusAtom(now: { Date(timeIntervalSince1970: 0) })
        let paneId = UUID()

        #expect(!atom.recordSettledActivity(paneId: paneId, lastOutputLine: nil))
        #expect(!atom.recordSettledActivity(paneId: paneId, lastOutputLine: ""))
        #expect(atom.status(for: paneId) == nil)
    }

    @Test("a distinct settle within the window publishes at the exact deadline without another settle")
    func settleWithinWindowPublishesAtDeadline() async throws {
        let source = makePaneStatusPublicationSource()
        let publications = try source.attach()
        var currentDate = Date(timeIntervalSince1970: 1000)
        var monotonicNow = Duration.zero
        let clock = TestPushClock()
        let atom = PaneActivityStatusAtom(
            minimumPublishInterval: .seconds(10),
            clock: clock,
            now: { currentDate },
            monotonicNow: { monotonicNow },
            onPublicationOutcome: { source.sink(.scenario, $0) }
        )
        let paneId = UUID()

        do {
            #expect(atom.recordSettledActivity(paneId: paneId, lastOutputLine: "first line"))
            currentDate = currentDate.addingTimeInterval(9.999)
            let didPublishWithinWindow = atom.recordSettledActivity(paneId: paneId, lastOutputLine: "second line")

            #expect(!didPublishWithinWindow)
            #expect(atom.status(for: paneId)?.lastOutputLine == "first line")
            try await publications.expectNext(in: .scenario, .published)
            try await publications.expectNext(in: .scenario, .deferred)

            await clock.waitForPendingSleepCount(exactly: 1)
            currentDate = Date(timeIntervalSince1970: 1010)
            monotonicNow = .seconds(10)
            clock.advance(by: .seconds(10))
            try await publications.expectNext(in: .scenario, .deadlineFired)

            #expect(atom.status(for: paneId)?.lastOutputLine == "second line")
            #expect(atom.status(for: paneId)?.observedAt == Date(timeIntervalSince1970: 1009.999))
            try await publications.finish()
        } catch {
            atom.clear(paneId: paneId)
            await clock.waitForPendingSleepCount(exactly: 0)
            try? await publications.finish()
            throw error
        }
    }

    @Test("multiple deferred settles retain only the latest pane value and one deadline")
    func multipleDeferredSettlesRetainLatestValue() async throws {
        let source = makePaneStatusPublicationSource()
        let publications = try source.attach()
        var currentDate = Date(timeIntervalSince1970: 1000)
        var monotonicNow = Duration.zero
        let clock = TestPushClock()
        let outcomeRecorder = PaneActivityStatusOutcomeRecorder()
        let atom = PaneActivityStatusAtom(
            minimumPublishInterval: .seconds(10),
            clock: clock,
            now: { currentDate },
            monotonicNow: { monotonicNow },
            onPublicationOutcome: {
                outcomeRecorder.record($0)
                source.sink(.scenario, $0)
            }
        )
        let paneId = UUID()

        do {
            #expect(atom.recordSettledActivity(paneId: paneId, lastOutputLine: "first"))
            currentDate = Date(timeIntervalSince1970: 1001)
            #expect(!atom.recordSettledActivity(paneId: paneId, lastOutputLine: "second"))
            currentDate = Date(timeIntervalSince1970: 1002)
            #expect(!atom.recordSettledActivity(paneId: paneId, lastOutputLine: "third"))
            try await publications.expectNext(in: .scenario, .published)
            try await publications.expectNext(in: .scenario, .deferred)
            try await publications.expectNext(in: .scenario, .replaced)
            await clock.waitForPendingSleepCount(exactly: 1)

            currentDate = Date(timeIntervalSince1970: 1010)
            monotonicNow = .seconds(10)
            clock.advance(by: .seconds(10))
            try await publications.expectNext(in: .scenario, .deadlineFired)

            #expect(atom.status(for: paneId)?.lastOutputLine == "third")
            #expect(atom.status(for: paneId)?.observedAt == Date(timeIntervalSince1970: 1002))
            #expect(outcomeRecorder.outcomes == [.published, .deferred, .replaced, .deadlineFired])
            try await publications.finish()
        } catch {
            atom.clear(paneId: paneId)
            await clock.waitForPendingSleepCount(exactly: 0)
            try? await publications.finish()
            throw error
        }
    }

    @Test("clear removes pending state and restores immediate publication eligibility")
    func clearRemovesPendingAndRestoresEligibility() async {
        var currentDate = Date(timeIntervalSince1970: 1000)
        let monotonicNow = Duration.zero
        let clock = TestPushClock()
        let atom = PaneActivityStatusAtom(
            minimumPublishInterval: .seconds(10),
            clock: clock,
            now: { currentDate },
            monotonicNow: { monotonicNow }
        )
        let paneId = UUID()

        #expect(atom.recordSettledActivity(paneId: paneId, lastOutputLine: "first"))
        currentDate = Date(timeIntervalSince1970: 1001)
        #expect(!atom.recordSettledActivity(paneId: paneId, lastOutputLine: "pending"))
        await clock.waitForPendingSleepCount(exactly: 1)

        atom.clear(paneId: paneId)
        await clock.waitForPendingSleepCount(exactly: 0)
        #expect(atom.status(for: paneId) == nil)

        #expect(atom.recordSettledActivity(paneId: paneId, lastOutputLine: "after clear"))
        #expect(atom.status(for: paneId)?.lastOutputLine == "after clear")
    }

    @Test("a deferred value is cancelled when the latest input returns to the committed value")
    func deferredValueIsCancelledByCommittedValue() async {
        var currentDate = Date(timeIntervalSince1970: 1000)
        var monotonicNow = Duration.zero
        let clock = TestPushClock()
        let atom = PaneActivityStatusAtom(
            minimumPublishInterval: .seconds(10),
            clock: clock,
            now: { currentDate },
            monotonicNow: { monotonicNow }
        )
        let paneId = UUID()

        #expect(atom.recordSettledActivity(paneId: paneId, lastOutputLine: "committed"))
        currentDate = Date(timeIntervalSince1970: 1001)
        #expect(!atom.recordSettledActivity(paneId: paneId, lastOutputLine: "pending"))
        await clock.waitForPendingSleepCount(exactly: 1)

        currentDate = Date(timeIntervalSince1970: 1002)
        #expect(!atom.recordSettledActivity(paneId: paneId, lastOutputLine: "committed"))
        await clock.waitForPendingSleepCount(exactly: 0)

        currentDate = Date(timeIntervalSince1970: 1010)
        monotonicNow = .seconds(10)
        clock.advance(by: .seconds(10))
        #expect(atom.status(for: paneId)?.lastOutputLine == "committed")
    }

    @Test("clearing the earliest pending pane reschedules the one deadline to the next pane")
    func clearingEarliestPendingPaneReschedulesNextDeadline() async throws {
        let source = makePaneStatusPublicationSource()
        let publications = try source.attach()
        var currentDate = Date(timeIntervalSince1970: 1000)
        var monotonicNow = Duration.zero
        let clock = TestPushClock()
        let atom = PaneActivityStatusAtom(
            minimumPublishInterval: .seconds(10),
            clock: clock,
            now: { currentDate },
            monotonicNow: { monotonicNow },
            onPublicationOutcome: { source.sink(.scenario, $0) }
        )
        let firstPaneId = UUID()
        let secondPaneId = UUID()

        do {
            #expect(atom.recordSettledActivity(paneId: firstPaneId, lastOutputLine: "first committed"))
            currentDate = Date(timeIntervalSince1970: 1001)
            monotonicNow = .seconds(1)
            #expect(atom.recordSettledActivity(paneId: secondPaneId, lastOutputLine: "second committed"))
            currentDate = Date(timeIntervalSince1970: 1002)
            monotonicNow = .seconds(2)
            #expect(!atom.recordSettledActivity(paneId: firstPaneId, lastOutputLine: "first pending"))
            #expect(!atom.recordSettledActivity(paneId: secondPaneId, lastOutputLine: "second pending"))
            await clock.waitForPendingSleepGeneration(0)

            atom.clear(paneId: firstPaneId)
            try await publications.expectNext(in: .scenario, .published)
            try await publications.expectNext(in: .scenario, .published)
            try await publications.expectNext(in: .scenario, .deferred)
            try await publications.expectNext(in: .scenario, .deferred)
            try await publications.expectNext(in: .scenario, .cleared)
            await clock.waitForPendingSleepGeneration(1)

            currentDate = Date(timeIntervalSince1970: 1011)
            monotonicNow = .seconds(11)
            clock.advance(by: .seconds(9))
            try await publications.expectNext(in: .scenario, .deadlineFired)

            #expect(atom.status(for: firstPaneId) == nil)
            #expect(atom.status(for: secondPaneId)?.lastOutputLine == "second pending")
            try await publications.finish()
        } catch {
            atom.clear(paneId: firstPaneId)
            atom.clear(paneId: secondPaneId)
            await clock.waitForPendingSleepCount(exactly: 0)
            try? await publications.finish()
            throw error
        }
    }

    @Test("a settle at or after the 10s window publishes the latest line")
    func settleAfterWindowPublishes() {
        var currentDate = Date(timeIntervalSince1970: 1000)
        var monotonicNow = Duration.zero
        let atom = PaneActivityStatusAtom(
            minimumPublishInterval: .seconds(10),
            now: { currentDate },
            monotonicNow: { monotonicNow }
        )
        let paneId = UUID()

        #expect(atom.recordSettledActivity(paneId: paneId, lastOutputLine: "first line"))
        currentDate = currentDate.addingTimeInterval(10)
        monotonicNow = .seconds(10)
        let didPublishAfterWindow = atom.recordSettledActivity(paneId: paneId, lastOutputLine: "second line")

        #expect(didPublishAfterWindow)
        #expect(atom.status(for: paneId)?.lastOutputLine == "second line")
    }

    @Test("the 10s cadence is scoped per pane, not global")
    func cadenceIsScopedPerPane() {
        let currentDate = Date(timeIntervalSince1970: 1000)
        let atom = PaneActivityStatusAtom(minimumPublishInterval: .seconds(10), now: { currentDate })
        let firstPaneId = UUID()
        let secondPaneId = UUID()

        #expect(atom.recordSettledActivity(paneId: firstPaneId, lastOutputLine: "pane one"))
        // A different pane, at the same instant, is not rate-limited by the first pane's publish.
        #expect(atom.recordSettledActivity(paneId: secondPaneId, lastOutputLine: "pane two"))
    }

    @Test("an unchanged line for the same pane is a no-op via AtomFamily's equal-write suppression")
    func unchangedLineIsEqualWriteSuppressed() {
        var currentDate = Date(timeIntervalSince1970: 1000)
        let atom = PaneActivityStatusAtom(minimumPublishInterval: .seconds(10), now: { currentDate })
        let paneId = UUID()
        let counter = PaneActivityStatusObservationCounter()

        #expect(atom.recordSettledActivity(paneId: paneId, lastOutputLine: "same line"))
        observeStatus(for: paneId, on: atom, counter: counter)

        currentDate = currentDate.addingTimeInterval(20)
        let didPublishRepeatedLine = atom.recordSettledActivity(paneId: paneId, lastOutputLine: "same line")

        #expect(!didPublishRepeatedLine)
        #expect(!counter.didFire)
    }

    @Test("keyed readers wake only for the touched pane")
    func keyedReadersWakeOnlyForTouchedPane() {
        let currentDate = Date(timeIntervalSince1970: 1000)
        let atom = PaneActivityStatusAtom(minimumPublishInterval: .seconds(10), now: { currentDate })
        let observedPaneId = UUID()
        let otherPaneId = UUID()
        let observedCounter = PaneActivityStatusObservationCounter()
        let otherCounter = PaneActivityStatusObservationCounter()

        observeStatus(for: observedPaneId, on: atom, counter: observedCounter)
        observeStatus(for: otherPaneId, on: atom, counter: otherCounter)

        atom.recordSettledActivity(paneId: observedPaneId, lastOutputLine: "only this pane changed")

        #expect(observedCounter.count == 1)
        #expect(!otherCounter.didFire)
    }
}
