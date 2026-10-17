import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@MainActor
@Suite("PaneRuntimeEventChannel")
struct PaneRuntimeEventChannelTests {
    @Test("emitted events arrive at the bus in sequence order")
    func emittedEventsReachBusInSequenceOrder() async {
        let harness = EventBusHarness<RuntimeEnvelope>()
        let subscriber = await harness.makeSubscriber()
        let paneId = PaneId.generateUUIDv7()
        let metadata = PaneMetadata(
            paneId: paneId,
            contentType: .terminal,
            title: "Test"
        )
        let channel = PaneRuntimeEventChannel(paneEventBus: harness.bus)

        for index in 0..<10 {
            channel.emit(
                paneId: paneId,
                metadata: metadata,
                paneKind: .terminal,
                event: .terminal(.titleChanged("title-\(index)")),
                persistForReplay: false
            )
        }

        await assertEventuallyAsync(
            "bus subscriber should receive all emitted events",
            minimumTurns: 5000
        ) {
            await subscriber.snapshot().count == 10
        }

        let envelopes = await subscriber.snapshot()
        let paneEvents = RuntimeEnvelopeHarness.paneEvents(from: envelopes)
        #expect(paneEvents.count == 10)
        #expect(paneEvents.map(\.seq) == Array(1...10).map(UInt64.init))

        await subscriber.shutdown()
        channel.finishSubscribers()
        await assertBusDrained(harness.bus)
    }

    @Test("outbound debt transfers to EventBus debt without a false zero")
    func outboundDebtTransfersToEventBusDebt() async {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let outboundPostGate = RuntimeEnvelopeOutboundPostGate(paneEventBus: bus)
        let subscription = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "runtimeChannelTransfer"
        )
        var iterator = subscription.makeAsyncIterator()
        let channel = makeChannel(
            paneEventBus: bus,
            reporter: reporter,
            outboundPost: outboundPostGate.post
        )

        emitBell(on: channel)
        await outboundPostGate.waitUntilPostEntered()

        let outboundSnapshot = reporter.snapshot()
        #expect(outboundSnapshot.runtimeChannelOutboundPendingCount == 1)
        #expect(outboundSnapshot.eventBusActiveDeliveryDebt == 0)
        #expect(outboundSnapshot.totalPendingCount == 1)

        await outboundPostGate.allowPostToFinish()
        await assertEventuallyAsync("outbound custody should transfer to EventBus") {
            let snapshot = reporter.snapshot()
            return snapshot.runtimeChannelOutboundPendingCount == 0
                && snapshot.eventBusActiveDeliveryDebt == 1
                && snapshot.totalPendingCount == 1
        }

