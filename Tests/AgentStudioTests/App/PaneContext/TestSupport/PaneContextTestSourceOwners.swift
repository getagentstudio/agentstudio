import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation

@testable import AgentStudio
@testable import AgentStudioCore

/// Test composition supplies canonical owners and an explicit clock to the real popover path.
@MainActor
struct PaneContextTestSourceOwners {
    let sessionStatus: SessionStatusAtom
    let presentation: PaneContextPresentationAtom
    let pane: @MainActor (PaneId) -> Pane?
    let serviceProvider: @MainActor () -> PaneContextUIAdapter?
    var performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    var activity: @MainActor (PaneId) -> PaneActivityTime? = { _ in nil }

    func bindings<SourceClock: Clock>(
        clock: SourceClock, wallNow: @escaping @Sendable () -> Date,
        observe: @escaping PaneContextPopoverOwnerObserver = { _, _ in }
    ) -> PaneContextPopoverHostBindings
    where SourceClock.Duration == Duration {
        PaneContextPopoverHostBindings(
            clock: clock, wallNow: wallNow,
            readSource: { id in
                let pane = pane(id)
                // Tests with a Pane fixture stand in for App's keyed graph getters; no shaping occurs here.
                let structural = pane.map { PaneStructuralFacts(state: PaneGraphState(pane: $0)) }
                return .init(
                    structuralFacts: structural, title: pane?.metadata.title, note: pane?.metadata.note,
                    session: sessionStatus.value(for: id), display: presentation.value(for: id), activity: activity(id))
            }, serviceProvider: serviceProvider, performanceTraceRecorder: performanceTraceRecorder, observe: observe)
    }

    func makeNativeHost(
        paneId: PaneId, entry: PaneContextPopoverEntry = .kind(.init(kind: .needsYou, count: 1)),
        location: PaneContextPopoverLocation = .pane, wallNow: Date,
        observesApplications: Bool = true, viewportWidth: CGFloat = 280
    ) -> PaneContextPreparedNativeHost {
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        time.shiftWallTime(by: wallNow.timeIntervalSince(time.now))
        return PaneContextPreparedNativeHost(
            paneId: paneId, sourceOwners: self, entry: entry, clock: clock,
            wallNow: { time.now }, bridge: bridge, location: location, observesApplications: observesApplications,
            viewportWidth: viewportWidth)
    }

    func makeNativeCardHost(
        context: PaneManagementContext, wallNow: Date,
        viewportWidth: CGFloat = 640
    ) -> PaneContextPreparedNativeHost {
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        time.shiftWallTime(by: wallNow.timeIntervalSince(time.now))
        return PaneContextPreparedNativeHost(
            context: context, sourceOwners: self, clock: clock,
            wallNow: { time.now }, bridge: bridge, viewportWidth: viewportWidth)
    }
}
