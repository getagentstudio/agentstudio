import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

extension DerivedActivityNotificationIntegrationTests {
    struct Fixture {
        let bus: EventBus<RuntimeEnvelope>
        let inboxAtom: InboxNotificationAtom
        let prefsAtom: InboxNotificationPrefsAtom
        let paneAtom: WorkspacePaneAtom
        let tabLayout: WorkspaceTabLayoutAtom
        let windowLifecycle: WindowLifecycleAtom
        let managementLayer: ManagementLayerAtom
        let attendedPane: AttendedPaneDerived
        let tracker: PaneFocusTracker
        let terminalActivity: TerminalActivityAtom
        let inboxRouter: InboxNotificationRouter
        let terminalRouter: TerminalActivityRouter
        let callbackFixture: TerminalActivityCallbackTestFixture
        let terminalRouterBox: TerminalRouterBox
        let clock: TestPushClock
        let paneActivityObservationRecorder: PaneActivityObservationRecorder
        let eventRecorder: RecordingSubscriber<RuntimeEnvelope>

        @MainActor
        func shutdown() async {
            await callbackFixture.closeAndJoin()
            await terminalRouter.stop()
            await inboxRouter.stop()
            await tracker.stop()
            await eventRecorder.shutdown()
        }
    }

    @MainActor
    final class TerminalRouterBox {
        var router: TerminalActivityRouter?
        private var latestObservationTask: Task<Void, Never>?

        func observeActivity(for paneId: UUID) {
            guard let router else { return }
            latestObservationTask = Task { @MainActor in
                await router.consumeTerminalActivityInput(
                    .orderedControl(
                        surfaceID: paneId,
                        paneID: paneId,
                        precedingAggregate: nil,
                        control: .observed
                    )
                )
            }
        }

        func joinLatestObservation() async {
            await latestObservationTask?.value
        }
    }
    final class PaneActivityObservationRecorder {
        private(set) var paneIds: [UUID] = []

        func record(_ paneId: UUID) {
            paneIds.append(paneId)
        }
    }

    func makeFixture() async -> Fixture {
        let bus = EventBus<RuntimeEnvelope>()
        let inboxAtom = InboxNotificationAtom()
        let prefsAtom = InboxNotificationPrefsAtom()
        let paneAtom = WorkspacePaneAtom()
        let tabLayout = WorkspaceTabLayoutAtom()
        let windowLifecycle = WindowLifecycleAtom()
        let managementLayer = ManagementLayerAtom()
        let attendedPane = AttendedPaneDerived(
            tabLayout: tabLayout,
            windowLifecycle: windowLifecycle,
            managementLayer: managementLayer
        )
        let tracker = PaneFocusTracker(attendedPane: attendedPane)
        let terminalActivity = TerminalActivityAtom(
            outputBurstThreshold: AppPolicies.InboxNotification.terminalActivityOutputBurstThresholdRows
        )
        let clock = TestPushClock()
        let terminalRouterBox = TerminalRouterBox()
        let paneActivityObservationRecorder = PaneActivityObservationRecorder()
        let eventRecorder = RecordingSubscriber(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function))
        let drawerView: @MainActor (UUID) -> DrawerView? = { parentPaneId in
            guard let drawer = paneAtom.pane(parentPaneId)?.drawer,
                let tabId = tabLayout.tabContaining(paneId: parentPaneId)?.id
            else {
                return nil
            }
            return tabLayout.arrangementAtom.arrangementState(tabId)?.arrangements
                .first { $0.id == tabLayout.tab(tabId)?.activeArrangementId }?
                .drawerViews[drawer.drawerId]
        }
        let inboxRouter = InboxNotificationRouter(
            bus: bus,
            inboxAtom: inboxAtom,
            prefsAtom: prefsAtom,
            paneAtom: paneAtom,
            tabLayout: tabLayout,
            attendedPane: attendedPane,
            focusTracker: tracker,
            terminalIsPinnedToBottom: { paneId in
                terminalActivity.snapshot(for: paneId)?.isPinnedToBottom == true
            },
            terminalPinnedStateSnapshot: {
                terminalActivity.snapshotsByPaneId.mapValues(\.isPinnedToBottom)
            },
            drawerView: drawerView,
            onPaneActivityObserved: { paneId in
                paneActivityObservationRecorder.record(paneId)
                terminalRouterBox.observeActivity(for: paneId)
            }
        )
        let callbackFixture = TerminalActivityCallbackTestFixture()
        let terminalRouter = TerminalActivityRouter(
            bus: bus,
            activityAtom: terminalActivity,
            callbackHandlingAccess: { callbackFixture.handler },
            attendedPane: attendedPane,
            surfaceIDForPaneID: { $0 },
            isPaneCurrentlyAttended: {
                PaneObservationResolver.isPaneCurrentlyAttended(
                    paneId: $0,
                    attendedPaneId: attendedPane.attendedPaneId,
                    pane: { paneAtom.pane($0) },
                    drawerView: drawerView
                )
            },
            lastOutputLineReader: { _ in .surfaceStale },
            unseenActivityDebounceDuration: AppPolicies.InboxNotification.terminalActivityQuietDebounceDuration,
            unseenActivityClock: clock
        )
        callbackFixture.router = terminalRouter
        terminalRouterBox.router = terminalRouter
        await inboxRouter.start()
        await terminalRouter.start()
        return Fixture(
            bus: bus,
            inboxAtom: inboxAtom,
            prefsAtom: prefsAtom,
            paneAtom: paneAtom,
            tabLayout: tabLayout,
            windowLifecycle: windowLifecycle,
            managementLayer: managementLayer,
            attendedPane: attendedPane,
            tracker: tracker,
            terminalActivity: terminalActivity,
            inboxRouter: inboxRouter,
            terminalRouter: terminalRouter,
            callbackFixture: callbackFixture,
            terminalRouterBox: terminalRouterBox,
            clock: clock,
            paneActivityObservationRecorder: paneActivityObservationRecorder,
            eventRecorder: eventRecorder
        )
    }

}
