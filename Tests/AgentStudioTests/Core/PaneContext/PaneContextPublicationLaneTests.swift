import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

@Suite("Pane context publication lane")
struct PaneContextPublicationLaneTests {
    @Test("The lane reports only occupancy supplied by the batched assignment sink")
    func measurementExcludesExecutorWait() async throws {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let paneId = PaneId.generateUUIDv7()
        let measurement = PaneContextPresentationApplyMeasurement()
        let observations = PaneContextApplyObservationRecorder()
        let lane = PaneContextPublicationLane(
            mailbox: mailbox,
            sink: { _ in measurement.recordHeldDuration(.milliseconds(7)) },
            measurement: measurement, probe: { observations.append($0) })
        try #require(mailbox.offer(presentationDisplay(), for: paneId))
        await lane.publishPending()
        try #require(mailbox.offer(presentationDisplay(revision: 2), for: paneId))
        await lane.publishPending()
        let values = observations.values()
        #expect(values.count == 2)
        #expect(values.last?.heldDuration == .milliseconds(7))
        #expect(values.last?.totalHeldDuration == .milliseconds(14))
        #expect(values.last?.maximumHeldDuration == .milliseconds(7))
        #expect(values.last?.batchSize == 1)
        #expect(values.last?.counts.computed == 2)
        await lane.shutdown()
    }

    @Test("One awaited MainActor sink receives a whole multi-pane batch")
    func oneCallCarriesManyPanes() async throws {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let first = PaneId.generateUUIDv7()
        let second = PaneId.generateUUIDv7()
        let display = presentationDisplay(title: "Batch")
        try #require(mailbox.offer(display, for: first), "RED must fail before creating a lane")
        try #require(mailbox.offer(display, for: second))
        let batches = Mutex<[[PaneId: PaneContextPublication]]>([])
        let lane = PaneContextPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                MainActor.preconditionIsolated()
                batches.withLock { $0.append(batch) }
            })
        await lane.publishPending()
        #expect(batches.withLock { $0 } == [[first: .set(display), second: .set(display)]])
        #expect(!mailbox.offer(display, for: first))
        await lane.publishPending()
        #expect(batches.withLock { $0.count } == 1)
        await lane.shutdown()
    }

    @Test("A held sink coalesces a burst to the newest desired value")
    func heldSinkCoalescesBurst() async throws {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        let first = presentationDisplay(title: "First")
        try #require(mailbox.offer(first, for: pane), "Inert mailbox must fail before HeldStep waits")
        let held = HeldStep<[PaneId: PaneContextPublication]>("first pane-context batch held")
        let batches = Mutex<[[PaneId: PaneContextPublication]]>([])
        let lane = PaneContextPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                MainActor.preconditionIsolated()
                batches.withLock { $0.append(batch) }
                try? await held.arrive(batch)
            })
        let drain = Task { await lane.publishPending() }
        do {
            #expect(try await held.firstArrival() == [pane: .set(first)])
            mailbox.offer(presentationDisplay(title: "Middle"), for: pane)
            let newest = presentationDisplay(title: "Newest")
            mailbox.offer(newest, for: pane)
            #expect(!mailbox.offer(newest, for: pane))
            held.release()
            await drain.value
            #expect(batches.withLock { $0 } == [[pane: .set(first)], [pane: .set(newest)]])
            await lane.shutdown()
        } catch {
            held.retire()
            drain.cancel()
            await drain.value
            await lane.shutdown()
            throw error
        }
    }

    @Test("Returning to A while A is in flight enqueues A after desired B")
    func heldReturnToBaselinePreservesDesiredOrder() async throws {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        let first = presentationDisplay(title: "A")
        try #require(mailbox.offer(first, for: pane))
        let held = HeldStep<[PaneId: PaneContextPublication]>("A in flight before B and A")
        let batches = Mutex<[[PaneId: PaneContextPublication]]>([])
        let lane = PaneContextPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                batches.withLock { $0.append(batch) }
                try? await held.arrive(batch)
            })
        let drain = Task { await lane.publishPending() }
        do {
            _ = try await held.firstArrival()
            mailbox.offer(presentationDisplay(title: "B"), for: pane)
            #expect(mailbox.offer(first, for: pane))
            held.release()
            await drain.value
            #expect(batches.withLock { $0 } == [[pane: .set(first)], [pane: .set(first)]])
            await lane.shutdown()
        } catch {
            held.retire()
            drain.cancel()
            await drain.value
            await lane.shutdown()
            throw error
        }
    }

    @Test("Removal follows an in-flight set and rejects every late resurrection")
    func heldSetCannotResurrectRetirement() async throws {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        let display = presentationDisplay(title: "In flight")
        try #require(mailbox.offer(display, for: pane))
        let held = HeldStep<[PaneId: PaneContextPublication]>("set held before pane retirement")
        let batches = Mutex<[[PaneId: PaneContextPublication]]>([])
        let lane = PaneContextPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                batches.withLock { $0.append(batch) }
                try? await held.arrive(batch)
            })
        let drain = Task { await lane.publishPending() }
        do {
            _ = try await held.firstArrival()
            mailbox.retire(pane)
            #expect(!mailbox.offer(presentationDisplay(title: "Late"), for: pane))
            held.release()
            await drain.value
            #expect(batches.withLock { $0 } == [[pane: .set(display)], [pane: .remove]])
            await lane.shutdown()
        } catch {
            held.retire()
            drain.cancel()
            await drain.value
            await lane.shutdown()
            throw error
        }
    }

    @Test("Shutdown discards pending values and never calls the sink afterward")
    func shutdownClosesPublication() async throws {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        try #require(mailbox.offer(presentationDisplay(), for: pane))
        let calls = Mutex(0)
        let lane = PaneContextPublicationLane(mailbox: mailbox, sink: { _ in calls.withLock { $0 += 1 } })
        await lane.shutdown()
        await lane.publishPending()
        #expect(!mailbox.offer(presentationDisplay(title: "After shutdown"), for: pane))
        #expect(calls.withLock { $0 } == 0)
    }
}

private final class PaneContextApplyObservationRecorder: Sendable {
    private let observations = Mutex<[PaneContextPresentationApplySnapshot]>([])
    func append(_ snapshot: PaneContextPresentationApplySnapshot) { observations.withLock { $0.append(snapshot) } }
    func values() -> [PaneContextPresentationApplySnapshot] { observations.withLock { $0 } }
}
