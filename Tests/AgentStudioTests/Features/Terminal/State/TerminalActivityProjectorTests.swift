import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

private final class LateCompletionClock: Clock, @unchecked Sendable {
    struct Instant: Sendable, Comparable, Hashable, InstantProtocol {
        fileprivate let nanoseconds: Int64

        func advanced(by duration: Duration) -> Self {
            let components = duration.components
            return .init(
                nanoseconds: nanoseconds
                    + components.seconds * 1_000_000_000
                    + components.attoseconds / 1_000_000_000
            )
        }

        func duration(to other: Self) -> Duration {
            .nanoseconds(other.nanoseconds - nanoseconds)
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.nanoseconds < rhs.nanoseconds
        }
    }

    private struct PendingSleep {
        let generation: Int
        let continuation: UnsafeContinuation<Void, Never>
    }

    private struct GenerationWaiter {
        let generation: Int
        let continuation: UnsafeContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var nextGeneration = 0
    private var pendingSleeps: [PendingSleep] = []
    private var generationWaiters: [GenerationWaiter] = []

    var now: Instant { .init(nanoseconds: 0) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let generation = lock.withLock {
            defer { nextGeneration += 1 }
            return nextGeneration
        }
        await withUnsafeContinuation { continuation in
            var readyWaiters: [UnsafeContinuation<Void, Never>] = []
            lock.withLock {
                pendingSleeps.append(.init(generation: generation, continuation: continuation))
                readyWaiters = removeReadyWaiters()
            }
            for waiter in readyWaiters {
                waiter.resume()
            }
        }
    }

    func waitForPendingSleep(generation: Int) async {
        let isPending = lock.withLock {
            pendingSleeps.contains { $0.generation == generation }
        }
        guard !isPending else { return }

        await withUnsafeContinuation { continuation in
            let shouldResume = lock.withLock {
                if pendingSleeps.contains(where: { $0.generation == generation }) {
                    return true
                }
                generationWaiters.append(.init(generation: generation, continuation: continuation))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resumeSleep(generation: Int) {
        let continuation = lock.withLock { () -> UnsafeContinuation<Void, Never>? in
            guard let index = pendingSleeps.firstIndex(where: { $0.generation == generation }) else {
                return nil
            }
            return pendingSleeps.remove(at: index).continuation
        }
        continuation?.resume()
    }

    private func removeReadyWaiters() -> [UnsafeContinuation<Void, Never>] {
        var readyWaiters: [UnsafeContinuation<Void, Never>] = []
        generationWaiters.removeAll { waiter in
            guard pendingSleeps.contains(where: { $0.generation == waiter.generation }) else {
                return false
            }
            readyWaiters.append(waiter.continuation)
            return true
        }
        return readyWaiters
    }
}

@MainActor
@Suite("Terminal activity projector", .serialized)
struct TerminalActivityProjectorTests {
    @Test("aggregate admission retains fixed state per pane")
    func aggregateAdmissionIsBoundedPerPane() async {
        let clock = TestPushClock()
        let projector = TerminalActivityProjector(clock: clock)
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let context = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: true,
            outputBurstThreshold: 30
        )
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()

        for index in 0..<1000 {
            let aggregate = makeAggregate(firstTotal: index, latestTotal: index + 1)
            await projector.ingest(
                surfaceID: surfaceID,
                paneID: paneID,
                aggregate: aggregate,
                latestState: ScrollbarState(top: index, bottom: index + 1, total: index + 1),
                context: context
            )
        }

        #expect(await projector.retainedPaneCount == 1)
        #expect(await projector.scheduledTimerCount == 2)
        await projector.reset()
    }

    @Test("closing an old surface cannot retire its pane replacement")
    func oldSurfaceCloseDoesNotRetireReplacement() async {
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let context = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: false,
            outputBurstThreshold: 30
        )
        let paneID = UUIDv7.generate()
        let oldSurfaceID = UUIDv7.generate()
        let replacementSurfaceID = UUIDv7.generate()
        let aggregate = makeAggregate(firstTotal: 100, latestTotal: 120)

        await projector.ingest(
            surfaceID: oldSurfaceID,
            paneID: paneID,
            aggregate: aggregate,
            latestState: ScrollbarState(top: 80, bottom: 120, total: 120),
            context: context
        )
        await projector.ingest(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            aggregate: aggregate,
            latestState: ScrollbarState(top: 80, bottom: 120, total: 120),
            context: context
        )
        await projector.closeSurface(surfaceID: oldSurfaceID, paneID: paneID)
        await projector.markObserved(surfaceID: oldSurfaceID, paneID: paneID)

        #expect(await projector.retainedPaneCount == 1)
        #expect(await projector.scheduledTimerCount == 1)

        await projector.closeSurface(surfaceID: replacementSurfaceID, paneID: paneID)
        #expect(await projector.retainedPaneCount == 0)
    }

    @Test("equal compact state and first output are emitted once")
    func equalOutcomesAreSuppressed() async {
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let context = TerminalActivityProjectionContext(
            isAttended: true,
            isAgentClassified: false,
            outputBurstThreshold: 30
        )
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()
        let aggregate = makeAggregate(firstTotal: 100, latestTotal: 100)
        let state = ScrollbarState(top: 60, bottom: 100, total: 100)

        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: aggregate,
            latestState: state,
            context: context
        )
        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: aggregate,
            latestState: state,
            context: context
        )

