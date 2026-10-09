import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("TerminalActivityRouter derived activity events", .serialized)
struct TerminalActivityDerivedEventTests {
    private typealias SettledEventRecord = (
        source: EventSource,
        seq: UInt64,
        activity: TerminalSettledActivity
    )

    private final class MillisecondBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64

        init(_ value: Int64) {
            self.value = value
        }

        func set(_ value: Int64) {
            lock.withLock {
                self.value = value
            }
        }

        func get() -> Int64 {
            lock.withLock {
                value
            }
        }
    }

    private final class PaneSetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var paneIds = Set<UUID>()

        func insert(_ paneId: UUID) {
            _ = lock.withLock {
                paneIds.insert(paneId)
            }
        }

        func contains(_ paneId: UUID) -> Bool {
            lock.withLock {
                paneIds.contains(paneId)
            }
        }
    }

    @Test("scrollback growth does not emit unseen activity before quiet")
    func scrollbackGrowthDoesNotEmitUnseenActivityBeforeQuiet() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
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
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            await router.start()
            await bus.waitForSubscriberRegistration(subscriberName: "TerminalActivityRouter")
            let noSettleFrom = await events.mark(paneId.uuid)
            await postScrollbackBurst(paneId: paneId, totals: [100, 120, 140], through: router)
            #expect(atom.snapshot(for: paneId.uuid)?.scrollbarState?.total == 140)
            let deadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)
            clock.advance(to: deadlines.origin.advanced(by: deadline.deadline - .milliseconds(1)))
            #expect(clock.now < deadlines.origin.advanced(by: deadline.deadline))
            await router.stop()
            _ = try await deadlines.expectDisposition(for: deadline, .cancelled)
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(paneID: paneId.uuid, from: noSettleFrom)
            try await deadlines.finish()
            try await events.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            throw error
        }
    }

    @Test("scrollback growth emits one settled activity after quiet")
    func scrollbackGrowthEmitsOneSettledActivityAfterQuiet() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), clock: clock, factSink: deadlines.sink)
        let nowMilliseconds = MillisecondBox(2000)
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            projector: projector,
            surfaceIDForPaneID: { $0 },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock,
            nowMilliseconds: { nowMilliseconds.get() }
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            await router.start()
            await bus.waitForSubscriberRegistration(subscriberName: "TerminalActivityRouter")
            await postScrollbackBurst(
                paneId: paneId,
                totals: [100, 120, 140],
                through: router,
                startedAtMilliseconds: 2000
            )
            #expect(atom.snapshot(for: paneId.uuid)?.scrollbarState?.total == 140)
            let deadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)
            clock.advance(by: .milliseconds(749))
            #expect(clock.now < deadlines.origin.advanced(by: deadline.deadline))

            _ = try await deadlines.fire(deadline)
            let settled = try await events.expectNextUnseenActivity(
                paneID: paneId.uuid, windowID: deadline.scope.windowID)
            let activity = settled.activity
            #expect(activity.rowsAdded == 40)
            #expect(activity.thresholdRows == 30)
            #expect(activity.eventCount == 3)
            #expect(activity.latestRows == 140)
            #expect(activity.baselineRows == 100)
            #expect(activity.startedAtMilliseconds == 2000)
            #expect(activity.settledAtMilliseconds == 2000 + 200 + 750)

            let noAdditionalSettles = await events.mark(paneId.uuid)
            await router.stop()
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noAdditionalSettles)
            try await deadlines.finish()
            try await events.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            throw error
        }
    }

    @Test("observing pane before quiet cancels settled activity")
    func observingPaneBeforeQuietCancelsSettledActivity() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), clock: clock, factSink: deadlines.sink)
        let paneId = PaneId.generateUUIDv7()
        let attendedPaneIds = PaneSetBox()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            projector: projector,
            surfaceIDForPaneID: { $0 },
            isPaneCurrentlyAttended: { attendedPaneIds.contains($0) },
            unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock
        )

        do {
            await router.start()
            await bus.waitForSubscriberRegistration(subscriberName: "TerminalActivityRouter")
            let noSettleFrom = await events.mark(paneId.uuid)
            await postScrollbackBurst(paneId: paneId, totals: [100], through: router)
            let deadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)

            attendedPaneIds.insert(paneId.uuid)
            await postScrollbackBurst(
                paneId: paneId,
                totals: [100, 140],
                through: router,
                isAttended: true
            )
            _ = try await deadlines.expectDisposition(for: deadline, .cancelled)
            await clock.waitForPendingSleepCount(exactly: 0)
            clock.advance(by: .milliseconds(750))
            await router.stop()
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(paneID: paneId.uuid, from: noSettleFrom)
            try await deadlines.finish()
            try await events.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            throw error
        }
    }

    @Test("settled activity events use independent monotonic source sequence")
    func settledActivityEventsUseIndependentMonotonicSourceSequence() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let events = await TerminalActivityEventFactSource.attach(bus: bus, subscriberName: #function)
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
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        do {
            await router.start()
            await bus.waitForSubscriberRegistration(subscriberName: "TerminalActivityRouter")
            await postScrollbackBurst(paneId: paneId, totals: [100, 120, 140], through: router)
            #expect(atom.snapshot(for: paneId.uuid)?.scrollbarState?.total == 140)
            let firstDeadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            let observation = try await events.expectNextPaneObservation(paneID: paneId.uuid, isPinnedToBottom: false)
            _ = try await deadlines.fire(firstDeadline)
            let firstSettle = try await events.expectNextUnseenActivity(
                paneID: paneId.uuid, windowID: firstDeadline.scope.windowID)

            await router.consumeTerminalActivityInput(
                .orderedControl(
                    surfaceID: paneId.uuid,
                    paneID: paneId.uuid,
                    precedingAggregate: nil,
                    control: .observed
                )
            )
            await postScrollbackBurst(paneId: paneId, totals: [200, 220, 240], through: router)
            #expect(atom.snapshot(for: paneId.uuid)?.scrollbarState?.total == 240)
            let secondDeadline = try await deadlines.expectNextRegistration(paneID: paneId.uuid)
            _ = try await deadlines.fire(secondDeadline)
            let secondSettle = try await events.expectNextUnseenActivity(
                paneID: paneId.uuid, windowID: secondDeadline.scope.windowID)
            #expect([observation.seq, firstSettle.envelope.seq, secondSettle.envelope.seq] == [1, 2, 3])
            let settledEvents: [SettledEventRecord] = [
                (firstSettle.envelope.source, firstSettle.envelope.seq, firstSettle.activity),
                (secondSettle.envelope.source, secondSettle.envelope.seq, secondSettle.activity),
            ]
            #expect(
                settledEvents.map(\.source) == [
                    .system(.builtin(.terminalActivityRouter)),
                    .system(.builtin(.terminalActivityRouter)),
                ])
            #expect(settledEvents.map(\.seq) == [2, 3])

            let noAdditionalSettles = await events.mark(paneId.uuid)
            await router.stop()
            _ = try await events.expectNoUnseenActivityThroughStoppedProducer(
                paneID: paneId.uuid, from: noAdditionalSettles)
            try await deadlines.finish()
            try await events.finish()
        } catch {
            await router.stop()
            try? await deadlines.finish()
            try? await events.finish()
            throw error
        }
    }

    private func postScrollbackBurst(
        paneId: PaneId,
        totals: [Int],
        through router: TerminalActivityRouter,
        isAttended: Bool = false,
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
                    context: TerminalActivityProjectionContext(
                        isAttended: isAttended,
                        isAgentClassified: false,
                        outputBurstThreshold: 30
                    )
                )
            )
        )
    }

}
