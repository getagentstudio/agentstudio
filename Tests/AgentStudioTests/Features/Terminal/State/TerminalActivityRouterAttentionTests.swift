import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("TerminalActivityRouter attention ordering", .serialized)
struct TerminalActivityRouterAttentionTests {
    @Test("first settled attention change delivers previous off before current on")
    func firstSettledChangeIsObserved() async throws {
        // Arrange
        let fixture = try AttentionFixture()
        do {
            try await fixture.start()

            // Act
            fixture.selectPane(at: 1)
            _ = try await fixture.recorder.expectNextControl(fixture.event(0, false))
            _ = try await fixture.recorder.expectNextControl(fixture.event(1, true))
            try await fixture.stop()

            // Assert
            #expect(fixture.recorder.events == [fixture.event(0, false), fixture.event(1, true)])
            try await fixture.finish()
        } catch {
            await fixture.abort()
            throw error
        }
    }

    @Test("same-turn intermediate attention never receives a control")
    func sameTurnChangesCoalesce() async throws {
        // Arrange
        let fixture = try AttentionFixture()
        do {
            try await fixture.start()

            // Act
            fixture.selectPane(at: 1)
            fixture.selectPane(at: 2)
            _ = try await fixture.recorder.expectNextControl(fixture.event(0, false))
            _ = try await fixture.recorder.expectNextControl(fixture.event(2, true))
            try await fixture.stop()

            // Assert
            #expect(fixture.recorder.events == [fixture.event(0, false), fixture.event(2, true)])
            try await fixture.finish()
        } catch {
            await fixture.abort()
            throw error
        }
    }
    @Test("separately settled turns survive an awaited control in order")
    func settledTurnsQueueBehindBlockedDelivery() async throws {
        // Arrange
        let fixture = try AttentionFixture()
        do {
            fixture.recorder.blocksFirstControl = true
            try await fixture.start()
            fixture.selectPane(at: 1)
            _ = try await fixture.recorder.heldControl.firstArrival()

            // Act
            fixture.selectPane(at: 2)
            await fixture.router.waitForPendingAttentionSettlement()
            fixture.selectPane(at: 3)
            await fixture.router.waitForPendingAttentionSettlement()
            #expect(fixture.recorder.events == [fixture.event(0, false)])
            fixture.recorder.releaseBlockedControl()
            await fixture.router.waitForPendingAttentionDelivery()
            try await fixture.stop()

            // Assert
            #expect(fixture.recorder.maximumConcurrentControls == 1)
            #expect(
                fixture.recorder.events == [
                    fixture.event(0, false), fixture.event(1, true),
                    fixture.event(1, false), fixture.event(2, true),
                    fixture.event(2, false), fixture.event(3, true),
                ])
            try await fixture.finish()
        } catch {
            await fixture.abort()
            throw error
        }
    }

    @Test("a backlog of settled transitions drains in order and accepts a later batch")
    func settledBacklogDrainsBeforeLaterBatch() async throws {
        let fixture = try AttentionFixture()
        do {
            fixture.recorder.blocksFirstControl = true
            try await fixture.start()
            fixture.selectPane(at: 1)
            _ = try await fixture.recorder.heldControl.firstArrival()
            var expected = [fixture.event(0, false), fixture.event(1, true)]
            var previous = 1
            for transition in 2...257 {
                let next = transition % fixture.paneIDs.count
                fixture.selectPane(at: next)
                await fixture.router.waitForPendingAttentionSettlement()
                expected.append(contentsOf: [fixture.event(previous, false), fixture.event(next, true)])
                previous = next
            }
            #expect(fixture.recorder.events == [fixture.event(0, false)])
            fixture.recorder.releaseBlockedControl()
            await fixture.router.waitForPendingAttentionDelivery()
            #expect(fixture.recorder.events == expected)

            let next = (previous + 1) % fixture.paneIDs.count
            fixture.selectPane(at: next)
            await fixture.router.waitForPendingAttentionDelivery()
            expected.append(contentsOf: [fixture.event(previous, false), fixture.event(next, true)])
            try await fixture.stop()
            #expect(fixture.recorder.events == expected)
            #expect(fixture.recorder.maximumConcurrentControls == 1)
            try await fixture.finish()
        } catch {
            await fixture.abort()
            throw error
        }
    }

    @Test("stop ignores attention changes and a later start arms again")
    func stopAndRestartPreserveAttentionLifecycle() async throws {
        // Arrange
        let fixture = try AttentionFixture()
        do {
            try await fixture.start()
            fixture.selectPane(at: 1)
            await fixture.router.waitForPendingAttentionDelivery()
            try await fixture.stop()
            let stoppedEvents = fixture.recorder.events

            // Act
            fixture.selectPane(at: 2)
            await fixture.router.waitForPendingAttentionDelivery()
            #expect(fixture.recorder.events == stoppedEvents)
            try await fixture.start()
            fixture.selectPane(at: 3)
            await fixture.router.waitForPendingAttentionDelivery()
            try await fixture.stop()

            // Assert
            #expect(fixture.recorder.events == stoppedEvents + [fixture.event(2, false), fixture.event(3, true)])
            try await fixture.finish()
        } catch {
            await fixture.abort()
            throw error
        }
    }

    @Test("restart waits for a suspended stop and preserves the new attention binding")
    func restartWaitsForSuspendedStop() async throws {
        // Arrange
        let fixture = try AttentionFixture()
        var stopTask: Task<Void, Never>?
        var restartTask: Task<Void, Never>?
        do {
            fixture.recorder.blocksFirstControl = true
            try await fixture.start()
            fixture.selectPane(at: 1)
            _ = try await fixture.recorder.heldControl.firstArrival()
            stopTask = Task { await fixture.router.stop() }
            let stopping = try await fixture.routerFacts.expectNextLifecycleEnqueued(.stop)
            try await fixture.recorder.heldControl.cancellationObserved()

            // Act
            restartTask = Task { @MainActor in await fixture.router.start() }
            let restarting = try await fixture.routerFacts.expectNextLifecycleEnqueued(.start)
            fixture.recorder.releaseBlockedControl()
            await stopTask?.value
            await restartTask?.value
            _ = try await fixture.routerFacts.expectLifecycleCompleted(in: stopping)
            _ = try await fixture.routerFacts.expectLifecycleCompleted(in: restarting)
            // Reinstall only the test recorder after verifying the real binding exists.
            #expect(Ghostty.ActionRouter.terminalActivityProjectionContext(paneID: fixture.paneIDs[1]) != nil)
            let scrollbar = ScrollbarState(top: 0, bottom: 10, total: 10)
            await Ghostty.ActionRouter.submitTerminalActivityInput(
                .aggregate(
                    surfaceID: fixture.paneIDs[1], paneID: fixture.paneIDs[1],
                    input: TerminalActivityAggregateInput(
                        aggregate: TerminalScrollbarActivityAggregate(state: scrollbar, observedAtMilliseconds: 1000),
                        latestState: scrollbar,
                        context: TerminalActivityProjectionContext(
                            isAttended: true, isAgentClassified: false, outputBurstThreshold: 1
                        )
                    )
                ))
            #expect(fixture.activityAtom.snapshot(for: fixture.paneIDs[1])?.scrollbarState == scrollbar)
            try await fixture.start()
            fixture.selectPane(at: 2)
            await fixture.router.waitForPendingAttentionDelivery()
            try await fixture.stop()

            // Assert
            #expect(
                fixture.recorder.events == [
                    fixture.event(0, false), fixture.event(1, false), fixture.event(2, true),
                ])
            #expect(fixture.recorder.maximumConcurrentControls == 1)
            try await fixture.finish()
        } catch {
            fixture.recorder.releaseBlockedControl()
            await stopTask?.value
            await restartTask?.value
            await fixture.abort()
            throw error
        }
    }

    @Test("caller attendance resolver can suppress an active anchor")
    func preservesCallerAttendanceAuthority() async throws {
        // Arrange
        let fixture = try AttentionFixture(attentionAllowed: false)
        do {
            try await fixture.start()

            // Act
            fixture.selectPane(at: 1)
            await fixture.router.waitForPendingAttentionDelivery()
            try await fixture.stop()

            // Assert
            #expect(fixture.recorder.events == [fixture.event(0, false), fixture.event(1, false)])
            try await fixture.finish()
        } catch {
            await fixture.abort()
            throw error
        }
    }

    @Test("settled attention cancels the real projector unseen window")
    func settledAttentionCancelsRealWindow() async throws {
        // Arrange: preserve the production activity-input binding.
        let fixture = try AttentionFixture()
        do {
            try await fixture.startWithRealInput()
            await fixture.seedUnseenWindow(at: 1)
            let bDeadline = try await fixture.deadlines.expectNextRegistration(paneID: fixture.paneIDs[1])

            // Act
            fixture.selectPane(at: 1)
            _ = try await fixture.deadlines.expectDisposition(for: bDeadline, .cancelled)
            await fixture.router.waitForPendingAttentionDelivery()
            await fixture.clock.waitForPendingSleepCount(exactly: 0)

            // Assert
            #expect(fixture.clock.pendingSleepCount == 0)
            try await fixture.stop()
            try await fixture.finish()
        } catch {
            await fixture.abort()
            throw error
        }
    }

    @Test("same-turn intermediate keeps its real unseen window while settled pane cancels")
    func intermediateAttentionPreservesRealWindow() async throws {
        // Arrange: both B and C have distinct pending windows.
        let fixture = try AttentionFixture()
        do {
            try await fixture.startWithRealInput()
            await fixture.seedUnseenWindow(at: 1)
            let bDeadline = try await fixture.deadlines.expectNextRegistration(paneID: fixture.paneIDs[1])
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            let bSleepGenerations = fixture.clock.pendingSleepGenerations
            await fixture.seedUnseenWindow(at: 2)
            let cDeadline = try await fixture.deadlines.expectNextRegistration(paneID: fixture.paneIDs[2])
            await fixture.clock.waitForPendingSleepCount(exactly: 2)

            // Act
            fixture.selectPane(at: 1)
            fixture.selectPane(at: 2)
            // Same-turn selection is coalesced into one settled old-pane -> C delivery;
            // C's cancellation is that delivery's closing fact.
            _ = try await fixture.deadlines.expectDisposition(for: cDeadline, .cancelled)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)

            // Assert
            #expect(fixture.clock.pendingSleepGenerations == bSleepGenerations)
            _ = try await fixture.deadlines.fire(bDeadline)
            try await fixture.stop()
            try await fixture.finish()
        } catch {
            await fixture.abort()
            throw error
        }
    }

    @Test("stopped router releases lifecycle and observation task ownership")
    func stoppedRouterCanDeallocate() async throws {
        // Arrange / Act
        let reference = try await stoppedRouterReference()

        // Assert
        #expect(reference.router == nil)
    }

    private func stoppedRouterReference() async throws -> WeakAttentionRouterReference {
        let fixture = try AttentionFixture()
        let reference = WeakAttentionRouterReference(router: fixture.router)
        do {
            try await fixture.start()
            fixture.selectPane(at: 1)
            await fixture.router.waitForPendingAttentionDelivery()
            try await fixture.stop()
            try await fixture.finish()
            return reference
        } catch {
            await fixture.abort()
            throw error
        }
    }

}

