import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

private actor PaneActivityBatchRecorder {
    private(set) var batches: [[PaneActivityTimeMutation]] = []

    func apply(_ batch: [PaneActivityTimeMutation]) {
        batches.append(batch)
    }
}

@Suite("Pane activity clock")
struct PaneActivityClockTests {
    @Test("first occurrence publishes immediately; older occurrence cannot replace it")
    func firstAndOlderOccurrence() async throws {
        let base = ContinuousClock.now
        let recorder = PaneActivityBatchRecorder()
        let firstBoundary = HeldStep<PaneActivityPublicationBoundary>("first activity publication or deadline")
        let testClock = PaneActivityPublicationClock(firstBoundary: firstBoundary)
        let clock = PaneActivityClock(
            clock: testClock,
            monotonicNow: { base },
            sink: { batch in
                try? await firstBoundary.arrive(.publication)
                await recorder.apply(batch)
            }
        )
        let paneId = UUIDv7.generate()

        clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(2))))
        await clock.start()
        let boundary = try await firstBoundary.firstArrival()
        #expect(boundary == .publication)
        if boundary != .publication {
            firstBoundary.retire()
            await clock.shutdown()
            return
        }
        firstBoundary.release()
        #expect(try await clock.settled() == .quiescent)
        clock.submit(occurrence(paneId: paneId, instant: base))
        #expect(try await clock.settled() == .quiescent)

        await clock.shutdown()
        let batches = await recorder.batches
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
        if case .set(let publishedPaneId, let time) = batches[0][0] {
            #expect(publishedPaneId == paneId)
            #expect(time.orderingInstant == base.advanced(by: .seconds(2)))
        } else {
            Issue.record("first occurrence did not publish a time")
        }
    }

    @Test("a newer occurrence is deferred to the injected deadline and settled waits for its apply")
    func coalescesUntilDeadline() async throws {
        let base = ContinuousClock.now
        let now = Mutex(base)
        let testClock = TestPushClock()
        let recorder = PaneActivityBatchRecorder()
        let clock = PaneActivityClock(
            publishInterval: .seconds(10),
            clock: testClock,
            monotonicNow: { now.withLock { $0 } },
            sink: { batch in await recorder.apply(batch) }
        )
        let paneId = UUIDv7.generate()

        clock.submit(occurrence(paneId: paneId, instant: base))
        #expect(try await clock.settled() == .quiescent)
        now.withLock { $0 = base.advanced(by: .seconds(1)) }
        clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(1))))
        await testClock.waitForPendingSleepCount(exactly: 1)
        #expect(await clock.pendingDeadline())

        let replacementSleepGeneration = testClock.scheduledSleepGeneration
        now.withLock { $0 = base.advanced(by: .seconds(2)) }
        clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(2))))
        await testClock.waitForPendingSleepGeneration(replacementSleepGeneration)

        now.withLock { $0 = base.advanced(by: .seconds(10)) }
        testClock.advance(by: .seconds(9))
        #expect(try await clock.settled() == .quiescent)
        let batches = await recorder.batches
        #expect(batches.count == 2)
        let newest = occurrence(paneId: paneId, instant: base.advanced(by: .seconds(2)))
        #expect(batches[1] == [.set(paneId, newest.activityTime)])
        await clock.shutdown()
    }

    @Test("a held sink does not lose the newest input for any pane")
    func keyedMailboxWhileSinkHeld() async throws {
        let gate = HeldStep<[PaneActivityTimeMutation]>("first activity batch apply")
        let recorder = PaneActivityBatchRecorder()
        let clock = PaneActivityClock { batch in
            try? await gate.arrive(batch)
            await recorder.apply(batch)
        }
        await clock.start()
        let base = ContinuousClock.now
        let firstPaneId = UUIDv7.generate()
        clock.submit(occurrence(paneId: firstPaneId, instant: base))
        let heldBatch = try await gate.firstArrival()
        #expect(heldBatch.count == 1)

        let otherPaneIds = (0..<16).map { _ in UUIDv7.generate() }
        for paneId in otherPaneIds {
            clock.submit(occurrence(paneId: paneId, instant: base))
            clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(1))))
        }
        gate.release()
        #expect(try await clock.settled() == .quiescent)

        let published = await recorder.batches.flatMap { batch in
            batch.compactMap { mutation -> (UUID, PaneActivityTime)? in
                guard case .set(let paneId, let time) = mutation else { return nil }
                return (paneId, time)
            }
        }
        #expect(published.count == otherPaneIds.count + 1)
        for paneId in otherPaneIds {
            #expect(published.first { $0.0 == paneId }?.1.orderingInstant == base.advanced(by: .seconds(1)))
        }
        await clock.shutdown()
    }

    @Test("cancelling one settled waiter leaves the pending publication and other waiters intact")
    func cancellingSettledWaiter() async throws {
        let base = ContinuousClock.now
        let now = Mutex(base)
        let testClock = TestPushClock()
        let recorder = PaneActivityBatchRecorder()
        let clock = PaneActivityClock(
            publishInterval: .seconds(10),
            clock: testClock,
            monotonicNow: { now.withLock { $0 } },
            sink: { batch in await recorder.apply(batch) }
        )
        let paneId = UUIDv7.generate()
        clock.submit(occurrence(paneId: paneId, instant: base))
        #expect(try await clock.settled() == .quiescent)
        now.withLock { $0 = base.advanced(by: .seconds(1)) }
        clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(1))))
        await testClock.waitForPendingSleepCount(exactly: 1)

        let cancelledWaiter = Task { try await clock.settled() }
        await clock.waitForSettledWaiterCount(1)
        let survivingWaiter = Task { try await clock.settled() }
        await clock.waitForSettledWaiterCount(2)
        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            Issue.record("cancelled settled waiter returned successfully")
        } catch is CancellationError {
            // The other waiters and the pending publication remain owned by the clock.
        }

        now.withLock { $0 = base.advanced(by: .seconds(10)) }
        testClock.advance(by: .seconds(9))
        #expect(try await survivingWaiter.value == .quiescent)
        #expect(await recorder.batches.count == 2)
        await clock.shutdown()
    }

    @Test("shutdown releases settled waiters and rejects later ingress")
    func shutdownReleasesWaiters() async throws {
        let base = ContinuousClock.now
        let now = Mutex(base)
        let testClock = TestPushClock()
        let recorder = PaneActivityBatchRecorder()
        let clock = PaneActivityClock(
            publishInterval: .seconds(10),
            clock: testClock,
            monotonicNow: { now.withLock { $0 } },
            sink: { batch in await recorder.apply(batch) }
        )
        let paneId = UUIDv7.generate()
        clock.submit(occurrence(paneId: paneId, instant: base))
        #expect(try await clock.settled() == .quiescent)
        now.withLock { $0 = base.advanced(by: .seconds(1)) }
        clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(1))))
        await testClock.waitForPendingSleepCount(exactly: 1)

        let waiter = Task { try await clock.settled() }
        await clock.shutdown()
        #expect(try await waiter.value == .shutDown)
        clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(20))))
        #expect(try await clock.settled() == .shutDown)
        #expect(await recorder.batches.count == 1)
    }

    @Test("retirement drops pending publication and rejects late input")
    func retirementTombstonesPane() async throws {
        let base = ContinuousClock.now
        let now = Mutex(base)
        let testClock = TestPushClock()
        let recorder = PaneActivityBatchRecorder()
        let clock = PaneActivityClock(
            publishInterval: .seconds(10),
            clock: testClock,
            monotonicNow: { now.withLock { $0 } },
            sink: { batch in await recorder.apply(batch) }
        )
        let paneId = UUIDv7.generate()

        clock.submit(occurrence(paneId: paneId, instant: base))
        #expect(try await clock.settled() == .quiescent)
        now.withLock { $0 = base.advanced(by: .seconds(1)) }
        clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(1))))
        await testClock.waitForPendingSleepCount(exactly: 1)
        clock.retire([paneId])
        #expect(try await clock.settled() == .quiescent)
        clock.submit(occurrence(paneId: paneId, instant: base.advanced(by: .seconds(20))))
        #expect(try await clock.settled() == .quiescent)

        let batches = await recorder.batches
        #expect(batches.count == 2)
        #expect(batches[1] == [.remove(paneId)])
        await clock.shutdown()
    }

    private func occurrence(paneId: UUID, instant: ContinuousClock.Instant) -> PaneActivityOccurrence {
        PaneActivityOccurrence(
            paneId: paneId,
            source: .terminal,
            orderingInstant: instant,
            wallTime: Date(timeIntervalSince1970: 1000)
        )
    }
}

// Observes the existing clock/sink boundary without advancing time. The first
// occurrence must reach publication, never a timer, before it can settle.
private enum PaneActivityPublicationBoundary: Sendable {
    case publication
    case deadline
}

private struct PaneActivityPublicationClock: Clock {
    typealias Instant = TestPushClock.Instant
    typealias Duration = Swift.Duration

    let firstBoundary: HeldStep<PaneActivityPublicationBoundary>
    private let baseClock = TestPushClock()

    var now: Instant { baseClock.now }
    var minimumResolution: Duration { baseClock.minimumResolution }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await firstBoundary.arrive(.deadline)
        try await baseClock.sleep(until: deadline, tolerance: tolerance)
    }
}
