import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

@MainActor
@Suite("TerminalRuntime outbound completion", .serialized)
struct TerminalRuntimeOutboundCompletionTests {
    @Test("ordinary shutdown leaves accepted runtime delivery pending until join")
    func ordinaryShutdownThenJoinWaitsForAcceptedOutboundPost() async throws {
        let fixtureStore = TerminalRuntimeOutboundCompletionFixtureStore()

        do {
            try await proveReplyDependsOnStep(
                makeScenario: {
                    let fixture = TerminalRuntimeOutboundCompletionFixture()
                    await fixtureStore.append(fixture)
                    return HeldReplyScenario(
                        context: fixture.preJoinSnapshot,
                        step: fixture.postOutcome,
                        produceReply: { @MainActor in
                            await fixture.finishAfterOrdinaryShutdown()
                        }
                    )
                },
                replyReportsFailure: { reply, beforeJoin in
                    guard let afterShutdown = beforeJoin.snapshot() else { return false }
                    return reply.postOutcome == .failed
                        && afterShutdown.runtimeChannelOutboundPendingCount == 2
                        && afterShutdown.runtimeChannelRetiredUndeliveredCount == 0
                        && reply.snapshotAfterJoin.runtimeChannelOutboundPendingCount == 0
                        && reply.snapshotAfterJoin.runtimeChannelRetiredUndeliveredCount == 1
                },
                assertCommitted: { reply, beforeJoin in
                    #expect(reply.postOutcome == .posted)
                    #expect(reply.didEmitBell)
                    #expect(reply.didEmitReadOnlyChange)
                    #expect(reply.replayEventCount == 2)
                    #expect(reply.replayNextSequence == 2)
                    #expect(reply.postResult?.subscriberCount == 0)
                    #expect(reply.postResult?.droppedCount == 0)
                    #expect(reply.postResult?.terminatedCount == 0)

                    let afterShutdown = beforeJoin.snapshot()
                    #expect(afterShutdown?.runtimeChannelOutboundPendingCount == 2)
                    #expect(afterShutdown?.runtimeChannelRetiredUndeliveredCount == 0)
                    #expect(afterShutdown?.totalPendingCount == 2)

                    #expect(reply.snapshotAfterJoin.runtimeChannelOutboundPendingCount == 0)
                    #expect(reply.snapshotAfterJoin.runtimeChannelRetiredUndeliveredCount == 1)
                    #expect(reply.snapshotAfterJoin.totalPendingCount == 0)
                }
            )
        } catch {
            for fixture in await fixtureStore.all() {
                await fixture.closeAndJoin()
            }
            throw error
        }

        for fixture in await fixtureStore.all() {
            await fixture.closeAndJoin()
        }
    }

}

private enum RuntimeOutboundPostOutcome: Sendable, Equatable {
    case pending
    case posted
    case failed
}

private struct RuntimeOutboundPostObservation: Sendable {
    let outcome: RuntimeOutboundPostOutcome
    let result: EventBus<RuntimeEnvelope>.PostResult?
}

private struct RuntimeOutboundPostObservationState: Sendable {
    var outcome = RuntimeOutboundPostOutcome.pending
    var result: EventBus<RuntimeEnvelope>.PostResult?
}

private final class RuntimeOutboundPostObservationRecorder: Sendable {
    private let state = Mutex(RuntimeOutboundPostObservationState())

    func recordPosted(_ result: EventBus<RuntimeEnvelope>.PostResult) {
        state.withLock { state in
            state.outcome = .posted
            state.result = result
        }
    }

    func recordFailure(_ result: EventBus<RuntimeEnvelope>.PostResult) {
        state.withLock { state in
            state.outcome = .failed
            state.result = result
        }
    }

    func snapshot() -> RuntimeOutboundPostObservation {
        state.withLock { state in
            RuntimeOutboundPostObservation(outcome: state.outcome, result: state.result)
        }
    }
}

private struct RuntimeOutboundCompletionReply: Sendable {
    let postOutcome: RuntimeOutboundPostOutcome
    let postResult: EventBus<RuntimeEnvelope>.PostResult?
    let snapshotAfterJoin: RuntimeDeliveryPerformanceSnapshot
    let didEmitBell: Bool
    let didEmitReadOnlyChange: Bool
    let replayEventCount: Int
    let replayNextSequence: UInt64
}

private final class TerminalRuntimeOutboundSnapshotRecorder: Sendable {
    private let state = Mutex<RuntimeDeliveryPerformanceSnapshot?>(nil)

    func record(_ snapshot: RuntimeDeliveryPerformanceSnapshot) {
        state.withLock { $0 = snapshot }
    }

    func snapshot() -> RuntimeDeliveryPerformanceSnapshot? {
        state.withLock { $0 }
    }
}

private actor TerminalRuntimeOutboundCompletionFixtureStore {
    private var fixtures: [TerminalRuntimeOutboundCompletionFixture] = []

    func append(_ fixture: TerminalRuntimeOutboundCompletionFixture) {
        fixtures.append(fixture)
    }

    func all() -> [TerminalRuntimeOutboundCompletionFixture] {
        fixtures
    }
}