        let compactCount = recorder.outcomes.count { outcome in
            if case .compactStateChanged = outcome { return true }
            return false
        }
        let firstRenderCount = recorder.outcomes.count { outcome in
            if case .firstRender = outcome { return true }
            return false
        }
        #expect(compactCount == 1)
        #expect(firstRenderCount == 1)
    }

    @Test("aggregate preserves transient entry and exit from pinned bottom")
    func aggregatePreservesTransientPinnedEntryAndExit() async {
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()
        let states = [
            ScrollbarState(top: 0, bottom: 10, total: 100),
            ScrollbarState(top: 90, bottom: 100, total: 100),
            ScrollbarState(top: 0, bottom: 10, total: 100),
        ]

        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: makeAggregate(states: states),
            latestState: states[2],
            context: attendedContext
        )

        #expect(observationStates(in: recorder.outcomes) == [false, true, false])
        #expect(latestCompactScrollbarState(in: recorder.outcomes) == states[2])
        await projector.reset()
    }

    @Test("aggregate preserves transient exit and return to pinned bottom")
    func aggregatePreservesTransientPinnedExitAndEntry() async {
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()
        let states = [
            ScrollbarState(top: 90, bottom: 100, total: 100),
            ScrollbarState(top: 0, bottom: 10, total: 100),
            ScrollbarState(top: 90, bottom: 100, total: 100),
        ]

        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: makeAggregate(states: states),
            latestState: states[2],
            context: attendedContext
        )

        #expect(observationStates(in: recorder.outcomes) == [true, false, true])
        #expect(latestCompactScrollbarState(in: recorder.outcomes) == states[2])
        await projector.reset()
    }

    @Test("quiet settlement is derived by the projector actor")
    func quietSettlementIsProjectorOwned() async throws {
        let clock = TestPushClock()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750),
            clock: clock
        )
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let context = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: false,
            outputBurstThreshold: 30
        )
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()

        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 100, latestTotal: 140),
            latestState: ScrollbarState(top: 100, bottom: 140, total: 140),
            context: context
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: .milliseconds(750))
        _ = try await recorder.firstSnapshot { outcomes in
            outcomes.contains { outcome in
                guard case .unseenActivitySettled(_, let outcomePaneID, let activity) = outcome else { return false }
                return activity.rowsAdded == 40 && outcomePaneID == paneID
            }
        }
    }

    @Test("unchanged last output line is suppressed on the following settle")
    func unchangedLastOutputLineIsSuppressedOnFollowingSettle() async throws {
        let clock = TestPushClock()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750),
            clock: clock
        )
        let recorder = OutcomeRecorder()
        await projector.configure(
            lastOutputLineReader: { _ in .value("same output line") },
            outcomeSink: { outcomes in recorder.record(outcomes) }
        )
        let context = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: false,
            outputBurstThreshold: 30
        )
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()

        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 100, latestTotal: 140),
            latestState: ScrollbarState(top: 100, bottom: 140, total: 140),
            context: context
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: .milliseconds(750))
        _ = try await recorder.firstSnapshot { outcomes in
            outcomes.contains { outcome in
                guard case .unseenActivitySettled(_, let outcomePaneID, let activity) = outcome else { return false }
                return outcomePaneID == paneID && activity.lastOutputLine == "same output line"
            }
        }

        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 140, latestTotal: 180),
            latestState: ScrollbarState(top: 140, bottom: 180, total: 180),
            context: context
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: .milliseconds(750))
        let secondSettledActivity = try await recorder.firstSnapshot { outcomes in
            outcomes.contains { outcome in
                guard case .unseenActivitySettled(_, let outcomePaneID, let activity) = outcome else { return false }
                return outcomePaneID == paneID && activity.baselineRows == 140
            }
        }.compactMap { outcome -> TerminalSettledActivity? in
            guard case .unseenActivitySettled(_, let outcomePaneID, let activity) = outcome,
                outcomePaneID == paneID, activity.baselineRows == 140
            else { return nil }
            return activity
        }.first

        #expect(secondSettledActivity?.lastOutputLine == nil)
        await projector.reset()
    }

    @Test("separate single-sample drains preserve cross-drain activity growth")
    func separateSingleSampleDrainsPreserveActivityGrowth() async throws {
        let clock = TestPushClock()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750),
            agentSettledQuietDuration: .milliseconds(750),
            clock: clock
        )
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let context = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: true,
            outputBurstThreshold: 30
        )
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()

        let samples: [(total: Int, observedAt: Int64)] = [
            (total: 100, observedAt: 1000),
            (total: 400, observedAt: 32_000),
            (total: 700, observedAt: 62_000),
        ]
        for sample in samples {
            let state = ScrollbarState(
                top: max(0, sample.total - 40),
                bottom: sample.total,
                total: sample.total
            )
            await projector.ingest(
                surfaceID: surfaceID,
                paneID: paneID,
                aggregate: makeSingleSampleAggregate(
                    state: state,
                    observedAtMilliseconds: sample.observedAt
                ),
                latestState: state,
                context: context
            )
        }

        await clock.waitForPendingSleepCount(exactly: 2)
        clock.advance(by: .milliseconds(750))
        _ = try await recorder.firstSnapshot { outcomes in
            let settledRows = outcomes.compactMap { outcome -> Int? in
                switch outcome {
                case .unseenActivitySettled(_, let outcomePaneID, let activity),
                    .agentSettledActivityPromoted(_, let outcomePaneID, let activity):
                    return outcomePaneID == paneID ? activity.rowsAdded : nil
                default:
                    return nil
                }
            }
            return settledRows == [600, 600]
        }
        await projector.reset()
    }

    @Test("late unseen callback cannot settle a replacement window with the same generation")
    func lateUnseenCallbackCannotSettleReplacementWindow() async throws {
        let clock = LateCompletionClock()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750),
            clock: clock
        )
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let context = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: false,
            outputBurstThreshold: 30
        )
        let paneID = UUIDv7.generate()
        let oldSurfaceID = UUIDv7.generate()
        let replacementSurfaceID = UUIDv7.generate()

        await projector.ingest(
            surfaceID: oldSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 100, latestTotal: 140),
            latestState: ScrollbarState(top: 100, bottom: 140, total: 140),
            context: context
        )
        await clock.waitForPendingSleep(generation: 0)
        await projector.ingest(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 200, latestTotal: 260),
            latestState: ScrollbarState(top: 220, bottom: 260, total: 260),
            context: context
        )

        clock.resumeSleep(generation: 0)
        await clock.waitForPendingSleep(generation: 1)

        #expect(await projector.scheduledTimerCount == 1)
        #expect(
            recorder.outcomes.contains { outcome in
                if case .unseenActivitySettled = outcome { return true }
                return false
            } == false)

        clock.resumeSleep(generation: 1)
        _ = try await recorder.firstSnapshot { outcomes in
            outcomes.contains { outcome in
                guard case .unseenActivitySettled(let surfaceID, let outcomePaneID, _) = outcome else {
                    return false
                }
                return surfaceID == replacementSurfaceID && outcomePaneID == paneID
            }
        }
        await projector.reset()
    }

    @Test("late agent callback cannot promote a replacement candidate with the same generation")
    func lateAgentCallbackCannotPromoteReplacementCandidate() async throws {
        let clock = LateCompletionClock()
        let projector = TerminalActivityProjector(
            agentSettledQuietDuration: .seconds(180),
            clock: clock
        )
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let context = TerminalActivityProjectionContext(
            isAttended: true,
            isAgentClassified: true,
            outputBurstThreshold: 30
        )
        let paneID = UUIDv7.generate()
        let oldSurfaceID = UUIDv7.generate()
        let replacementSurfaceID = UUIDv7.generate()

        await projector.ingest(
            surfaceID: oldSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(
                firstTotal: 100,
                latestTotal: 700,
                firstObservedAtMilliseconds: 1000,
                latestObservedAtMilliseconds: 62_000
            ),
            latestState: ScrollbarState(top: 660, bottom: 700, total: 700),
            context: context
        )
        await clock.waitForPendingSleep(generation: 0)
        await projector.ingest(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(
                firstTotal: 200,
                latestTotal: 800,
                firstObservedAtMilliseconds: 63_000,
                latestObservedAtMilliseconds: 124_000
            ),
            latestState: ScrollbarState(top: 760, bottom: 800, total: 800),
            context: context
        )

        clock.resumeSleep(generation: 0)
        await clock.waitForPendingSleep(generation: 1)

        #expect(await projector.scheduledTimerCount == 1)
        #expect(
            recorder.outcomes.contains { outcome in
                if case .agentSettledActivityPromoted = outcome { return true }
                return false
            } == false)

        clock.resumeSleep(generation: 1)
        _ = try await recorder.firstSnapshot { outcomes in
            outcomes.contains { outcome in
                guard case .agentSettledActivityPromoted(let surfaceID, let outcomePaneID, _) = outcome else {
                    return false
                }
                return surfaceID == replacementSurfaceID && outcomePaneID == paneID
            }
        }
        await projector.reset()
    }

    @Test("ordered observation applies earlier evidence before clearing activity windows")
    func orderedObservationClearsEarlierEvidence() async {
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()
        let context = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: true,
            outputBurstThreshold: 30
        )

        await projector.applyOrderedControl(
            surfaceID: surfaceID,
            paneID: paneID,
            precedingAggregate: TerminalActivityAggregateInput(
                aggregate: makeAggregate(firstTotal: 100, latestTotal: 140),
                latestState: ScrollbarState(top: 100, bottom: 140, total: 140),
                context: context
            ),
            control: .observed
        )

        #expect(await projector.retainedPaneCount == 1)
        #expect(await projector.scheduledTimerCount == 0)
        #expect(
            recorder.outcomes.contains { outcome in
                if case .compactStateChanged = outcome { return true }
                return false
            }
        )
    }

    @Test("ordered close retires earlier evidence without post-close debt")
    func orderedCloseRetiresEarlierEvidence() async {
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()

        await projector.applyOrderedControl(
            surfaceID: surfaceID,
            paneID: paneID,
            precedingAggregate: TerminalActivityAggregateInput(
                aggregate: makeAggregate(firstTotal: 100, latestTotal: 140),
                latestState: ScrollbarState(top: 100, bottom: 140, total: 140),
                context: TerminalActivityProjectionContext(
                    isAttended: false,
                    isAgentClassified: true,
                    outputBurstThreshold: 30
                )
            ),
            control: .surfaceClosed
        )

        #expect(await projector.retainedPaneCount == 0)
        #expect(await projector.scheduledTimerCount == 0)
        #expect(
            recorder.outcomes.last == .surfaceClosed(surfaceID: surfaceID, paneID: paneID)
        )
    }

    @Test("sink-triggered later evidence cannot split the ordered outcome batch")
    func orderedControlDeliversOneNoninterleavedOutcomeBatch() async {
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let recorder = OutcomeRecorder()
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()
        let context = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: false,
            outputBurstThreshold: 30
        )
        var laterAggregateTask: Task<Void, Never>?
        await projector.configure { outcomes in
            recorder.record(outcomes)
            guard recorder.batches.count == 1 else { return }
            laterAggregateTask = Task {
                await projector.ingest(
                    surfaceID: surfaceID,
                    paneID: paneID,
                    aggregate: makeAggregate(firstTotal: 140, latestTotal: 180),
                    latestState: ScrollbarState(top: 140, bottom: 180, total: 180),
                    context: context
                )
            }
        }

        await projector.applyOrderedControl(
            surfaceID: surfaceID,
            paneID: paneID,
            precedingAggregate: TerminalActivityAggregateInput(
                aggregate: makeAggregate(firstTotal: 100, latestTotal: 140),
                latestState: ScrollbarState(top: 100, bottom: 140, total: 140),
                context: context
            ),
            control: .observed
        )
        await laterAggregateTask?.value

        #expect(await projector.scheduledTimerCount == 1)
        #expect(recorder.batches.count == 2)
        #expect(recorder.batches[0].count == 3)
        #expect(
            recorder.batches[0].map { outcome in
                switch outcome {
                case .compactStateChanged: return "compact"
                case .firstRender: return "firstRender"
                case .paneObservationChanged: return "observation"
                default: return "unexpected"
                }
            } == ["compact", "firstRender", "observation"]
        )
        #expect(recorder.batches[1].count == 1)
        #expect(
            recorder.batches[1].allSatisfy { outcome in
                if case .compactStateChanged = outcome { return true }
                return false
            }
        )
        await projector.reset()
    }

    private func makeAggregate(
        firstTotal: Int,
        latestTotal: Int,
        firstObservedAtMilliseconds: Int64 = 1000,
        latestObservedAtMilliseconds: Int64 = 1100
    ) -> TerminalScrollbarActivityAggregate {
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(top: max(0, firstTotal - 10), bottom: firstTotal, total: firstTotal),
            observedAtMilliseconds: firstObservedAtMilliseconds
        )
        aggregate.merge(
            state: ScrollbarState(top: max(0, latestTotal - 10), bottom: latestTotal, total: latestTotal),
            observedAtMilliseconds: latestObservedAtMilliseconds
        )
        return aggregate
    }

    private func makeSingleSampleAggregate(
        state: ScrollbarState,
        observedAtMilliseconds: Int64
    ) -> TerminalScrollbarActivityAggregate {
        TerminalScrollbarActivityAggregate(
            state: state,
            observedAtMilliseconds: observedAtMilliseconds
        )
    }

    private var attendedContext: TerminalActivityProjectionContext {
        TerminalActivityProjectionContext(
            isAttended: true,
            isAgentClassified: false,
            outputBurstThreshold: 30
        )
    }

    private func makeAggregate(states: [ScrollbarState]) -> TerminalScrollbarActivityAggregate {
        let firstState = states[0]
        var aggregate = TerminalScrollbarActivityAggregate(
            state: firstState,
            observedAtMilliseconds: 1000
        )
        for (index, state) in states.dropFirst().enumerated() {
            aggregate.merge(
                state: state,
                observedAtMilliseconds: 1100 + Int64(index * 100)
            )
        }
        return aggregate
    }

    private func observationStates(
        in outcomes: [TerminalActivityProjectionOutcome]
    ) -> [Bool] {
        outcomes.compactMap { outcome in
            guard case .paneObservationChanged(_, _, let isPinnedToBottom) = outcome else {
                return nil
            }
            return isPinnedToBottom
        }
    }

    private func latestCompactScrollbarState(
        in outcomes: [TerminalActivityProjectionOutcome]
    ) -> ScrollbarState? {
        outcomes.compactMap { outcome -> ScrollbarState? in
            guard case .compactStateChanged(let update) = outcome else { return nil }
            return update.scrollbarState
        }.last
    }
}
