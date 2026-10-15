import AgentStudioTestHarness
import AgentStudioTestSupport
import Testing

@testable import AgentStudioCore

private enum BusTestFact: Sendable, Equatable {
    case started
    case closed
}

private struct BusTestEnvelope: Sendable, Equatable {
    let scope: String
    let fact: BusTestFact
}

@Suite("EventBus fact source")
struct EventBusFactSourceTests {
    private func vocabulary() -> FactVocabulary<String, BusTestFact> {
        FactVocabulary(
            describeScope: { $0 },
            describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .closed }
        )
    }

    private func attach(
        bus: EventBus<BusTestEnvelope>,
        policy: BusSubscriberPolicy = .criticalUnbounded,
        observeEnvelope: @escaping @Sendable (BusTestEnvelope) -> Void = { _ in }
    ) async -> FactRecorder<String, BusTestFact> {
        let subscription = await bus.subscribe(policy: policy, subscriberName: #function)
        return EventBusFactSource.attach(
            subscription: subscription, vocabulary: vocabulary(),
            replayWasTruncated: {
                if case .possiblyTruncated = subscription.replayStatus { return true }
                return false
            },
            classify: {
                observeEnvelope($0)
                return ($0.scope, $0.fact)
            }
        )
    }

    @Test("attach completes the subscription before a post can be missed")
    func attachBeforePost() async throws {
        let bus = EventBus<BusTestEnvelope>()
        let recorder = await attach(bus: bus)

        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .started))

        try await recorder.expectNext(in: "operation", .started)
        try await recorder.finish()
    }

    @Test("mark settles bus deliveries already enqueued at the call")
    func markSettlesEarlierPost() async throws {
        let bus = EventBus<BusTestEnvelope>()
        let recorder = await attach(bus: bus)
        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .started))

        try await recorder.expectNext(in: "operation", .started)
        let opening = await recorder.mark("operation")
        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .closed))

        try await recorder.expectNone(
            of: { $0 == .started }, "second start", from: opening,
            closedBy: { $0 == .closed }
        )
        try await recorder.finish()
    }

    @Test("truncated replay is sticky loss before a retained close")
    func truncatedReplayReportsLoss() async throws {
        let bus = EventBus<BusTestEnvelope>(
            replayConfiguration: .init(capacityPerSource: 1, sourceKey: { $0.scope })
        )
        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .started))
        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .closed))
        let recorder = await attach(bus: bus)

        await #expect(throws: FactsLost.self) {
            try await recorder.expectNext(in: "operation", .closed)
        }
        await #expect(throws: FactsLost.self) { try await recorder.finish() }
    }

    @Test("bounded replay eviction reports loss before a matching fact")
    func replayDropReportsLoss() async throws {
        let bus = EventBus<BusTestEnvelope>(
            replayConfiguration: .init(capacityPerSource: 3, sourceKey: { $0.scope })
        )
        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .started))
        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .started))
        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .closed))
        let recorder = await attach(bus: bus, policy: .lossyNewest(1))

        await #expect(throws: FactsLost.self) {
            try await recorder.expectNext(in: "operation", .closed)
        }
        await #expect(throws: FactsLost.self) { try await recorder.finish() }
    }

    @Test("finish cancels the collector and rejects later bus facts")
    func finishStopsCollection() async throws {
        let bus = EventBus<BusTestEnvelope>()
        let recorder = await attach(bus: bus)

        try await recorder.finish()
        _ = await bus.post(BusTestEnvelope(scope: "operation", fact: .started))

        await #expect(throws: Cancelled.self) {
            try await recorder.expectNext(in: "operation", .started)
        }
    }

    @Test("a fresh bus has no stale facts from an earlier subscription")
    func freshBusHasNoStaleFacts() async throws {
        let firstBus = EventBus<BusTestEnvelope>()
        let firstRecorder = await attach(bus: firstBus)
        _ = await firstBus.post(BusTestEnvelope(scope: "old", fact: .started))
        try await firstRecorder.expectNext(in: "old", .started)
        try await firstRecorder.finish()

        let secondBus = EventBus<BusTestEnvelope>()
        let subscriptionFacts = LocalFactSource(
            vocabulary: FactVocabulary<String, BusTestEnvelope>(
                describeScope: { $0 },
                describeFact: { "\($0.scope)/\($0.fact)" },
                isClosing: { _, envelope in envelope == BusTestEnvelope(scope: "new", fact: .closed) }
            )
        )
        let observedFacts = try subscriptionFacts.attach()
        let opening = await observedFacts.mark("second subscription")
        let secondRecorder = await attach(
            bus: secondBus,
            observeEnvelope: { subscriptionFacts.sink("second subscription", $0) }
        )
        _ = await secondBus.post(BusTestEnvelope(scope: "new", fact: .closed))

        do {
            try await secondRecorder.expectNext(in: "new", .closed)
            try await observedFacts.expectNone(
                of: { $0.scope == "old" }, "old subscription facts", from: opening,
                closedBy: { $0 == BusTestEnvelope(scope: "new", fact: .closed) }
            )
        } catch {
            try await secondRecorder.finish()
            subscriptionFacts.end()
            try? await observedFacts.finish()
            throw error
        }
        try await secondRecorder.finish()
        subscriptionFacts.end()
        try await observedFacts.finish()
    }
}