@MainActor
private final class TerminalRuntimeOutboundCompletionFixture {
    let reporter: RuntimeDeliveryPerformanceReporter
    let postOutcome: HeldStep<RuntimeEnvelope>
    let preJoinSnapshot: TerminalRuntimeOutboundSnapshotRecorder

    private let runtime: TerminalRuntime
    private let postEntry: HeldStep<RuntimeEnvelope>
    private let postObservation: RuntimeOutboundPostObservationRecorder

    init() {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let paneEventBus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let postEntry = HeldStep<RuntimeEnvelope>(
            "TerminalRuntime accepted outbound entry", cancellation: .holdThroughCancellation)
        let postOutcome = HeldStep<RuntimeEnvelope>(
            "TerminalRuntime outbound post outcome after shutdown", cancellation: .holdThroughCancellation)
        let postObservation = RuntimeOutboundPostObservationRecorder()
        let preJoinSnapshot = TerminalRuntimeOutboundSnapshotRecorder()
        let outboundPost: PaneRuntimeEventChannel.OutboundPost = { envelope in
            do {
                try await postEntry.arrive(envelope)
                try await postOutcome.arrive(envelope)
                let result = await paneEventBus.post(envelope)
                postObservation.recordPosted(result)
                return result
            } catch {
                let result = EventBus<RuntimeEnvelope>.PostResult(
                    subscriberCount: 0,
                    droppedCount: 0,
                    terminatedCount: 0
                )
                postObservation.recordFailure(result)
                return result
            }
        }

        self.reporter = reporter
        self.postEntry = postEntry
        self.postOutcome = postOutcome
        self.postObservation = postObservation
        self.preJoinSnapshot = preJoinSnapshot
        self.runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "TerminalRuntime outbound completion"),
            paneEventBus: paneEventBus,
            performanceReporter: reporter,
            outboundPost: outboundPost,
            surfaceCommandDispatcher: NoOpTerminalSurfaceCommandDispatcher()
        )
    }

    func finishAfterOrdinaryShutdown() async -> RuntimeOutboundCompletionReply {
        runtime.transitionToReady()
        runtime.handleGhosttyEvent(.bellRang)

        let firstEnvelope: RuntimeEnvelope
        do {
            firstEnvelope = try await postEntry.firstArrival()
        } catch {
            await closeAndJoin()
            let snapshotAfterFirstJoin = reporter.snapshot()
            let observationAfterFirstJoin = postObservation.snapshot()
            return RuntimeOutboundCompletionReply(
                postOutcome: observationAfterFirstJoin.outcome,
                postResult: observationAfterFirstJoin.result,
                snapshotAfterJoin: snapshotAfterFirstJoin,
                didEmitBell: false,
                didEmitReadOnlyChange: false,
                replayEventCount: 0,
                replayNextSequence: 0
            )
        }

        let didEmitBell = Self.isBellRang(firstEnvelope)
        // Keep a second real event buffered behind the held accepted post.
        runtime.handleGhosttyEvent(.readOnlyChanged(true))
        let replay = await runtime.eventsSince(seq: 0)
        _ = await runtime.shutdown(timeout: .seconds(1))
        preJoinSnapshot.record(reporter.snapshot())

        // The accepted post remains held while synchronous shutdown cancels its consumer.
        postEntry.release()
        await runtime.finishAndJoinOutboundDelivery()
        let snapshotAfterFirstJoin = reporter.snapshot()
        let observationAfterFirstJoin = postObservation.snapshot()
        let reply = RuntimeOutboundCompletionReply(
            postOutcome: observationAfterFirstJoin.outcome,
            postResult: observationAfterFirstJoin.result,
            snapshotAfterJoin: snapshotAfterFirstJoin,
            didEmitBell: didEmitBell,
            didEmitReadOnlyChange: runtime.isReadOnly,
            replayEventCount: replay.events.count,
            replayNextSequence: replay.nextSeq
        )

        // Repeated completion cannot repair an early snapshot: reply fields are cached above.
        await runtime.finishAndJoinOutboundDelivery()
        return reply
    }

    func closeAndJoin() async {
        postEntry.release()
        postOutcome.release()
        _ = await runtime.shutdown(timeout: .seconds(1))
        await runtime.finishAndJoinOutboundDelivery()
    }

    private static func isBellRang(_ envelope: RuntimeEnvelope) -> Bool {
        guard
            case .pane(let paneEnvelope) = envelope,
            case .terminal(.bellRang) = paneEnvelope.event
        else {
            return false
        }
        return true
    }
}

@MainActor
private final class NoOpTerminalSurfaceCommandDispatcher: TerminalSurfaceCommandDispatching {
    func sendInput(_: String, toPaneId _: UUID) -> Result<Void, SurfaceError> {
        .success(())
    }

    func clearScrollback(forPaneId _: UUID) -> Result<Void, SurfaceError> {
        .success(())
    }

    func scrollToBottom(forPaneId _: UUID) -> Result<Void, SurfaceError> {
        .success(())
    }

    func scrollPageFractional(fraction _: Double, forPaneId _: UUID) -> Result<Void, SurfaceError> {
        .success(())
    }

    func jumpToPrompt(delta _: Int, forPaneId _: UUID) -> Result<Void, SurfaceError> {
        .success(())
    }
}
