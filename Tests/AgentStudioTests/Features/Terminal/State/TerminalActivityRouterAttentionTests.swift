import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("TerminalActivityRouter attention ordering", .serialized)
struct TerminalActivityRouterAttentionTests {
    @Test("two activity fixtures keep controls separate across one fixture's retirement")
    func twoActivityFixturesKeepControlsSeparateAcrossRetirement() async {
        let first = AttentionFixture()
        let second = AttentionFixture()
        await first.start()
        await second.start()

        first.selectPane(at: 1)
        await first.joinPendingAttentionDelivery()
        #expect(first.recorder.events == [first.event(0, false), first.event(1, true)])
        #expect(second.recorder.events.isEmpty)
        await first.closeAndJoin()
        #expect(await first.applyObservedControl(at: 1) == .dropped(.retiredHandling))
        #expect(second.callbackContext(for: second.paneIDs[0]) != nil)

        second.selectPane(at: 2)
        await second.joinPendingAttentionDelivery()
        #expect(second.recorder.events == [second.event(0, false), second.event(2, true)])
        #expect(first.recorder.events == [first.event(0, false), first.event(1, true)])
        await second.closeAndJoin()
    }

    @Test("first settled attention change delivers previous off before current on")
    func firstSettledChangeIsObserved() async {
        // Arrange
        let fixture = AttentionFixture()
        await fixture.start()

        // Act
        fixture.selectPane(at: 1)
        await assertEventuallyMain("first attention pair") { fixture.recorder.events.count == 2 }
        await fixture.closeAndJoin()

        // Assert
        #expect(fixture.recorder.events == [fixture.event(0, false), fixture.event(1, true)])
    }