@MainActor
private final class AttentionFixture {
    let paneIDs = (0..<4).map { _ in UUIDv7.generate() }
    let tabLayout = WorkspaceTabLayoutAtom()
    let windowLifecycle = WindowLifecycleAtom()
    let managementLayer = ManagementLayerAtom()
    let recorder: AttentionControlRecorder
    let deadlines: TerminalActivityDeadlineFacts
    let routerFacts: FactRecorder<TerminalActivityRouterFactScope, TerminalActivityRouterFact>
    private let routerFactSource: TerminalActivityRouterFactSource
    let activityAtom = TerminalActivityAtom()
    let clock = TestPushClock()
    let bindingID = UUIDv7.generate()
    let tabID: UUID
    let router: TerminalActivityRouter

    init(attentionAllowed: Bool = true) throws {
        recorder = try AttentionControlRecorder()
        let deadlines = try TerminalActivityDeadlineFacts(clock: clock)
        self.deadlines = deadlines
        let routerFactSource = TerminalActivityRouterFactSource()
        self.routerFactSource = routerFactSource
        routerFacts = try routerFactSource.attach()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .seconds(2), clock: clock, factSink: deadlines.sink)
        let arrangement = PaneArrangement(
            name: "Default", isDefault: true, layout: Layout.autoTiled(paneIDs), activePaneId: paneIDs[0]
        )
        let tab = Tab(
            name: "Attention", allPaneIds: paneIDs, arrangements: [arrangement], activeArrangementId: arrangement.id
        )
        tabID = tab.id
        tabLayout.appendTab(tab)
        let windowID = UUIDv7.generate()
        windowLifecycle.recordWindowRegistered(windowID)
        windowLifecycle.recordWindowBecameKey(windowID)
        let attendedPane = AttendedPaneDerived(
            tabLayout: tabLayout, windowLifecycle: windowLifecycle, managementLayer: managementLayer
        )
        router = TerminalActivityRouter(
            bus: EventBus<RuntimeEnvelope>(), activityAtom: activityAtom, projector: projector,
            attendedPane: attendedPane,
            surfaceIDForPaneID: { $0 },
            isPaneCurrentlyAttended: { paneID in attentionAllowed && attendedPane.attendedPaneId == paneID },
            isPaneAgentClassified: { _, _ in false },
            lastOutputLineReader: { _ in .surfaceStale },
            unseenActivityDebounceDuration: .seconds(2), unseenActivityClock: clock,
            factSink: routerFactSource.sink
        )
    }

    func start() async throws {
        try await startWithRealInput()
        Ghostty.ActionRouter.bindTerminalActivityInput(
            id: bindingID,
            context: { _ in
                TerminalActivityProjectionContext(isAttended: false, isAgentClassified: false, outputBurstThreshold: 1)
            },
            sink: { [recorder] input in await recorder.record(input) }
        )
    }

    func stop() async throws {
        recorder.releaseBlockedControl()
        await router.stop()
        let stopping = try await routerFacts.expectNextLifecycleEnqueued(.stop)
        _ = try await routerFacts.expectLifecycleCompleted(in: stopping)
        Ghostty.ActionRouter.unbindTerminalActivityInput(id: bindingID)
    }

    func startWithRealInput() async throws {
        await router.start()
        let starting = try await routerFacts.expectNextLifecycleEnqueued(.start)
        _ = try await routerFacts.expectLifecycleCompleted(in: starting)
    }

    func finish() async throws {
        try await recorder.finish()
        try await deadlines.finish()
        try await routerFacts.finish()
    }

    func abort() async {
        recorder.releaseBlockedControl()
        await router.stop()
        Ghostty.ActionRouter.unbindTerminalActivityInput(id: bindingID)
        try? await recorder.finish()
        try? await deadlines.finish()
        try? await routerFacts.finish()
    }

    func seedUnseenWindow(at index: Int) async {
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(top: 0, bottom: 10, total: 100), observedAtMilliseconds: 1000
        )
        let latest = ScrollbarState(top: 0, bottom: 10, total: 140)
        aggregate.merge(state: latest, observedAtMilliseconds: 1100)
        await Ghostty.ActionRouter.submitTerminalActivityInput(
            .aggregate(
                surfaceID: paneIDs[index], paneID: paneIDs[index],
                input: TerminalActivityAggregateInput(
                    aggregate: aggregate, latestState: latest,
                    context: TerminalActivityProjectionContext(
                        isAttended: false, isAgentClassified: false, outputBurstThreshold: 30
                    )
                )
            ))
    }

    func selectPane(at index: Int) {
        tabLayout.setActivePane(paneIDs[index], inTab: tabID)
    }

    func event(_ index: Int, _ attended: Bool) -> AttentionControlRecorder.Event {
        .init(paneID: paneIDs[index], attended: attended)
    }
}

