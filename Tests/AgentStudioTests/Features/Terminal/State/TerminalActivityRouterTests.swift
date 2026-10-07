import AgentStudioCore
import AgentStudioInfrastructure
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

    private struct TraceRecordFixture: Decodable {
        let body: String
        let traceID: String?
        let attributes: [String: TraceAttributeFixture]

        enum CodingKeys: String, CodingKey {
            case attributes
            case body
            case traceID = "trace_id"
        }
    }

    private enum TraceAttributeFixture: Decodable, Equatable {
        case int(Int)
        case string(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .int(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .other
            }
        }
    }

    @Test("consumes pane terminal events from runtime bus into activity atom")
    func consumesPaneTerminalEventsFromRuntimeBusIntoActivityAtom() async {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom)
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await waitForBusSubscriberCount(bus, atLeast: 1)
        _ = await bus.post(
            .pane(
                .test(
                    event: .terminal(.progressReportUpdated(ProgressState(kind: .set, percent: 25))),
                    paneId: paneId,
                    paneKind: .terminal
                )
            )
        )

        await assertEventuallyMain("terminal activity router should update progress") {
            atom.snapshot(for: paneId.uuid)?.progress == .reported(ProgressState(kind: .set, percent: 25))
        }

        await router.stop()
    }

    /// A6 (advisor review 2026-10-01; PD rev 21 item 5, Lead decision: push,
    /// not pull): proves the new `onFirstRender` callback actually fires
    /// from a real `.firstRender` outcome -- the same raw fact
    /// `consumeAggregateState` already computes and `consumeProjectionOutcome`'s
    /// existing `.firstRender` arm already forwards to `startupTraceRecorder`.
    /// No new event type or bus case: `.firstRender` never posts to the
    /// bus, so this asserts the callback directly instead of waiting on a
    /// `RecordingSubscriber` envelope.
    @Test("a real first-render outcome notifies the injected onFirstRender callback")
    func realFirstRenderOutcomeNotifiesOnFirstRenderCallback() async {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        final class FirstRenderCallbackRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var notifiedPaneIDs: [UUID] = []

            func record(_ paneID: UUID) {
                lock.lock()
                notifiedPaneIDs.append(paneID)
                lock.unlock()
            }
        }
        let recorder = FirstRenderCallbackRecorder()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            onFirstRender: { paneID in recorder.record(paneID) },
            surfaceIDForPaneID: { $0 }
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        // `consumeTerminalActivityInput` -> `projector.ingest` -> `emit` ->
        // `outcomeSink` -> `consumeProjectionOutcomes` is one unbroken
        // `await` chain, no detached task in between -- `onFirstRender` has
        // already been called, synchronously, by the time this returns.
        await ingestActivity(
            paneId: paneId,
            totals: [10],
            context: TerminalActivityProjectionContext(
                isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
            through: router
        )

        #expect(recorder.notifiedPaneIDs == [paneId.uuid])
        await router.stop()
    }

    @Test("records terminal activity trace records when runtime tracing is enabled")
    func recordsTerminalActivityTraceRecordsWhenRuntimeTracingIsEnabled() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let traceDirectory = temporaryTraceDirectoryURL()
        let traceFixture = makeTraceRuntime(
            traceDirectory: traceDirectory,
            traceName: "terminal-activity",
            traceTags: "terminal.activity",
            processIdentifier: 246,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom, traceRuntime: traceRuntime)
        let paneId = PaneId.generateUUIDv7()
        let correlationId = UUID()

        await router.start()
        await waitForBusSubscriberCount(bus, atLeast: 1)
        _ = await bus.post(
            .pane(
                .test(
                    event: .terminal(.openURLRequested(url: "https://example.com/trace", kind: .text)),
                    paneId: paneId,
                    paneKind: .terminal,
                    seq: 7,
                    correlationId: correlationId
                )
            )
        )

        await assertEventuallyMain("terminal activity router should consume before trace drain") {
            atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 1
        }
        await router.stop()

        let outputFileURL = traceFixture.outputFileURL
        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(contents.contains("\"body\":\"terminal.activity.observed\""))
        #expect(contents.contains("\"agentstudio.runtime.event\":\"terminal.openURLRequested\""))
        #expect(contents.contains("\"agentstudio.envelope.seq\":7"))
        #expect(contents.contains("\"agentstudio.pane.id\":\"\(paneId.uuidString)\""))
        #expect(contents.contains("\"agentstudio.envelope.correlation_id\":\"\(correlationId.uuidString)\""))
        #expect(contents.contains("\"agentstudio.session.id\":"))
    }

    @Test("records eventbus delivery summaries for exact terminal facts")
    func recordsEventBusDeliverySummariesForExactTerminalFacts() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let traceDirectory = temporaryTraceDirectoryURL()
        let traceFixture = makeTraceRuntime(
            traceDirectory: traceDirectory,
            traceName: "terminal-activity-eventbus",
            traceTags: "eventbus",
            processIdentifier: 251,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom, traceRuntime: traceRuntime)
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await waitForBusSubscriberCount(bus, atLeast: 1)
        _ = await bus.post(
            .pane(
                .test(
                    event: .terminal(.openURLRequested(url: "https://example.com/eventbus", kind: .text)),
                    paneId: paneId,
                    paneKind: .terminal,
                    seq: 1
                )
            )
        )

        await assertEventuallyMain("terminal activity router should consume before trace drain") {
            atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 1
        }
        await router.stop()

        let outputFileURL = traceFixture.outputFileURL
        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        let records = try traceRecords(in: outputFileURL)
        let deliveryRecords = records.filter { $0.body == "eventbus.deliver" }
        #expect(deliveryRecords.count == 1)
        let deliveryAttributes = try #require(deliveryRecords.first?.attributes)
        #expect(deliveryAttributes["agentstudio.eventbus.consumer"] == .string("TerminalActivityRouter"))
        #expect(deliveryAttributes["agentstudio.eventbus.name"] == .string("paneRuntime"))
        #expect(deliveryAttributes["agentstudio.eventbus.delivery"] == .string("consumed"))
        #expect(deliveryAttributes["agentstudio.runtime.event"] == .string("terminal.openURLRequested"))
        #expect(deliveryAttributes["agentstudio.envelope.seq"] == .int(1))
        #expect(contents.contains("\"agentstudio.eventbus.consumer\":\"TerminalActivityRouter\""))
        #expect(contents.contains("\"agentstudio.eventbus.name\":\"paneRuntime\""))
        #expect(contents.contains("\"agentstudio.eventbus.delivery\":\"consumed\""))
        #expect(contents.contains("\"agentstudio.runtime.event\":\"terminal.openURLRequested\""))
        #expect(contents.contains("\"agentstudio.envelope.seq\":1"))
    }

    @Test("stop drains buffered terminal activity trace records")
    func stopDrainsBufferedTerminalActivityTraceRecords() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let traceDirectory = temporaryTraceDirectoryURL()
        let traceFixture = makeTraceRuntime(
            traceDirectory: traceDirectory,
            traceName: "terminal-activity-drain",
            traceTags: "terminal.activity",
            processIdentifier: 247
        )
        let traceRuntime = traceFixture.runtime
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom, traceRuntime: traceRuntime)
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        _ = await bus.post(
            .pane(
                .test(
                    event: .terminal(.openURLRequested(url: "https://example.com/drain", kind: .text)),
                    paneId: paneId,
                    paneKind: .terminal,
                    seq: 8
                )
            )
        )

        await assertEventuallyMain("terminal activity router should consume before stop") {
            atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 1
        }

        let outputFileURL = traceFixture.outputFileURL
        #expect(FileManager.default.fileExists(atPath: outputFileURL.path) == false)

        await router.stop()

        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(contents.contains("\"body\":\"terminal.activity.observed\""))
        #expect(contents.contains("\"agentstudio.envelope.seq\":8"))
    }

    @Test("terminal activity trace records preserve envelope arrival order")
    func terminalActivityTraceRecordsPreserveEnvelopeArrivalOrder() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let traceDirectory = temporaryTraceDirectoryURL()
        let traceFixture = makeTraceRuntime(
            traceDirectory: traceDirectory,
            traceName: "terminal-activity-order",
            traceTags: "terminal.activity",
            processIdentifier: 248
        )
        let traceRuntime = traceFixture.runtime
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom, traceRuntime: traceRuntime)
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        for sequence in 1...5 {
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.openURLRequested(url: "https://example.com/\(sequence)", kind: .text)),
                        paneId: paneId,
                        paneKind: .terminal,
                        seq: UInt64(sequence)
                    )
                )
            )
        }

        await assertEventuallyMain("terminal activity router should consume all URL requests") {
            atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 5
        }

        await router.stop()

        let outputFileURL = traceFixture.outputFileURL
        let sequences = try traceEnvelopeSequences(in: outputFileURL)
        #expect(sequences == [1, 2, 3, 4, 5])
    }

    @Test("typed activity aggregate is debounced into one derived settled fact")
    func typedActivityAggregateIsDebouncedIntoOneDerivedSettledFact() async {
        let bus = EventBus<RuntimeEnvelope>()
        let subscriber = RecordingSubscriber(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function))
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await ingestActivity(
            paneId: paneId,
            totals: [100, 120, 140],
            context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
            through: router
        )
        await clock.waitForPendingSleepCount(atLeast: 1)
        clock.advance(by: .milliseconds(750))

        _ = await subscriber.firstEvent { envelope in
            RuntimeEnvelopeHarness.paneEvents(from: [envelope]).contains {
                if case .terminalActivity(.unseenActivitySettled) = $0.event { return true }
                return false
            }
        }
        let settledEventCount = RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot()).count {
            if case .terminalActivity(.unseenActivitySettled) = $0.event { return true }
            return false
        }
        #expect(settledEventCount == 1)
        await router.stop()
        await subscriber.shutdown()
    }

    @Test("unseen settlement records the pane's activity status regardless of downstream suppression")
    func unseenSettlementRecordsPaneActivityStatus() async {
        // The router must publish the settled activity's last output line unconditionally: it has
        // no knowledge of InboxNotificationRouter/InboxPromoter's later suppression decisions for
        // the derived envelope it posts, so this recording call is the one place that guarantees a
        // pane's own sidebar row learns its latest real content either way.
        let bus = EventBus<RuntimeEnvelope>()
        let subscriber = RecordingSubscriber(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function))
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
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
            lastOutputLineReader: { _ in .value("seam-live-proof") },
            recordSettledActivityStatus: { paneId, lastOutputLine in
                recordedCalls.record(paneId: paneId, lastOutputLine: lastOutputLine)
            },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await ingestActivity(
            paneId: paneId,
            totals: [100, 120, 140],
            context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
            through: router
        )
        await clock.waitForPendingSleepCount(atLeast: 1)
        clock.advance(by: .milliseconds(750))

        _ = await subscriber.firstEvent { envelope in
            RuntimeEnvelopeHarness.paneEvents(from: [envelope]).contains {
                if case .terminalActivity(.unseenActivitySettled) = $0.event { return true }
                return false
            }
        }

        #expect(recordedCalls.calls.count == 1)
        #expect(recordedCalls.calls.first?.paneId == paneId.uuid)
        #expect(recordedCalls.calls.first?.lastOutputLine == "seam-live-proof")

        await router.stop()
        await subscriber.shutdown()
    }

    @Test("ordered commandFinished settles before and independently of lossy bus delivery")
    func orderedCommandFinishedSettlesIndependentlyOfBusDelivery() async {
        let bus = EventBus<RuntimeEnvelope>()
        let subscriber = RecordingSubscriber(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function))
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
            }
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await waitForBusSubscriberCount(bus, atLeast: 1)
        await router.consumeTerminalActivityInput(
            .orderedControl(
                surfaceID: paneId.uuid,
                paneID: paneId.uuid,
                precedingAggregate: nil,
                control: .commandFinished
            )
        )
        await router.waitForPendingDerivedActivityPosts()

        await assertEventuallyAsync("ordered commandFinished should publish a zero-row settled activity") {
            await subscriber.count { envelope in
                RuntimeEnvelopeHarness.paneEvents(from: [envelope]).contains {
                    if case .terminalActivity(.unseenActivitySettled(let activity)) = $0.event {
                        return activity.lastOutputLine == "echo-command-output" && activity.rowsAdded == 0
                    }
                    return false
                }
            } == 1
        }

        // The ordinary semantic fact remains available on the bus, but activity settlement does
        // not consume it a second time or depend on this subscriber path.
        _ = await bus.post(
            .pane(
                .test(
                    event: .terminal(.commandFinished(exitCode: 0, duration: 50_000_000)),
                    paneId: paneId,
                    paneKind: .terminal
                )
            )
        )

        await assertEventuallyAsync("bus delivery must not duplicate ordered command settlement") {
            await subscriber.count { envelope in
                RuntimeEnvelopeHarness.paneEvents(from: [envelope]).contains {
                    if case .terminalActivity(.unseenActivitySettled(let activity)) = $0.event {
                        return activity.lastOutputLine == "echo-command-output" && activity.rowsAdded == 0
                    }
                    return false
                }
            } == 1
        }

        #expect(recordedCalls.calls.count == 1)
        #expect(recordedCalls.calls.first?.paneId == paneId.uuid)
        #expect(recordedCalls.calls.first?.lastOutputLine == "echo-command-output")

        await router.stop()
        await subscriber.shutdown()
    }

    @Test("attended typed activity updates compact state without unseen settlement")
    func attendedTypedActivityUpdatesCompactStateWithoutUnseenSettlement() async {
        let bus = EventBus<RuntimeEnvelope>()
        let subscriber = RecordingSubscriber(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function))
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await ingestActivity(
            paneId: paneId,
            totals: [100, 140],
            context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30),
            through: router
        )
        #expect(atom.snapshot(for: paneId.uuid)?.scrollbarState?.total == 140)
        #expect(clock.pendingSleepCount == 0)
        #expect(
            RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot()).contains {
                if case .terminalActivity(.unseenActivitySettled) = $0.event { return true }
                return false
            } == false)

        await router.stop()
        await subscriber.shutdown()
    }

    @Test("stop cancels projector quiet timers without publishing stale activity")
    func stopCancelsProjectorQuietTimersWithoutPublishingStaleActivity() async {
        let bus = EventBus<RuntimeEnvelope>()
        let subscriber = RecordingSubscriber(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function))
        let clock = TestPushClock()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: TerminalActivityAtom(outputBurstThreshold: 30),
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await ingestActivity(
            paneId: paneId,
            totals: [100, 140],
            context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
            through: router
        )
        await clock.waitForPendingSleepCount(atLeast: 1)
        await router.stop()
        await clock.waitForPendingSleepCount(exactly: 0)
        clock.advance(by: .milliseconds(750))
        #expect(
            RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot()).contains {
                if case .terminalActivity(.unseenActivitySettled) = $0.event { return true }
                return false
            } == false)
        await subscriber.shutdown()
    }

    @Test("later typed aggregate replaces the earlier quiet timer")
    func laterTypedAggregateReplacesEarlierQuietTimer() async {
        let bus = EventBus<RuntimeEnvelope>()
        let subscriber = RecordingSubscriber(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function))
        let clock = TestPushClock()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: TerminalActivityAtom(outputBurstThreshold: 30),
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        let firstGeneration = clock.scheduledSleepGeneration
        await ingestActivity(
            paneId: paneId,
            totals: [100],
            context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
            through: router
        )
        await clock.waitForPendingSleepGeneration(firstGeneration)
        await ingestActivity(
            paneId: paneId,
            totals: [100, 140],
            context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
            through: router,
            startedAtMilliseconds: 1300
        )
        await clock.waitForPendingSleepGeneration(firstGeneration + 1)
        clock.advance(by: .milliseconds(750))
        _ = await subscriber.firstEvent { envelope in
            RuntimeEnvelopeHarness.paneEvents(from: [envelope]).contains {
                if case .terminalActivity(.unseenActivitySettled) = $0.event { return true }
                return false
            }
        }
        let settledEventCount = RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot()).count {
            if case .terminalActivity(.unseenActivitySettled) = $0.event { return true }
            return false
        }
        #expect(settledEventCount == 1)
        await router.stop()
        await subscriber.shutdown()
    }

    @Test("decreasing typed totals clamp growth to zero")
    func decreasingTypedTotalsClampGrowthToZero() async {
        let bus = EventBus<RuntimeEnvelope>()
        let subscriber = RecordingSubscriber(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function))
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await ingestActivity(
            paneId: paneId,
            totals: [100, 80],
            context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
            through: router
        )
        #expect(atom.snapshot(for: paneId.uuid)?.outputBurst == .quiet(lastTotal: 80))
        await clock.waitForPendingSleepCount(atLeast: 1)
        clock.advance(by: .milliseconds(750))
        #expect(
            RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot()).contains {
                if case .terminalActivity(.unseenActivitySettled) = $0.event { return true }
                return false
            } == false)
        await router.stop()
        await subscriber.shutdown()
    }

    @Test("start is idempotent and does not double-consume events")
    func startIsIdempotentAndDoesNotDoubleConsumeEvents() async {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom()
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom)
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await router.start()
        _ = await bus.post(
            .pane(
                .test(
                    event: .terminal(.openURLRequested(url: "https://example.com", kind: .text)),
                    paneId: paneId,
                    paneKind: .terminal
                )
            )
        )

        await assertEventuallyMain("idempotent start should consume one URL request") {
            atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 1
        }

        await router.stop()
    }

    @Test("stop prevents later runtime events from mutating activity")
    func stopPreventsLaterRuntimeEventsFromMutatingActivity() async {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom()
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom)
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await router.stop()
        _ = await bus.post(
            .pane(
                .test(
                    event: .terminal(.progressReportUpdated(ProgressState(kind: .set, percent: 99))),
                    paneId: paneId,
                    paneKind: .terminal
                )
            )
        )
        await Task.yield()

        #expect(atom.snapshot(for: paneId.uuid) == nil)
    }

    @Test("non-terminal pane envelopes are ignored")
    func nonTerminalPaneEnvelopesAreIgnored() async {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom()
        let router = TerminalActivityRouter(bus: bus, activityAtom: atom)
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        _ = await bus.post(
            .pane(
                .test(
                    event: .browser(.pageLoaded(url: URL(fileURLWithPath: "/tmp/index.html"))),
                    paneId: paneId,
                    paneKind: .browser
                )
            )
        )
        await Task.yield()

        #expect(atom.snapshot(for: paneId.uuid) == nil)
        await router.stop()
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-terminal-activity-router-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeTraceRuntime(
        traceDirectory: URL,
        traceName: String,
        traceTags: String,
        processIdentifier: Int32,
        flushMode: String? = nil
    ) -> (runtime: AgentStudioTraceRuntime, outputFileURL: URL) {
        var environment = [
            "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
            "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
            "AGENTSTUDIO_TRACE_NAME": traceName,
            "AGENTSTUDIO_TRACE_TAGS": traceTags,
        ]
        environment["AGENTSTUDIO_TRACE_FLUSH"] = flushMode
        return (
            runtime: AgentStudioTraceRuntime.fromEnvironment(
                environment,
                processIdentifier: processIdentifier
            ),
            outputFileURL: traceDirectory.appendingPathComponent(
                "agentstudio-\(traceName)-\(processIdentifier).jsonl"
            )
        )
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

    private func traceEnvelopeSequences(in fileURL: URL) throws -> [Int] {
        try traceRecords(in: fileURL).map { record in
            guard case .int(let sequence) = record.attributes["agentstudio.envelope.seq"] else {
                Issue.record("Missing integer envelope sequence in trace record")
                return -1
            }
            return sequence
        }
    }

    private func traceRecords(in fileURL: URL) throws -> [TraceRecordFixture] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return try contents.split(separator: "\n").map { line in
            try JSONDecoder().decode(TraceRecordFixture.self, from: Data(line.utf8))
        }
    }

}