    @Test("same-turn intermediate attention never receives a control")
    func sameTurnChangesCoalesce() async {
        // Arrange
        let fixture = AttentionFixture()
        await fixture.start()

        // Act
        fixture.selectPane(at: 1)
        fixture.selectPane(at: 2)
        await assertEventuallyMain("settled attention pair") { fixture.recorder.events.count == 2 }
        await fixture.closeAndJoin()

        // Assert
        #expect(fixture.recorder.events == [fixture.event(0, false), fixture.event(2, true)])
    }
    @Test("separately settled turns survive an awaited control in order")
    func settledTurnsQueueBehindBlockedDelivery() async {
        // Arrange
        let fixture = AttentionFixture()
        fixture.recorder.blocksFirstControl = true
        await fixture.start()
        fixture.selectPane(at: 1)
        await assertEventuallyMain("first control entered") { fixture.recorder.isBlocked }
        guard fixture.recorder.isBlocked else {
            await fixture.closeAndJoin()
            return
        }

        // Act
        fixture.selectPane(at: 2)
        await fixture.joinPendingAttentionSettlement()
        fixture.selectPane(at: 3)
        await fixture.joinPendingAttentionSettlement()
        #expect(fixture.recorder.events == [fixture.event(0, false)])
        fixture.recorder.releaseBlockedControl()
        await fixture.joinPendingAttentionDelivery()
        await fixture.closeAndJoin()

        // Assert
        #expect(fixture.recorder.maximumConcurrentControls == 1)
        #expect(
            fixture.recorder.events == [
                fixture.event(0, false), fixture.event(1, true),
                fixture.event(1, false), fixture.event(2, true),
                fixture.event(2, false), fixture.event(3, true),
            ])
    }

    @Test("a backlog of settled transitions drains in order and accepts a later batch")
    func settledBacklogDrainsBeforeLaterBatch() async {
        let fixture = AttentionFixture()
        fixture.recorder.blocksFirstControl = true
        await fixture.start()
        fixture.selectPane(at: 1)
        await assertEventuallyMain("first control entered") { fixture.recorder.isBlocked }
        var expected = [fixture.event(0, false), fixture.event(1, true)]
        var previous = 1
        for transition in 2...257 {
            let next = transition % fixture.paneIDs.count
            fixture.selectPane(at: next)
            await fixture.joinPendingAttentionSettlement()
            expected.append(contentsOf: [fixture.event(previous, false), fixture.event(next, true)])
            previous = next
        }
        #expect(fixture.recorder.events == [fixture.event(0, false)])
        fixture.recorder.releaseBlockedControl()
        await fixture.joinPendingAttentionDelivery()
        #expect(fixture.recorder.events == expected)

        let next = (previous + 1) % fixture.paneIDs.count
        fixture.selectPane(at: next)
        await fixture.joinPendingAttentionDelivery()
        expected.append(contentsOf: [fixture.event(previous, false), fixture.event(next, true)])
        await fixture.closeAndJoin()
        #expect(fixture.recorder.events == expected)
        #expect(fixture.recorder.maximumConcurrentControls == 1)
    }

    @Test("stop ignores attention changes and a later start arms again")
    func stopAndRestartPreserveAttentionLifecycle() async {
        // Arrange
        let fixture = AttentionFixture()
        await fixture.start()
        fixture.selectPane(at: 1)
        await fixture.joinPendingAttentionDelivery()
        await fixture.stop()
        let stoppedEvents = fixture.recorder.events

        // Act
        fixture.selectPane(at: 2)
        await fixture.joinPendingAttentionDelivery()
        #expect(fixture.recorder.events == stoppedEvents)
        await fixture.start()
        fixture.selectPane(at: 3)
        await fixture.joinPendingAttentionDelivery()
        await fixture.closeAndJoin()

        // Assert
        #expect(fixture.recorder.events == stoppedEvents + [fixture.event(2, false), fixture.event(3, true)])
    }

    @Test("restart waits for a suspended stop and preserves its injected callback handler")
    func restartWaitsForSuspendedStop() async {
        // Arrange
        let fixture = AttentionFixture()
        fixture.recorder.blocksFirstControl = true
        await fixture.start()
        fixture.selectPane(at: 1)
        await assertEventuallyMain("control suspended") { fixture.recorder.isBlocked }
        guard fixture.recorder.isBlocked else {
            await fixture.closeAndJoin()
            return
        }
        let stopTask = Task { await fixture.stop() }
        await assertEventuallyMain("stop cancelled the delivery") { fixture.recorder.cancellation.wasObserved }
        guard fixture.recorder.cancellation.wasObserved else {
            fixture.recorder.releaseBlockedControl()
            await stopTask.value
            await fixture.closeAndJoin()
            return
        }

        // Act
        var restartRequested = false
        let restartTask = Task { @MainActor in
            restartRequested = true
            await fixture.start()
        }
        await assertEventuallyMain("restart requested during stop") { restartRequested }
        fixture.recorder.releaseBlockedControl()
        await stopTask.value
        await restartTask.value
        // The same fixture-owned handler and its context remain selected after restart.
        #expect(fixture.callbackContext(for: fixture.paneIDs[1]) != nil)
        let scrollbar = ScrollbarState(top: 0, bottom: 10, total: 10)
        await fixture.submitSourceInput(
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
        await fixture.start()
        fixture.selectPane(at: 2)
        await fixture.joinPendingAttentionDelivery()
        await fixture.closeAndJoin()

        // Assert
        #expect(
            fixture.recorder.events == [
                fixture.event(0, false), fixture.event(1, false), fixture.event(2, true),
            ])
        #expect(fixture.recorder.maximumConcurrentControls == 1)
    }

    @Test("caller attendance resolver can suppress an active anchor")
    func preservesCallerAttendanceAuthority() async {
        // Arrange
        let fixture = AttentionFixture(attentionAllowed: false)
        await fixture.start()

        // Act
        fixture.selectPane(at: 1)
        await fixture.joinPendingAttentionDelivery()
        await fixture.closeAndJoin()

        // Assert
        #expect(fixture.recorder.events == [fixture.event(0, false), fixture.event(1, false)])
    }

    @Test("settled attention cancels the real projector unseen window")
    func settledAttentionCancelsRealWindow() async {
        // Arrange: route activity inputs through the fixture-owned host into the real router.
        let fixture = AttentionFixture()
        await fixture.start()
        await fixture.seedUnseenWindow(at: 1)
        await assertEventuallyMain("B unseen window scheduled") { fixture.clock.pendingSleepCount == 1 }
        guard fixture.clock.pendingSleepCount == 1 else {
            await fixture.closeAndJoin()
            return
        }

        // Act
        fixture.selectPane(at: 1)
        await assertEventuallyMain("B attendance cancels its unseen window") { fixture.clock.pendingSleepCount == 0 }

        // Assert
        #expect(fixture.clock.pendingSleepCount == 0)
        await fixture.closeAndJoin()
    }

    @Test("same-turn intermediate keeps its real unseen window while settled pane cancels")
    func intermediateAttentionPreservesRealWindow() async {
        // Arrange: both B and C have distinct pending windows.
        let fixture = AttentionFixture()
        await fixture.start()
        await fixture.seedUnseenWindow(at: 1)
        await assertEventuallyMain("B window scheduled") { fixture.clock.pendingSleepCount == 1 }
        let bSleepGenerations = fixture.clock.pendingSleepGenerations
        await fixture.seedUnseenWindow(at: 2)
        await assertEventuallyMain("B and C windows scheduled") { fixture.clock.pendingSleepCount == 2 }
        guard bSleepGenerations.count == 1, fixture.clock.pendingSleepCount == 2 else {
            await fixture.closeAndJoin()
            return
        }

        // Act
        fixture.selectPane(at: 1)
        fixture.selectPane(at: 2)
        await assertEventuallyMain("only C window cancelled") {
            fixture.clock.pendingSleepGenerations == bSleepGenerations
        }

        // Assert
        #expect(fixture.clock.pendingSleepGenerations == bSleepGenerations)
        await fixture.closeAndJoin()
    }

    @Test("stopped router releases lifecycle and observation task ownership")
    func stoppedRouterCanDeallocate() async {
        // Arrange / Act
        let reference = await stoppedRouterReference()

        // Assert
        #expect(reference.router == nil)
    }

    private func stoppedRouterReference() async -> WeakAttentionRouterReference {
        let fixture = AttentionFixture()
        let reference = fixture.weakRouterReference()
        await fixture.start()
        fixture.selectPane(at: 1)
        await fixture.joinPendingAttentionDelivery()
        await fixture.closeAndJoin()
        return reference
    }

}