private struct AttentionControlScope: Hashable, Sendable {
    let callSequence: Int
}

@MainActor
private final class AttentionControlRecorder {
    struct Event: Equatable, Sendable {
        let paneID: UUID
        let attended: Bool
    }

    private enum ControlFact: Equatable, Sendable {
        case received(Event)
        case returned
    }

    var events: [Event] = []
    var blocksFirstControl = false
    let heldControl = HeldStep<Event>("first attention control", cancellation: .holdThroughCancellation)
    private(set) var maximumConcurrentControls = 0
    private var concurrentControls = 0
    private var nextCallSequence = 0
    private let source: LocalFactSource<AttentionControlScope, ControlFact>
    private let facts: FactRecorder<AttentionControlScope, ControlFact>

    init() throws {
        source = LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { "attention control \($0.callSequence)" },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .returned }
            )
        )
        facts = try source.attach()
    }

    func record(_ input: TerminalActivitySourceInput) async {
        guard case .orderedControl(_, let paneID, _, .contextChanged(let context)) = input else { return }
        nextCallSequence += 1
        let scope = AttentionControlScope(callSequence: nextCallSequence)
        let event = Event(paneID: paneID, attended: context.isAttended)
        concurrentControls += 1
        maximumConcurrentControls = max(maximumConcurrentControls, concurrentControls)
        defer { concurrentControls -= 1 }
        events.append(event)
        source.sink(scope, .received(event))
        if blocksFirstControl, scope.callSequence == 1 {
            do {
                try await heldControl.arrive(event)
            } catch {
                Issue.record("held attention control failed: \(error)")
            }
        }
        source.sink(scope, .returned)
    }

    func releaseBlockedControl() { heldControl.release() }

    func expectNextControl(_ expected: Event) async throws -> AttentionControlScope {
        let scope = try await facts.expectNextOperation(
            matching: { _ in true }, opening: { $0 == .received(expected) }, "attention control received")
        try await facts.expectNext(in: scope, .received(expected))
        try await facts.expectNext(in: scope, .returned)
        return scope
    }

    func finish() async throws { try await facts.finish() }
}

@MainActor
private final class WeakAttentionRouterReference {
    weak var router: TerminalActivityRouter?

    init(router: TerminalActivityRouter) { self.router = router }
}