        _ = await iterator.next()
        #expect(reporter.snapshot().totalPendingCount == 0)
        channel.finishSubscribers()
    }

    @Test("finish keeps in-flight outbound debt pending until EventBus post completes")
    func finishKeepsInFlightOutboundDebtPendingUntilPostCompletes() async {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let outboundPostGate = RuntimeEnvelopeOutboundPostGate(paneEventBus: bus)
        let channel = makeChannel(
            paneEventBus: bus,
            reporter: reporter,
            outboundPost: outboundPostGate.post
        )

        emitBell(on: channel)
        await outboundPostGate.waitUntilPostEntered()
        #expect(reporter.snapshot().runtimeChannelOutboundPendingCount == 1)

        channel.finishSubscribers()
        let finishingSnapshot = reporter.snapshot()
        #expect(finishingSnapshot.runtimeChannelOutboundPendingCount == 1)
        #expect(finishingSnapshot.runtimeChannelRetiredUndeliveredCount == 0)
        #expect(finishingSnapshot.totalPendingCount == 1)

        await outboundPostGate.allowPostToFinish()
        await channel.finishAndJoinOutboundDelivery()
        let completedSnapshot = reporter.snapshot()
        #expect(completedSnapshot.runtimeChannelOutboundPendingCount == 0)
        #expect(completedSnapshot.runtimeChannelRetiredUndeliveredCount == 0)
    }

    @Test("finish retires only buffered envelopes after an in-flight post completes")
    func finishRetiresOnlyBufferedOutboundDebt() async {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let outboundPostGate = RuntimeEnvelopeOutboundPostGate(paneEventBus: bus)
        let channel = makeChannel(
            paneEventBus: bus,
            reporter: reporter,
            outboundPost: outboundPostGate.post
        )

        emitBell(on: channel)
        await outboundPostGate.waitUntilPostEntered()
        emitBell(on: channel)
        #expect(reporter.snapshot().runtimeChannelOutboundPendingCount == 2)

        channel.finishSubscribers()
        #expect(reporter.snapshot().runtimeChannelOutboundPendingCount == 2)

        await outboundPostGate.allowPostToFinish()
        await channel.finishAndJoinOutboundDelivery()
        let completedSnapshot = reporter.snapshot()
        #expect(completedSnapshot.runtimeChannelOutboundPendingCount == 0)
        #expect(completedSnapshot.runtimeChannelRetiredUndeliveredCount == 1)
    }

    @Test("outbound completion observes the accepted post's outcome and retirement", arguments: [0, 1])
    func outboundCompletionObservesAcceptedPostAndRetirement(bufferedEnvelopeCount: Int) async throws {
        try await proveReplyDependsOnStep(
            makeScenario: {
                let fixture = OwnedChannelCompletionFixture(bufferedEnvelopeCount: bufferedEnvelopeCount)
                return HeldReplyScenario(
                    context: fixture,
                    step: fixture.postCompletion,
                    produceReply: { @MainActor in await fixture.finishAfterAcceptedPost() }
                )
            },
            replyReportsFailure: { reply, _ in
                #expect(reply.snapshot.runtimeChannelOutboundPendingCount == 0)
                #expect(reply.snapshot.runtimeChannelRetiredUndeliveredCount == UInt64(bufferedEnvelopeCount))
                #expect(reply.didObserveEntryCancellation)
                #expect(reply.didObserveOutcomeCancellation)
                return reply.outcome == .failed
            },
            assertCommitted: { reply, fixture in
                #expect(reply.outcome == .posted)
                #expect(reply.snapshot.runtimeChannelOutboundPendingCount == 0)
                #expect(reply.snapshot.runtimeChannelRetiredUndeliveredCount == UInt64(bufferedEnvelopeCount))
                #expect(reply.snapshot.totalPendingCount == 0)
                #expect(reply.didObserveEntryCancellation)
                #expect(reply.didObserveOutcomeCancellation)
                await fixture.channel.finishAndJoinOutboundDelivery()
                await fixture.channel.finishAndJoinOutboundDelivery()
                #expect(fixture.reporter.snapshot() == reply.snapshot)
            }
        )
    }

    private func makeChannel(
        paneEventBus: EventBus<RuntimeEnvelope>,
        reporter: RuntimeDeliveryPerformanceReporter,
        outboundPost: @escaping PaneRuntimeEventChannel.OutboundPost
    ) -> PaneRuntimeEventChannel {
        PaneRuntimeEventChannel(
            paneEventBus: paneEventBus,
            performanceReporter: reporter,
            outboundPost: outboundPost
        )
    }

    private func emitBell(on channel: PaneRuntimeEventChannel) {
        let paneId = PaneId.generateUUIDv7()
        channel.emit(
            paneId: paneId,
            metadata: PaneMetadata(
                paneId: paneId,
                contentType: .terminal,
                title: "Test"
            ),
            paneKind: .terminal,
            event: .terminal(.bellRang),
            persistForReplay: false
        )
    }
}

private actor RuntimeEnvelopeOutboundPostGate {
    private let paneEventBus: EventBus<RuntimeEnvelope>
    private var postEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var postReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasPostEntered = false
    private var isPostReleased = false

    init(paneEventBus: EventBus<RuntimeEnvelope>) {
        self.paneEventBus = paneEventBus
    }

    func post(_ envelope: RuntimeEnvelope) async -> EventBus<RuntimeEnvelope>.PostResult {
        if !hasPostEntered {
            hasPostEntered = true
            let entryWaiters = postEntryWaiters
            postEntryWaiters.removeAll(keepingCapacity: false)
            for entryWaiter in entryWaiters {
                entryWaiter.resume()
            }

            if !isPostReleased {
                await withCheckedContinuation { continuation in
                    postReleaseWaiters.append(continuation)
                }
            }
        }

        return await paneEventBus.post(envelope)
    }

    func waitUntilPostEntered() async {
        guard !hasPostEntered else { return }
        await withCheckedContinuation { continuation in
            postEntryWaiters.append(continuation)
        }
    }

    func allowPostToFinish() {
        guard !isPostReleased else { return }
        isPostReleased = true
        let releaseWaiters = postReleaseWaiters
        postReleaseWaiters.removeAll(keepingCapacity: false)
        for releaseWaiter in releaseWaiters {
            releaseWaiter.resume()
        }
    }
}