@MainActor
private final class AttentionFixture {
    let paneIDs = (0..<4).map { _ in UUIDv7.generate() }
    let tabLayout = WorkspaceTabLayoutAtom()
    let windowLifecycle = WindowLifecycleAtom()
    let managementLayer = ManagementLayerAtom()
    let recorder: AttentionControlRecorder
    let activityAtom = TerminalActivityAtom()
    let clock = TestPushClock()
    let tabID: UUID
    private lazy var routingLookup = AttentionRoutingLookup()
    private lazy var mountedHostResolver = TerminalLocalActionMountedHostResolver(
        surfaceForID: { _ in nil },
        paneIDForSurfaceID: { _ in nil }
    )
    private lazy var host: GhosttyActionRoutingHost = .init(
        dependencies: .init(
            runtimeRegistry: RuntimeRegistry(),
            routingLookup: routingLookup,
            mountedHostResolver: mountedHostResolver,
            applyNativeView: { _, _, _ in .dropped(.staleSurface) },
            activityContext: { [weak self] paneID in
                self?.router.sourceInputContext(paneID: paneID)
            },
            submitActivityInput: { [weak self] input in
                guard let self else { return }
                await self.recorder.record(input)
                await self.router.consumeSourceInputIfAccepting(input)
            },
            startupTraceRecorder: nil,
            traceRuntime: nil
        )
    )
    private lazy var handler: Ghostty.ActionRouter = .init(host: host)
    private lazy var router: TerminalActivityRouter = .init(
        bus: EventBus<RuntimeEnvelope>(),
        activityAtom: activityAtom,
        callbackHandlingAccess: { [weak self] in self?.handler },
        attendedPane: attendedPane,
        surfaceIDForPaneID: { $0 },
        isPaneCurrentlyAttended: { [weak self] paneID in
            guard let self else { return false }
            return self.attentionAllowed && self.attendedPane.attendedPaneId == paneID
        },
        isPaneAgentClassified: { _, _ in false },
        lastOutputLineReader: { _ in .surfaceStale },
        unseenActivityDebounceDuration: .seconds(2),
        unseenActivityClock: clock
    )
    private let attentionAllowed: Bool
    private let attendedPane: AttendedPaneDerived

