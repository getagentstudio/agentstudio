import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("EventBus RuntimeEnvelope replay")
struct EventBusRuntimeEnvelopeTests {
    @Test("fact interests target single live posts without changing matched order")
    func factInterestsTargetSingleLivePosts() async {
        let bus = EventBus<RuntimeEnvelope>()
        let terminal = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "live-terminal",
            factInterest: .matching([.paneTerminal])
        )
        let activity = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "live-activity",
            factInterest: .matching([.paneTerminalActivity])
        )
        let overlapping = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "live-overlap",
            factInterest: .matching([.paneTerminal, .paneTerminalActivity])
        )
        let envelopes = makeTargetingSequence()

        for envelope in envelopes {
            _ = await bus.post(envelope)
        }

        #expect(await consumeSequences(terminal, count: 2) == [1, 3])
        #expect(await consumeSequences(activity, count: 1) == [2])
        #expect(await consumeSequences(overlapping, count: 3) == [1, 2, 3])
        assertTargetedDiagnostics(await bus.diagnosticsSnapshot())
    }

    @Test("fact interests target batch posts without changing matched order")
    func factInterestsTargetBatchPosts() async {
        let bus = EventBus<RuntimeEnvelope>()
        let terminal = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "batch-terminal",
            factInterest: .matching([.paneTerminal])
        )
        let activity = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "batch-activity",
            factInterest: .matching([.paneTerminalActivity])
        )
        let overlapping = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "batch-overlap",
            factInterest: .matching([.paneTerminal, .paneTerminalActivity])
        )

        _ = await bus.post(contentsOf: makeTargetingSequence())

        #expect(await consumeSequences(terminal, count: 2) == [1, 3])
        #expect(await consumeSequences(activity, count: 1) == [2])
        #expect(await consumeSequences(overlapping, count: 3) == [1, 2, 3])
        assertTargetedDiagnostics(await bus.diagnosticsSnapshot())
    }

    @Test("fact interests target replay while absent interest remains catch-all")
    func factInterestsTargetReplay() async {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(
                capacityPerSource: 8,
                sourceKey: { envelope in envelope.source.description }
            )
        )
        for envelope in makeTargetingSequence() {
            _ = await bus.post(envelope)
        }

        let terminal = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "replay-terminal",
            factInterest: .matching([.paneTerminal])
        )
        let activity = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "replay-activity",
            factInterest: .matching([.paneTerminalActivity])
        )
        let ungated = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "replay-ungated"
        )

        #expect(await consumeSequences(terminal, count: 2) == [1, 3])
        #expect(await consumeSequences(activity, count: 1) == [2])
        #expect(await consumeSequences(ungated, count: 3) == [1, 2, 3])
        assertTargetedDiagnostics(await bus.diagnosticsSnapshot(), overlapSuffix: "ungated")
    }

    @Test("replay keeps at most 256 envelopes per source")
    func replayBoundPerSource() async throws {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(
                capacityPerSource: 256,
                sourceKey: { envelope in
                    envelope.source.description
                }
            )
        )
        let paneA = PaneId.generateUUIDv7()
        let paneB = PaneId.generateUUIDv7()

        for seq in 1...300 {
            _ = await bus.post(makePaneEnvelope(paneId: paneA, seq: UInt64(seq)))
            _ = await bus.post(makePaneEnvelope(paneId: paneB, seq: UInt64(seq)))
        }

        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: "replayBoundPerSource")
        let replayed = try await consumeReplayThroughLiveMarker(bus: bus, subscription: subscription)
        #expect(replayed.count == 256 * 2)

        let paneASeqs = replayed.filter { $0.source == .pane(paneA) }.map(\.seq)
        let paneBSeqs = replayed.filter { $0.source == .pane(paneB) }.map(\.seq)
        #expect(paneASeqs.count == 256)
        #expect(paneBSeqs.count == 256)
        #expect(paneASeqs.first == 45)
        #expect(paneASeqs.last == 300)
        #expect(paneASeqs == (45...300).map { UInt64($0) })
        #expect(paneBSeqs.first == 45)
        #expect(paneBSeqs.last == 300)
        #expect(paneBSeqs == (45...300).map { UInt64($0) })
        let expectedTranscript = (45...300).flatMap { sequence in
            [
                ReplayTranscriptEntry(source: .pane(paneA), sequence: UInt64(sequence)),
                ReplayTranscriptEntry(source: .pane(paneB), sequence: UInt64(sequence)),
            ]
        }
        #expect(replayed.map { ReplayTranscriptEntry(source: $0.source, sequence: $0.seq) } == expectedTranscript)
    }

    @Test("replay bound is isolated per source")
    func replayBoundIsolationPerSource() async throws {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(
                capacityPerSource: 256,
                sourceKey: { envelope in
                    envelope.source.description
                }
            )
        )
        let hotPane = PaneId.generateUUIDv7()
        let coolPane = PaneId.generateUUIDv7()

        for seq in 1...400 {
            _ = await bus.post(makePaneEnvelope(paneId: hotPane, seq: UInt64(seq)))
        }
        for seq in 1...3 {
            _ = await bus.post(makePaneEnvelope(paneId: coolPane, seq: UInt64(seq)))
        }

        let subscription = await bus.subscribe(
            policy: .criticalUnbounded, subscriberName: "replayBoundIsolationPerSource")
        let replayed = try await consumeReplayThroughLiveMarker(bus: bus, subscription: subscription)

        #expect(replayed.count == 256 + 3)

        let hotSeqs = replayed.filter { $0.source == .pane(hotPane) }.map(\.seq)
        let coolSeqs = replayed.filter { $0.source == .pane(coolPane) }.map(\.seq)
        #expect(hotSeqs.count == 256)
        #expect(hotSeqs.first == 145)
        #expect(hotSeqs.last == 400)
        #expect(hotSeqs == (145...400).map { UInt64($0) })
        #expect(coolSeqs == [1, 2, 3])
        let expectedTranscript =
            (145...400).map { ReplayTranscriptEntry(source: .pane(hotPane), sequence: UInt64($0)) }
            + (1...3).map { ReplayTranscriptEntry(source: .pane(coolPane), sequence: UInt64($0)) }
        #expect(replayed.map { ReplayTranscriptEntry(source: $0.source, sequence: $0.seq) } == expectedTranscript)
    }

    @Test("replay source eviction removes closed pane history")
    func replaySourceEvictionRemovesClosedPaneHistory() async throws {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(
                capacityPerSource: 256,
                sourceKey: { envelope in
                    envelope.source.description
                }
            )
        )
        let evictedPane = PaneId.generateUUIDv7()
        let retainedPane = PaneId.generateUUIDv7()

        _ = await bus.post(makePaneEnvelope(paneId: evictedPane, seq: 1))
        _ = await bus.post(makePaneEnvelope(paneId: retainedPane, seq: 2))
        await bus.evictReplay(sourceKey: EventSource.pane(evictedPane).description)

        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: "replaySourceEviction")
        let replayed = try await consumeReplayThroughLiveMarker(bus: bus, subscription: subscription)
        let envelope = replayed.first

        #expect(envelope?.source == .pane(retainedPane))
        #expect(replayed.map(\.source) == [.pane(retainedPane)])
        #expect(replayed.map(\.seq) == [2])
    }

    @Test("replay drops are counted when subscriber buffering is smaller than replay snapshot")
    func replayDropsAreCountedForSmallSubscriberBuffer() async {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(
                capacityPerSource: 8,
                sourceKey: { envelope in
                    envelope.source.description
                }
            )
        )
        let paneId = PaneId.generateUUIDv7()
        for seq in 1...8 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        let subscription = await bus.subscribe(policy: .lossyNewest(1), subscriberName: "smallReplayBuffer")
        let dropped = await bus.totalDroppedEvents()
        #expect(dropped > 0)
        withExtendedLifetime(subscription) {}
    }

    @Test("critical subscriber receives more than standard lossy limit without drops")
    func criticalSubscriberReceivesMoreThanStandardLossyLimit() async {
        let bus = EventBus<RuntimeEnvelope>()
        let paneId = PaneId.generateUUIDv7()
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: "criticalBurst")

        for seq in 1...BusSubscriberPolicy.standardLossyBufferLimit + 1 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        var iterator = subscription.makeAsyncIterator()
        var received: [UInt64] = []
        for _ in 1...BusSubscriberPolicy.standardLossyBufferLimit + 1 {
            guard let envelope = await iterator.next() else {
                Issue.record("Expected critical subscriber to receive the whole burst")
                return
            }
            received.append(envelope.seq)
        }

        #expect(received.count == BusSubscriberPolicy.standardLossyBufferLimit + 1)
        #expect(await bus.totalDroppedEvents() == 0)
        let diagnostics = await bus.diagnosticsSnapshot()
        #expect(diagnostics.activeSubscribers.first?.liveDroppedCount == 0)
    }

    @Test("lossy subscriber drops are attributed to subscriber and policy")
    func lossySubscriberDropsAreAttributed() async {
        let bus = EventBus<RuntimeEnvelope>()
        let paneId = PaneId.generateUUIDv7()
        let subscription = await bus.subscribe(policy: .lossyNewest(1), subscriberName: "lossyDiagnostic")

        for seq in 1...8 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        let diagnostics = await bus.diagnosticsSnapshot()
        let subscriber = diagnostics.activeSubscribers.first
        #expect(subscriber?.subscriberName == "lossyDiagnostic")
        #expect(subscriber?.policy == .lossyNewest(1))
        #expect((subscriber?.liveDroppedCount ?? 0) > 0)
        #expect(subscriber?.failureClasses.contains(.lossyDrop) == true)
        withExtendedLifetime(subscription) {}
    }

    @Test("critical pressure diagnostics are visible for stalled consumers")
    func criticalPressureDiagnosticsAreVisible() async {
        let bus = EventBus<RuntimeEnvelope>()
        let paneId = PaneId.generateUUIDv7()
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: "stalledCritical")

        for seq in 1...BusSubscriberPolicy.criticalPressureWarningLimit + 1 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        let diagnostics = await bus.diagnosticsSnapshot()
        let subscriber = diagnostics.activeSubscribers.first
        #expect((subscriber?.highWaterLag ?? 0) > UInt64(BusSubscriberPolicy.criticalPressureWarningLimit))
        #expect(subscriber?.failureClasses.contains(.criticalPressure) == true)
        #expect(subscriber?.requiresRecovery == true)
        withExtendedLifetime(subscription) {}
    }

    @Test("critical pressure diagnostics do not fire for drained consumers")
    func criticalPressureDiagnosticsDoNotFireForDrainedConsumers() async {
        let bus = EventBus<RuntimeEnvelope>()
        let paneId = PaneId.generateUUIDv7()
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: "drainingCritical")
        var iterator = subscription.makeAsyncIterator()

        for seq in 1...BusSubscriberPolicy.criticalPressureWarningLimit + 1 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
            guard let envelope = await iterator.next() else {
                Issue.record("Expected draining critical subscriber to receive event \(seq)")
                return
            }
            #expect(envelope.seq == UInt64(seq))
        }

        let diagnostics = await bus.diagnosticsSnapshot()
        let subscriber = diagnostics.activeSubscribers.first
        #expect(subscriber?.failureClasses.contains(.criticalPressure) == false)
        #expect(subscriber?.requiresRecovery == false)
        #expect(subscriber?.highWaterLag == 1)
    }

    @Test("replay truncation status uses safe source labels")
    func replayTruncationStatusUsesSafeSourceLabels() async {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(
                capacityPerSource: 2,
                sourceKey: { envelope in
                    envelope.source.description
                }
            )
        )
        let paneId = PaneId.generateUUIDv7()
        for seq in 1...3 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: "lateCritical")

        guard case .possiblyTruncated(let sourceLabels) = subscription.replayStatus else {
            Issue.record("Expected replay truncation status")
            return
        }
        #expect(sourceLabels.count == 1)
        #expect(sourceLabels.first?.hasPrefix("source-") == true)
        #expect(sourceLabels.first?.contains(paneId.uuidString) == false)

        let diagnostics = await bus.diagnosticsSnapshot()
        let subscriber = diagnostics.activeSubscribers.first
        #expect(subscriber?.failureClasses.contains(.replayPossiblyTruncated) == true)
        #expect(subscriber?.requiresRecovery == true)
    }

    @Test("recovery diagnostics survive subscriber termination")
    func recoveryDiagnosticsSurviveSubscriberTermination() async {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(
                capacityPerSource: 2,
                sourceKey: { envelope in
                    envelope.source.description
                }
            )
        )
        let paneId = PaneId.generateUUIDv7()
        for seq in 1...3 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        var subscription: EventBusSubscription<RuntimeEnvelope>? = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "terminatingCritical"
        )
        #expect(subscription?.replayStatus != .complete)
        subscription = nil

        await assertBusDrained(bus)

        let diagnostics = await bus.diagnosticsSnapshot()
        #expect(diagnostics.activeSubscribers.isEmpty)
        let retained = diagnostics.retainedRecoveryDiagnostics.first
        #expect(retained?.subscriberName == "terminatingCritical")
        #expect(retained?.failureClasses.contains(.replayPossiblyTruncated) == true)
        #expect(retained?.requiresRecovery == true)

        await bus.clearRetainedRecoveryDiagnostics()
        let clearedDiagnostics = await bus.diagnosticsSnapshot()
        #expect(clearedDiagnostics.retainedRecoveryDiagnostics.isEmpty)
    }

    @Test("performance debt tracks stalled delivery and returns to zero after consumption")
    func performanceDebtTracksStalledDeliveryAndConsumption() async {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let paneId = PaneId.generateUUIDv7()
        let subscription = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "performanceDebtStalled"
        )

        for seq in 1...3 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        #expect(reporter.snapshot().eventBusActiveDeliveryDebt == 3)
        #expect(reporter.snapshot().eventBusActiveSubscriberCount == 1)

        var iterator = subscription.makeAsyncIterator()
        for expectedDebt in [2, 1, 0] {
            _ = await iterator.next()
            #expect(reporter.snapshot().eventBusActiveDeliveryDebt == UInt64(expectedDebt))
        }
    }

    @Test("lossy replacement drops stay separate from active delivery debt")
    func lossyReplacementDropsStaySeparateFromDebt() async {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let paneId = PaneId.generateUUIDv7()
        let subscription = await bus.subscribe(
            policy: .lossyNewest(1),
            subscriberName: "performanceDebtLossy"
        )

        for seq in 1...8 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        let pressuredSnapshot = reporter.snapshot()
        #expect(pressuredSnapshot.eventBusActiveDeliveryDebt == 1)
        #expect(pressuredSnapshot.eventBusLiveDroppedCount == 7)

        var iterator = subscription.makeAsyncIterator()
        _ = await iterator.next()
        #expect(reporter.snapshot().eventBusActiveDeliveryDebt == 0)
    }

    @Test("replay delivery contributes debt while retained replay storage does not")
    func replayDeliveryContributesOnlyWhilePending() async {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(
                capacityPerSource: 4,
                sourceKey: { envelope in envelope.source.description }
            ),
            performanceReporter: reporter
        )
        let paneId = PaneId.generateUUIDv7()
        for seq in 1...4 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }

        let subscription = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "performanceDebtReplay"
        )
        #expect(reporter.snapshot().eventBusActiveDeliveryDebt == 4)

        var iterator = subscription.makeAsyncIterator()
        for _ in 1...4 {
            _ = await iterator.next()
        }

        #expect(reporter.snapshot().eventBusActiveDeliveryDebt == 0)
        #expect(await bus.diagnosticsSnapshot().activeSubscribers.first?.replayStatus == .complete)
    }

    @Test("subscriber termination retires undelivered debt without leaving active debt")
    func subscriberTerminationRetiresUndeliveredDebt() async {
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let paneId = PaneId.generateUUIDv7()
        var subscription: EventBusSubscription<RuntimeEnvelope>? = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "performanceDebtTermination"
        )
        for seq in 1...3 {
            _ = await bus.post(makePaneEnvelope(paneId: paneId, seq: UInt64(seq)))
        }
        #expect(reporter.snapshot().eventBusActiveDeliveryDebt == 3)
        #expect(subscription != nil)

        subscription = nil
        await assertBusDrained(bus)

        let retiredSnapshot = reporter.snapshot()
        #expect(retiredSnapshot.eventBusActiveDeliveryDebt == 0)
        #expect(retiredSnapshot.eventBusRetiredUndeliveredCount == 3)
        #expect(retiredSnapshot.eventBusActiveSubscriberCount == 0)
    }

    /// The marker closes replay; cancellation then drives the owned consumer to
    /// stream nil, whose existing callback joins subscriber removal.
    private func consumeReplayThroughLiveMarker(
        bus: EventBus<RuntimeEnvelope>,
        subscription: EventBusSubscription<RuntimeEnvelope>
    ) async throws -> [RuntimeEnvelope] {
        let markerPane = PaneId.generateUUIDv7()
        let marker = makePaneEnvelope(paneId: markerPane, seq: 1)
        let markerArrival = HeldStep<[RuntimeEnvelope]>("complete replay through live marker")
        markerArrival.release()
        let consumer = Task {
            var replayed: [RuntimeEnvelope] = []
            var observedMarker = false
            for await envelope in subscription {
                guard !observedMarker else { continue }
                if envelope.source == marker.source && envelope.seq == marker.seq {
                    observedMarker = true
                    try? await markerArrival.arrive(replayed)
                } else {
                    replayed.append(envelope)
                }
            }
        }
        let markerPost = await bus.post(marker)
        do {
            let replayed = try await markerArrival.firstArrival()
            consumer.cancel()
            await consumer.value
            #expect(await bus.subscriberCount == 0)
            #expect(!markerArrival.recordedArrivals.isEmpty)
            #expect(markerPost.droppedCount == 0)
            #expect(markerPost.subscriberCount == 1)
            return replayed
        } catch {
            consumer.cancel()
            await consumer.value
            #expect(await bus.subscriberCount == 0)
            throw error
        }
    }

    private func makePaneEnvelope(paneId: PaneId, seq: UInt64) -> RuntimeEnvelope {
        .pane(
            PaneEnvelope.test(
                event: .terminal(.bellRang),
                paneId: paneId,
                paneKind: .terminal,
                source: .pane(paneId),
                seq: seq
            )
        )
    }

    private func makeTargetingSequence() -> [RuntimeEnvelope] {
        let paneId = PaneId.generateUUIDv7()
        return [
            makePaneEnvelope(paneId: paneId, seq: 1),
            .pane(
                PaneEnvelope.test(
                    event: .terminalActivity(.agentSettledActivityRevoked),
                    paneId: paneId,
                    paneKind: .terminal,
                    source: .pane(paneId),
                    seq: 2
                )
            ),
            makePaneEnvelope(paneId: paneId, seq: 3),
        ]
    }

    private func consumeSequences(
        _ subscription: EventBusSubscription<RuntimeEnvelope>,
        count: Int
    ) async -> [UInt64] {
        var iterator = subscription.makeAsyncIterator()
        var sequences: [UInt64] = []
        for _ in 0..<count {
            if let envelope = await iterator.next() {
                sequences.append(envelope.seq)
            }
        }
        return sequences
    }

    private func assertTargetedDiagnostics(
        _ snapshot: EventBusDiagnosticsSnapshot,
        overlapSuffix: String = "overlap"
    ) {
        let yieldedByName = Dictionary(
            uniqueKeysWithValues: snapshot.activeSubscribers.map { ($0.subscriberName, $0.yieldedCount) }
        )
        let terminal = yieldedByName.first { $0.key.hasSuffix("terminal") }?.value
        let activity = yieldedByName.first { $0.key.hasSuffix("activity") }?.value
        let overlap = yieldedByName.first { $0.key.hasSuffix(overlapSuffix) }?.value
        #expect(terminal == 2)
        #expect(activity == 1)
        #expect(overlap == 3)
        #expect(snapshot.activeSubscribers.count == 3)
    }
}

private struct ReplayTranscriptEntry: Equatable, Sendable {
    let source: EventSource
    let sequence: UInt64
}
