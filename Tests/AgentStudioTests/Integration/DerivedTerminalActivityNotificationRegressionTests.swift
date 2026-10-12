import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Derived terminal activity notification regressions", .serialized)
struct DerivedTerminalActivityNotificationRegressionTests {
    private struct Fixture {
        let inboxAtom: InboxNotificationAtom
        let paneAtom: WorkspacePaneAtom
        let tabLayout: WorkspaceTabLayoutAtom
        let windowLifecycle: WindowLifecycleAtom
        let attendedPane: AttendedPaneDerived
        let tracker: PaneFocusTracker
        let terminalActivity: TerminalActivityAtom
        let inboxRouter: InboxNotificationRouter
        let terminalRouter: TerminalActivityRouter
        let callbackFixture: TerminalActivityCallbackTestFixture

        @MainActor
        func shutdown() async {
            await callbackFixture.closeAndJoin()
            await terminalRouter.stop()
            await inboxRouter.stop()
            await tracker.stop()
        }
    }

    private final class TerminalRouterBox {
        var router: TerminalActivityRouter?
    }

    @Test("transient entry to bottom clears observed pane unread state before final unpinned state")
    func transientEntryToBottomClearsObservedPaneUnreadState() async {
        let fixture = await makeFixture()
        let paneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(paneId, to: fixture)
        makeWindowKey(fixture.windowLifecycle)
        await waitForAttendedPane(
            paneId.uuid,
            in: fixture,
            description: "pane should be attended before receiving pinned edges"
        )
        fixture.inboxAtom.append(
            InboxNotification(
                id: UUIDv7.generate(),
                timestamp: Date(timeIntervalSince1970: 100),
                kind: .unseenActivity,
                title: "Output available",
                body: nil,
                source: .pane(.init(paneId: paneId.uuid)),
                isRead: false,
                isDismissedFromPaneInbox: false
            )
        )
        let states = [
            ScrollbarState(top: 0, bottom: 10, total: 100),
            ScrollbarState(top: 90, bottom: 100, total: 100),
            ScrollbarState(top: 0, bottom: 10, total: 100),
        ]

        await fixture.terminalRouter.consumeTerminalActivityInput(
            .aggregate(
                surfaceID: paneId.uuid,
                paneID: paneId.uuid,
                input: TerminalActivityAggregateInput(
                    aggregate: makeAggregate(states: states),
                    latestState: states[2],
                    context: TerminalActivityProjectionContext(
                        isAttended: true,
                        isAgentClassified: false,
                        outputBurstThreshold: fixture.terminalActivity.outputBurstThreshold
                    )
                )
            )
        )

        await assertEventuallyMain("transient pinned entry should clear the observed pane notification") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox
                && fixture.inboxAtom.globalUnreadCount == 0
        }
        #expect(fixture.terminalActivity.snapshot(for: paneId.uuid)?.scrollbarState == states[2])

        await fixture.shutdown()
    }

    private func makeFixture() async -> Fixture {
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
                terminalRouterBox.router?.markUnseenActivityObserved(paneId: paneId)
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
            inboxAtom: inboxAtom,
            paneAtom: paneAtom,
            tabLayout: tabLayout,
            windowLifecycle: windowLifecycle,
            attendedPane: attendedPane,
            tracker: tracker,
            terminalActivity: terminalActivity,
            inboxRouter: inboxRouter,
            terminalRouter: terminalRouter,
            callbackFixture: callbackFixture
        )
    }

    @discardableResult
    private func addTerminalPane(
        _ paneId: PaneId,
        to fixture: Fixture
    ) -> UUID {
        let metadata = PaneMetadata(
            paneId: paneId,
            contentType: .terminal,
            title: "Terminal"
        )
        let pane = Pane(
            id: paneId.uuid,
            content: .terminal(
                TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())
            ),
            metadata: metadata
        )
        fixture.paneAtom.addPane(pane)

        let arrangement = PaneArrangement(
            name: "Default",
            isDefault: true,
            layout: Layout(paneId: pane.id)
        )
        let tab = Tab(
            name: "Tab",
            panes: [pane.id],
            arrangements: [arrangement],
            activeArrangementId: arrangement.id,
            activePaneId: pane.id
        )
        fixture.tabLayout.appendTab(tab)
        return tab.id
    }

    private func makeWindowKey(_ atom: WindowLifecycleAtom) {
        let id = UUID()
        atom.recordWindowRegistered(id)
        atom.recordWindowBecameKey(id)
    }

    private func waitForAttendedPane(
        _ paneId: UUID,
        in fixture: Fixture,
        description: String
    ) async {
        await assertEventuallyMain(description) {
            fixture.attendedPane.attendedPaneId == paneId
        }
    }

    private func makeAggregate(states: [ScrollbarState]) -> TerminalScrollbarActivityAggregate {
        let firstState = states[0]
        var aggregate = TerminalScrollbarActivityAggregate(
            state: firstState,
            observedAtMilliseconds: 1000
        )
        for (index, state) in states.dropFirst().enumerated() {
            aggregate.merge(
                state: state,
                observedAtMilliseconds: 1100 + Int64(index * 100)
            )
        }
        return aggregate
    }
}