    init(attentionAllowed: Bool = true) {
        self.attentionAllowed = attentionAllowed
        let recorder = AttentionControlRecorder()
        self.recorder = recorder
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
        self.attendedPane = attendedPane
    }

    func start() async {
        await router.start()
    }

    func stop() async {
        await router.stop()
    }

    func closeAndJoin() async {
        recorder.releaseBlockedControl()
        await router.stop()
        await handler.retire()
    }

    func joinPendingAttentionSettlement() async {
        await router.waitForPendingAttentionSettlement()
    }

    func joinPendingAttentionDelivery() async {
        await router.waitForPendingAttentionDelivery()
    }

    func callbackContext(for paneID: UUID) -> TerminalActivityProjectionContext? {
        host.activityContext(paneID)
    }

    func weakRouterReference() -> WeakAttentionRouterReference {
        WeakAttentionRouterReference(router: router)
    }

    func applyObservedControl(at index: Int) async -> GhosttyDeferredApplyResult {
        let paneID = paneIDs[index]
        return await handler.applyOrderedActivityControl(
            surfaceID: paneID, paneID: paneID, control: .observed
        )
    }

    func submitSourceInput(_ input: TerminalActivitySourceInput) async {
        await host.submitActivityInput(input)
    }

    func seedUnseenWindow(at index: Int) async {
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(top: 0, bottom: 10, total: 100), observedAtMilliseconds: 1000
        )
        let latest = ScrollbarState(top: 0, bottom: 10, total: 140)
        aggregate.merge(state: latest, observedAtMilliseconds: 1100)
        await host.submitActivityInput(
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

@MainActor
private final class AttentionRoutingLookup: GhosttyActionRoutingLookup {
    func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID? { nil }

    func paneId(for surfaceId: UUID) -> UUID? { nil }
}

@MainActor
private final class AttentionControlRecorder {
    struct Event: Equatable {
        let paneID: UUID
        let attended: Bool
    }

    var events: [Event] = []
    var blocksFirstControl = false
    let cancellation = AttentionCancellationProbe()
    private(set) var isBlocked = false
    private(set) var maximumConcurrentControls = 0
    private var concurrentControls = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    func record(_ input: TerminalActivitySourceInput) async {
        guard case .orderedControl(_, let paneID, _, .contextChanged(let context)) = input else { return }
        concurrentControls += 1
        maximumConcurrentControls = max(maximumConcurrentControls, concurrentControls)
        defer { concurrentControls -= 1 }
        events.append(Event(paneID: paneID, attended: context.isAttended))
        if blocksFirstControl, events.count == 1 {
            let cancellation = self.cancellation
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    blockedContinuation = continuation
                    isBlocked = true
                }
            } onCancel: {
                cancellation.record()
            }
        }
    }

    func releaseBlockedControl() {
        let continuation = blockedContinuation
        blockedContinuation = nil
        isBlocked = false
        continuation?.resume()
    }
}

private final class AttentionCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    var wasObserved: Bool { lock.withLock { observed } }

    func record() { lock.withLock { observed = true } }
}

@MainActor
private final class WeakAttentionRouterReference {
    weak var router: TerminalActivityRouter?

    init(router: TerminalActivityRouter) { self.router = router }
}
