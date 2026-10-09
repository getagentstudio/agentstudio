import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("TerminalActivityRouter", .serialized)
struct TerminalActivityRouterTests {
    private final class MillisecondBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64

        init(_ value: Int64) {
            self.value = value
        }

        func set(_ value: Int64) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class SecondSleepFailsClock: Clock, @unchecked Sendable {
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

        private enum SleepFailure: Error {
            case injected
        }

        private let lock = NSLock()
        private var sleepCount = 0
        private var pendingContinuations: [Int: UnsafeContinuation<Void, Error>] = [:]

        var now: Instant { .init(nanoseconds: 0) }
        var minimumResolution: Duration { .zero }

        var startedSleepCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return sleepCount
        }

        func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
            let generation = nextSleepGeneration()
            if generation == 2 {
                throw SleepFailure.injected
            }

            try await withTaskCancellationHandler {
                try await withUnsafeThrowingContinuation { continuation in
                    storeContinuation(continuation, for: generation)
                }
            } onCancel: {
                cancel(generation)
            }
        }

        private func nextSleepGeneration() -> Int {
            lock.lock()
            defer { lock.unlock() }
            sleepCount += 1
            return sleepCount
        }

        private func storeContinuation(_ continuation: UnsafeContinuation<Void, Error>, for generation: Int) {
            lock.lock()
            pendingContinuations[generation] = continuation
            lock.unlock()
        }

        private func cancel(_ generation: Int) {
            lock.lock()
            let continuation = pendingContinuations.removeValue(forKey: generation)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    @Test("consumes pane terminal events from runtime bus into activity atom")
    func consumesPaneTerminalEventsFromRuntimeBusIntoActivityAtom() async throws {
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom, factSink: factSource.sink)
        let paneId = PaneId.generateUUIDv7()

        do {
            await router.start()
            await bus.waitForSubscriberRegistration(subscriberName: "TerminalActivityRouter")
            let eventID = UUIDv7.generate()
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.progressReportUpdated(ProgressState(kind: .set, percent: 25))),
                        paneId: paneId,
                        paneKind: .terminal,
                        eventId: eventID
                    )
                )
            )

            _ = try await facts.expectRuntimeEnvelopeHandled(paneID: paneId.uuid, eventID: eventID)
            #expect(atom.snapshot(for: paneId.uuid)?.progress == .reported(ProgressState(kind: .set, percent: 25)))

            await router.stop()
            try await facts.finish()
        } catch {
            await router.stop()
            try? await facts.finish()
            throw error
        }
    }

    @Test("typed activity aggregate is debounced into one derived settled fact")
    func typedActivityAggregateIsDebouncedIntoOneDerivedSettledFact() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), clock: clock, factSink: deadlines.sink)
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            projector: projector,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock,
            factSink: factSource.sink
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            _ = try await facts.startRouter(router)
            await ingestActivity(
                paneId: paneId,
                totals: [100, 120, 140],
                context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
                through: router
            )
            let deadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)
            _ = try await deadlines.fire(deadline)

            _ = try await events.expectNextUnseenActivity(paneID: paneId.uuid, windowID: deadline.scope.windowID)
            let noAdditionalSettles = await events.mark(paneId.uuid)

            let stopScope = try await facts.stopRouter(router)
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noAdditionalSettles, stopScope: stopScope)
            try await deadlines.finish()
            try await events.finish()
            try await facts.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            try? await facts.finish()
            throw error
        }
    }

    @Test("unseen settlement records the pane's activity status regardless of downstream suppression")
    func unseenSettlementRecordsPaneActivityStatus() async throws {
        // The router must publish the settled activity's last output line unconditionally: it has
        // no knowledge of InboxNotificationRouter/InboxPromoter's later suppression decisions for
        // the derived envelope it posts, so this recording call is the one place that guarantees a
        // pane's own sidebar row learns its latest real content either way.
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), clock: clock, factSink: deadlines.sink)
        final class RecordedCallBox: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls: [(paneId: UUID, lastOutputLine: String?)] = []

            func record(paneId: UUID, lastOutputLine: String?) {
                lock.lock()
                calls.append((paneId, lastOutputLine))
                lock.unlock()
            }
        }
        let recordedCalls = RecordedCallBox()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            projector: projector,
            surfaceIDForPaneID: { $0 },
            lastOutputLineReader: { _ in .value("seam-live-proof") },
            recordSettledActivityStatus: { paneId, lastOutputLine in
                recordedCalls.record(paneId: paneId, lastOutputLine: lastOutputLine)
            },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock,
            factSink: factSource.sink
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            _ = try await facts.startRouter(router)
            await ingestActivity(
                paneId: paneId,
                totals: [100, 120, 140],
                context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
                through: router
            )
            let deadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)
            _ = try await deadlines.fire(deadline)

            _ = try await events.expectNextUnseenActivity(paneID: paneId.uuid, windowID: deadline.scope.windowID)
            let noAdditionalSettles = await events.mark(paneId.uuid)

            #expect(recordedCalls.calls.count == 1)
            #expect(recordedCalls.calls.first?.paneId == paneId.uuid)
            #expect(recordedCalls.calls.first?.lastOutputLine == "seam-live-proof")

            let stopScope = try await facts.stopRouter(router)
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noAdditionalSettles, stopScope: stopScope)
            try await deadlines.finish()
            try await events.finish()
            try await facts.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            try? await facts.finish()
            throw error
        }
    }

    @Test("ordered commandFinished settles before and independently of lossy bus delivery")
    func orderedCommandFinishedSettlesIndependentlyOfBusDelivery() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        final class RecordedCallBox: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls: [(paneId: UUID, lastOutputLine: String?)] = []

            func record(paneId: UUID, lastOutputLine: String?) {
                lock.lock()
                calls.append((paneId, lastOutputLine))
                lock.unlock()
            }
        }
        let recordedCalls = RecordedCallBox()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            surfaceIDForPaneID: { $0 },
            isPaneCurrentlyAttended: { _ in true },
            lastOutputLineReader: { _ in .value("echo-command-output") },
            recordSettledActivityStatus: { paneId, lastOutputLine in
                recordedCalls.record(paneId: paneId, lastOutputLine: lastOutputLine)
            },
            factSink: factSource.sink
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            _ = try await facts.startRouter(router)
            await router.consumeTerminalActivityInput(
                .orderedControl(
                    surfaceID: paneId.uuid,
                    paneID: paneId.uuid,
                    precedingAggregate: nil,
                    control: .commandFinished
                )
            )
            let settled = try await events.expectNextUnseenActivity(paneID: paneId.uuid)
            #expect(settled.activity.lastOutputLine == "echo-command-output")
            #expect(settled.activity.rowsAdded == 0)
            let noAdditionalSettles = await events.mark(paneId.uuid)

            // The ordinary semantic fact remains available on the bus, but activity settlement does
            // not consume it a second time or depend on this subscriber path.
            let eventID = UUIDv7.generate()
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.commandFinished(exitCode: 0, duration: 50_000_000)),
                        paneId: paneId,
                        paneKind: .terminal,
                        eventId: eventID
                    )
                )
            )

            _ = try await facts.expectRuntimeEnvelopeHandled(paneID: paneId.uuid, eventID: eventID)

            #expect(recordedCalls.calls.count == 1)
            #expect(recordedCalls.calls.first?.paneId == paneId.uuid)
            #expect(recordedCalls.calls.first?.lastOutputLine == "echo-command-output")

            let stopScope = try await facts.stopRouter(router)
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noAdditionalSettles, stopScope: stopScope)
            try await facts.finish()
            try await events.finish()
        } catch {
            await router.stop()
            try? await facts.finish()
            try? await events.finish()
            throw error
        }
    }

    @Test("attended typed activity updates compact state without unseen settlement")
    func attendedTypedActivityUpdatesCompactStateWithoutUnseenSettlement() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), clock: clock, factSink: deadlines.sink)
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            projector: projector,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock,
            factSink: factSource.sink
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            _ = try await facts.startRouter(router)
            let noSettleFrom = await events.mark(paneId.uuid)
            await ingestActivity(
                paneId: paneId,
                totals: [100, 140],
                context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30),
                through: router
            )
            #expect(atom.snapshot(for: paneId.uuid)?.scrollbarState?.total == 140)
            // The awaited ingest made the scheduling decision; an attended pane schedules no window.
            // `#require` stops here on a regression instead of waiting on the timer it scheduled.
            try #require(await projector.scheduledTimerCount == 0)
            #expect(clock.pendingSleepCount == 0)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)

            let stopScope = try await facts.stopRouter(router)
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noSettleFrom, stopScope: stopScope)
            try await deadlines.finish()
            try await events.finish()
            try await facts.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            try? await facts.finish()
            throw error
        }
    }

    @Test("stop cancels projector quiet timers without publishing stale activity")
    func stopCancelsProjectorQuietTimersWithoutPublishingStaleActivity() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let clock = TestPushClock()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), clock: clock, factSink: deadlines.sink)
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: TerminalActivityAtom(outputBurstThreshold: 30),
            projector: projector,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock,
            factSink: factSource.sink
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            _ = try await facts.startRouter(router)
            let noSettleFrom = await events.mark(paneId.uuid)
            await ingestActivity(
                paneId: paneId,
                totals: [100, 140],
                context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
                through: router
            )
            let deadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)
            let stopScope = try await facts.stopRouter(router)
            _ = try await deadlines.expectDisposition(for: deadline, .cancelled)
            await clock.waitForPendingSleepCount(exactly: 0)
            clock.advance(by: .milliseconds(750))

            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noSettleFrom, stopScope: stopScope)
            try await deadlines.finish()
            try await events.finish()
            try await facts.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            try? await facts.finish()
            throw error
        }
    }

    @Test("later typed aggregate replaces the earlier quiet timer")
    func laterTypedAggregateReplacesEarlierQuietTimer() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let clock = TestPushClock()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), clock: clock, factSink: deadlines.sink)
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: TerminalActivityAtom(outputBurstThreshold: 30),
            projector: projector,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock,
            factSink: factSource.sink
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            _ = try await facts.startRouter(router)
            await ingestActivity(
                paneId: paneId,
                totals: [100],
                context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
                through: router
            )
            let firstDeadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)
            await ingestActivity(
                paneId: paneId,
                totals: [100, 140],
                context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
                through: router,
                startedAtMilliseconds: 1300
            )
            _ = try await deadlines.expectDisposition(for: firstDeadline, .superseded)
            let deadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await deadlines.fire(deadline)
            _ = try await events.expectNextUnseenActivity(paneID: paneId.uuid, windowID: deadline.scope.windowID)
            let noAdditionalSettles = await events.mark(paneId.uuid)

            let stopScope = try await facts.stopRouter(router)
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noAdditionalSettles, stopScope: stopScope)
            try await deadlines.finish()
            try await events.finish()
            try await facts.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            try? await facts.finish()
            throw error
        }
    }

    @Test("decreasing typed totals clamp growth to zero")
    func decreasingTypedTotalsClampGrowthToZero() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), clock: clock, factSink: deadlines.sink)
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            projector: projector,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock,
            factSink: factSource.sink
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            _ = try await facts.startRouter(router)
            let noSettleFrom = await events.mark(paneId.uuid)
            await ingestActivity(
                paneId: paneId,
                totals: [100, 80],
                context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
                through: router
            )
            #expect(atom.snapshot(for: paneId.uuid)?.outputBurst == .quiet(lastTotal: 80))
            let deadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)
            _ = try await deadlines.fire(deadline)

            let stopScope = try await facts.stopRouter(router)
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noSettleFrom, stopScope: stopScope)
            try await deadlines.finish()
            try await events.finish()
            try await facts.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            try? await facts.finish()
            throw error
        }
    }

    @Test("start is idempotent and does not double-consume events")
    func startIsIdempotentAndDoesNotDoubleConsumeEvents() async throws {
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom()
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom, factSink: factSource.sink)
        let paneId = PaneId.generateUUIDv7()

        do {
            await router.start()
            await router.start()
            let eventID = UUIDv7.generate()
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.openURLRequested(url: "https://example.com", kind: .text)),
                        paneId: paneId,
                        paneKind: .terminal,
                        eventId: eventID
                    )
                )
            )

            _ = try await facts.expectRuntimeEnvelopeHandled(paneID: paneId.uuid, eventID: eventID)
            #expect(atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 1)

            await router.stop()
            try await facts.finish()
        } catch {
            await router.stop()
            try? await facts.finish()
            throw error
        }
    }

    @Test("stop prevents later runtime events from mutating activity")
    func stopPreventsLaterRuntimeEventsFromMutatingActivity() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom()
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom, factSink: factSource.sink)
        let paneId = PaneId.generateUUIDv7()

        do {
            _ = try await facts.startRouter(router)
            _ = try await facts.stopRouter(router)
            // The owner's stop completion follows cancellation and await of busTask.
            // No consumer survives that boundary to mutate state for a later post.
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.progressReportUpdated(ProgressState(kind: .set, percent: 99))),
                        paneId: paneId,
                        paneKind: .terminal
                    )
                )
            )

            #expect(atom.snapshot(for: paneId.uuid) == nil)
            try await facts.finish()
        } catch {
            await router.stop()
            try? await facts.finish()
            throw error
        }
    }

    @Test("non-terminal pane envelopes are ignored")
    func nonTerminalPaneEnvelopesAreIgnored() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom()
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom, factSink: factSource.sink)
        let paneId = PaneId.generateUUIDv7()
        let sentinelPaneId = PaneId.generateUUIDv7()
        let sentinelEventID = UUIDv7.generate()

        do {
            _ = try await facts.startRouter(router)
            _ = await bus.post(
                .pane(
                    .test(
                        event: .browser(.pageLoaded(url: URL(fileURLWithPath: "/tmp/index.html"))),
                        paneId: paneId,
                        paneKind: .browser
                    )
                )
            )
            // One ordered subscriber must handle this later envelope before the
            // browser assertion; filtering the browser requires no handler receipt.
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.progressReportUpdated(ProgressState(kind: .set, percent: 99))),
                        paneId: sentinelPaneId,
                        paneKind: .terminal,
                        eventId: sentinelEventID
                    )
                )
            )
            _ = try await facts.expectRuntimeEnvelopeHandled(paneID: sentinelPaneId.uuid, eventID: sentinelEventID)
            #expect(
                atom.snapshot(for: sentinelPaneId.uuid)?.progress == .reported(ProgressState(kind: .set, percent: 99)))
            #expect(atom.snapshot(for: paneId.uuid) == nil)
            _ = try await facts.stopRouter(router)
            try await facts.finish()
        } catch {
            await router.stop()
            try? await facts.finish()
            throw error
        }
    }

    private func ingestActivity(
        paneId: PaneId,
        totals: [Int],
        context: TerminalActivityProjectionContext,
        through router: TerminalActivityRouter,
        startedAtMilliseconds: Int64 = 1000
    ) async {
        guard let firstTotal = totals.first, let latestTotal = totals.last else { return }
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(top: 0, bottom: 10, total: firstTotal),
            observedAtMilliseconds: startedAtMilliseconds
        )
        for (index, totalRows) in totals.dropFirst().enumerated() {
            aggregate.merge(
                state: ScrollbarState(top: 0, bottom: 10, total: totalRows),
                observedAtMilliseconds: startedAtMilliseconds + Int64((index + 1) * 100)
            )
        }
        await router.consumeTerminalActivityInput(
            .aggregate(
                surfaceID: paneId.uuid,
                paneID: paneId.uuid,
                input: TerminalActivityAggregateInput(
                    aggregate: aggregate,
                    latestState: ScrollbarState(top: 0, bottom: 10, total: latestTotal),
                    context: context
                )
            )
        )
    }

    private func makeAttendedPaneDerived(activePaneId: UUID) -> AttendedPaneDerived {
        let atoms = makeInstalledTestCoreAtoms()
        let arrangement = PaneArrangement(
            name: "Default",
            isDefault: true,
            layout: Layout(paneId: activePaneId),
            activePaneId: activePaneId
        )
        let tab = Tab(
            name: "Tab",
            allPaneIds: [activePaneId],
            arrangements: [arrangement],
            activeArrangementId: arrangement.id
        )
        let windowId = UUID()
        atoms.windowLifecycle.recordWindowRegistered(windowId)
        atoms.windowLifecycle.recordWindowBecameKey(windowId)
        atoms.workspaceTabLayout.appendTab(tab)
        atoms.workspaceTabLayout.setActiveTab(tab.id)
        return atoms.attendedPane
    }

}