private enum OwnedChannelPostOutcome: Sendable, Equatable {
    case pending
    case posted
    case failed
}

private struct OwnedChannelCompletionReply: Sendable {
    let outcome: OwnedChannelPostOutcome
    let snapshot: RuntimeDeliveryPerformanceSnapshot
    let didObserveEntryCancellation: Bool
    let didObserveOutcomeCancellation: Bool
}

private final class OwnedChannelPostOutcomeRecorder: Sendable {
    private let state = Mutex(OwnedChannelPostOutcome.pending)

    func record(_ outcome: OwnedChannelPostOutcome) {
        state.withLock { $0 = outcome }
    }

    func snapshot() -> OwnedChannelPostOutcome {
        state.withLock { $0 }
    }
}

@MainActor
private final class OwnedChannelCompletionFixture {
    let channel: PaneRuntimeEventChannel
    let reporter: RuntimeDeliveryPerformanceReporter
    let postCompletion: HeldStep<RuntimeEnvelope>
    private let postEntry: HeldStep<RuntimeEnvelope>
    private let outcomeRecorder: OwnedChannelPostOutcomeRecorder
    private let bufferedEnvelopeCount: Int
    private let paneID = PaneId.generateUUIDv7()

    init(bufferedEnvelopeCount: Int) {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let postEntry = HeldStep<RuntimeEnvelope>(
            "accepted outbound post before channel finish", cancellation: .holdThroughCancellation)
        let postCompletion = HeldStep<RuntimeEnvelope>(
            "accepted outbound post outcome after channel finish", cancellation: .holdThroughCancellation)
        let outcomeRecorder = OwnedChannelPostOutcomeRecorder()
        self.reporter = reporter
        self.postEntry = postEntry
        self.postCompletion = postCompletion
        self.outcomeRecorder = outcomeRecorder
        self.bufferedEnvelopeCount = bufferedEnvelopeCount
        self.channel = PaneRuntimeEventChannel(
            paneEventBus: bus,
            performanceReporter: reporter,
            outboundPost: { envelope in
                do {
                    try await postEntry.arrive(envelope)
                    try await postCompletion.arrive(envelope)
                    let result = await bus.post(envelope)
                    outcomeRecorder.record(.posted)
                    return result
                } catch {
                    outcomeRecorder.record(.failed)
                    return .init(subscriberCount: 0, droppedCount: 0, terminatedCount: 0)
                }
            }
        )
    }

    func finishAfterAcceptedPost() async -> OwnedChannelCompletionReply {
        emitBell()
        do {
            _ = try await postEntry.firstArrival()
        } catch {
            postEntry.retire()
            postCompletion.retire()
            await channel.finishAndJoinOutboundDelivery()
            return completionReply(outcome: .failed)
        }
        for _ in 0..<bufferedEnvelopeCount { emitBell() }
        // Finish stays synchronous. Release the entry only after cancellation,
        // so the dependency proof observes the post's outcome after finish.
        channel.finishSubscribers()
        postEntry.release()
        await channel.finishAndJoinOutboundDelivery()
        return completionReply(outcome: outcomeRecorder.snapshot())
    }

    private func completionReply(outcome: OwnedChannelPostOutcome) -> OwnedChannelCompletionReply {
        OwnedChannelCompletionReply(
            outcome: outcome,
            snapshot: reporter.snapshot(),
            didObserveEntryCancellation: postEntry.hasObservedCancellation,
            didObserveOutcomeCancellation: postCompletion.hasObservedCancellation
        )
    }

    private func emitBell() {
        channel.emit(
            paneId: paneID,
            metadata: PaneMetadata(paneId: paneID, contentType: .terminal, title: "Owned channel completion"),
            paneKind: .terminal,
            event: .terminal(.bellRang),
            persistForReplay: false
        )
    }
}
