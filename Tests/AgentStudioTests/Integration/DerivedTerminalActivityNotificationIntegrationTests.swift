import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Derived terminal activity notification integration", .serialized)
struct DerivedActivityNotificationIntegrationTests {
    @Test("drawer child output burst reaches parent PaneInbox through runtime bus")
    func drawerChildOutputBurstReachesParentPaneInboxThroughRuntimeBus() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        let drawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        fixture.paneAtom.toggleDrawer(for: parentPaneId.uuid)
        makeWindowKey(fixture.windowLifecycle)
        #expect(fixture.paneAtom.pane(parentPaneId.uuid)?.drawer?.isExpanded == false)

        await postScrollbackBurst(
            paneId: PaneId(existingUUID: drawerPane.id),
            to: fixture
        )

        await assertEventuallyMain("drawer child output burst should create one inbox row") {
            fixture.inboxAtom.notifications.count == 1
        }
        let notification = try #require(fixture.inboxAtom.notifications.first)
        let scope = PaneInboxScopeResolver.resolve(
            anchorPaneId: parentPaneId.uuid,
            pane: { fixture.paneAtom.pane($0) }
        )
        let visibleRows = PaneInboxNotificationPopover.relevantNotifications(
            paneIds: scope.paneIds,
            notifications: fixture.inboxAtom.notifications,
            contentMode: .activity
        )
        #expect(notification.kind == .unseenActivity)
        #expect(notification.paneId == drawerPane.id)
        #expect(notification.isRead == false)
        #expect(notification.isDismissedFromPaneInbox == false)
        #expect(scope.paneIds == [parentPaneId.uuid, drawerPane.id])
        #expect(visibleRows.map(\.id) == [notification.id])

        await fixture.shutdown()
    }

    @Test("continuous output bursts in same pane keep one unread row until observed")
    func continuousOutputBurstsInSamePaneKeepOneUnreadRowUntilObserved() async {
        let fixture = await makeFixture()
        let paneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(paneId, to: fixture)

        await postScrollbackBurst(paneId: paneId, to: fixture)
        await assertEventuallyMain("first output burst should create an inbox row") {
            fixture.inboxAtom.notifications.count == 1
        }
        await postScrollbackBurst(paneId: paneId, totals: [200, 220, 250], to: fixture, startingSeq: 10)
        let eventRecorder = fixture.eventRecorder
        await assertEventuallyAsync("two quiet-settled activity facts should reach the runtime bus") {
            await Self.settledActivities(from: eventRecorder).count == 2
        }

        await assertEventuallyMain("continuous output should not create another inbox row") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].activityContext?.latestRows == 250
        }
        #expect(fixture.inboxAtom.notifications[0].kind == .unseenActivity)
        #expect((fixture.inboxAtom.notifications[0].activityContext?.eventCount ?? 0) >= 2)
        #expect(fixture.inboxAtom.globalUnreadCount == 1)

        await fixture.shutdown()
    }

    @Test("read dismissed unseen activity row resets runtime window before quiet close")
    func readDismissedUnseenActivityRowResetsRuntimeWindowBeforeQuietClose() async throws {
        let fixture = await makeFixture()
        let paneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(paneId, to: fixture)

        await postScrollbackBurst(paneId: paneId, to: fixture)
        await assertEventuallyMain("first output burst should create an inbox row") {
            fixture.inboxAtom.notifications.count == 1
        }
        let firstNotification = try #require(fixture.inboxAtom.notifications.first)
        #expect(fixture.inboxAtom.markRead(id: firstNotification.id) == true)
        #expect(fixture.inboxAtom.dismissFromPaneInbox(id: firstNotification.id) == true)
        await waitForRecordedActivityObservation(paneId: paneId.uuid, in: fixture)

        await postScrollbackBurst(paneId: paneId, totals: [200, 220, 240], to: fixture, startingSeq: 10)

        await assertEventuallyMain("observed row should let the next burst create a fresh unread row") {
            fixture.inboxAtom.notifications.count == 2
                && fixture.inboxAtom.notifications.last?.isRead == false
                && fixture.inboxAtom.notifications.last?.isDismissedFromPaneInbox == false
        }
        #expect(fixture.inboxAtom.globalUnreadCount == 1)

        await fixture.shutdown()
    }

    @Test("marking unseen activity read resets runtime window before quiet close")
    func markingUnseenActivityReadResetsRuntimeWindowBeforeQuietClose() async throws {
        let fixture = await makeFixture()
        let paneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(paneId, to: fixture)

        await postScrollbackBurst(paneId: paneId, to: fixture)
        await assertEventuallyMain("first output burst should create an inbox row") {
            fixture.inboxAtom.notifications.count == 1
        }
        let firstNotification = try #require(fixture.inboxAtom.notifications.first)
        fixture.inboxAtom.toggleReadState(id: firstNotification.id)
        #expect(fixture.inboxAtom.notifications[0].isRead == true)
        #expect(fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false)
        await waitForRecordedActivityObservation(paneId: paneId.uuid, in: fixture)

        await postScrollbackBurst(paneId: paneId, totals: [200, 220, 240], to: fixture, startingSeq: 10)

        await assertEventuallyMain("read-only observation should let the next burst create a fresh row") {
            fixture.inboxAtom.notifications.count == 2
                && fixture.inboxAtom.notifications.last?.isRead == false
                && fixture.inboxAtom.notifications.last?.isDismissedFromPaneInbox == false
        }
        #expect(fixture.inboxAtom.globalUnreadCount == 1)

        await fixture.shutdown()
    }

    @Test("two drawer children create separate parent PaneInbox rows")
    func twoDrawerChildrenCreateSeparateParentPaneInboxRows() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        let firstDrawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        let secondDrawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        fixture.paneAtom.toggleDrawer(for: parentPaneId.uuid)
        makeWindowKey(fixture.windowLifecycle)

        await postScrollbackBurst(
            paneId: PaneId(existingUUID: firstDrawerPane.id),
            pinnedToBottom: true,
            to: fixture
        )
        await postScrollbackBurst(
            paneId: PaneId(existingUUID: secondDrawerPane.id),
            to: fixture,
            startingSeq: 10
        )

        await assertEventuallyMain("both drawer children should create separate inbox rows") {
            fixture.inboxAtom.notifications.count == 2
        }
        let scope = PaneInboxScopeResolver.resolve(
            anchorPaneId: parentPaneId.uuid,
            pane: { fixture.paneAtom.pane($0) }
        )
        let visibleRows = PaneInboxNotificationPopover.relevantNotifications(
            paneIds: scope.paneIds,
            notifications: fixture.inboxAtom.notifications,
            contentMode: .activity
        )
        #expect(Set(visibleRows.compactMap(\.paneId)) == Set([firstDrawerPane.id, secondDrawerPane.id]))
        #expect(visibleRows.allSatisfy { $0.kind == .unseenActivity })
        #expect(visibleRows.allSatisfy { !$0.isRead && !$0.isDismissedFromPaneInbox })
        #expect(fixture.inboxAtom.globalUnreadCount == 2)

        await fixture.shutdown()
    }

    @Test("active drawer child switch observes current unseen activity window")
    func activeDrawerChildSwitchObservesCurrentUnseenActivityWindow() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        let firstDrawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        let secondDrawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        makeWindowKey(fixture.windowLifecycle)
        #expect(drawerView(for: parentPaneId.uuid, in: fixture)?.activeChildId == secondDrawerPane.id)

        await postScrollbackBurst(
            paneId: PaneId(existingUUID: firstDrawerPane.id),
            pinnedToBottom: true,
            to: fixture
        )
        await assertEventuallyMain("first child output burst should create an inbox row") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == false
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false
        }

        setActiveDrawerPane(firstDrawerPane.id, parentPaneId: parentPaneId.uuid, in: fixture)
        await waitForRecordedActivityObservation(paneId: firstDrawerPane.id, in: fixture)
        await assertEventuallyMain("active drawer child switch should clear the observed child row") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == true
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == true
                && fixture.inboxAtom.globalUnreadCount == 0
        }
        fixture.paneAtom.toggleDrawer(for: parentPaneId.uuid)
        await postScrollbackBurst(
            paneId: PaneId(existingUUID: firstDrawerPane.id),
            totals: [200, 220, 240],
            to: fixture,
            startingSeq: 10
        )

        await assertEventuallyMain("output after active-child observation should be a fresh derived burst") {
            fixture.inboxAtom.notifications.count == 2
                && fixture.inboxAtom.notifications.last?.isRead == false
                && fixture.inboxAtom.notifications.last?.isDismissedFromPaneInbox == false
        }
        #expect(fixture.inboxAtom.globalUnreadCount == 1)

        await fixture.shutdown()
    }

    @Test("focused pane output burst does not create a PaneInbox row")
    func focusedPaneOutputBurstDoesNotCreatePaneInboxRow() async {
        let fixture = await makeFixture()
        let paneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(paneId, to: fixture)
        makeWindowKey(fixture.windowLifecycle)
        await waitForAttendedPane(
            paneId.uuid,
            in: fixture,
            description: "focused pane should be attended before output burst"
        )

        await postScrollbackBurst(paneId: paneId, to: fixture, settle: false)

        await assertEventuallyMain("focused pane burst should still update activity state") {
            fixture.terminalActivity.snapshot(for: paneId.uuid)?.outputBurst.thresholdReached == true
        }
        #expect(fixture.inboxAtom.notifications.isEmpty)

        await fixture.shutdown()
    }

    @Test("focused drawer child output burst does not create a PaneInbox row")
    func focusedDrawerChildOutputBurstDoesNotCreatePaneInboxRow() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        let drawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        makeWindowKey(fixture.windowLifecycle)
        await waitForTerminalRouterAttendance(
            paneId: drawerPane.id,
            in: fixture,
            description: "focused drawer child should be attended before output burst"
        )

        await postScrollbackBurst(paneId: PaneId(existingUUID: drawerPane.id), to: fixture, settle: false)

        await assertEventuallyMain("focused drawer child burst should still update activity state") {
            fixture.terminalActivity.snapshot(for: drawerPane.id)?.outputBurst.thresholdReached == true
        }
        #expect(fixture.inboxAtom.notifications.isEmpty)

        await fixture.shutdown()
    }

    @Test("main pane hidden by open drawer emits unseen activity")
    func mainPaneHiddenByOpenDrawerEmitsUnseenActivity() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        _ = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        makeWindowKey(fixture.windowLifecycle)

        await postScrollbackBurst(paneId: parentPaneId, to: fixture)

        await assertEventuallyMain("hidden main pane activity should create one inbox row") {
            fixture.inboxAtom.notifications.count == 1
        }
        #expect(fixture.inboxAtom.notifications[0].paneId == parentPaneId.uuid)
        #expect(fixture.inboxAtom.notifications[0].kind == .unseenActivity)
        #expect(fixture.inboxAtom.notifications[0].isRead == false)
        #expect(fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false)

        await fixture.shutdown()
    }

    @Test("visible split sibling stays observed while active pane drawer is open")
    func visibleSplitSiblingStaysObservedWhileActivePaneDrawerIsOpen() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        let visibleSiblingPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        addVisiblePaneToActiveTab(visibleSiblingPaneId, to: fixture)
        _ = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        makeWindowKey(fixture.windowLifecycle)

        await postScrollbackBurst(
            paneId: visibleSiblingPaneId,
            totals: [100, 120, 140],
            pinnedToBottom: true,
            to: fixture
        )

        await assertEventuallyMain("bottom-pinned visible sibling should append read history") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == true
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == true
        }
        #expect(fixture.inboxAtom.globalUnreadCount == 0)
        #expect(fixture.inboxAtom.notifications[0].paneId == visibleSiblingPaneId.uuid)
        #expect(fixture.inboxAtom.notifications[0].kind == .unseenActivity)

        await fixture.shutdown()
    }

    @Test("visible split sibling scrolled up emits unread activity for small output")
    func visibleSplitSiblingScrolledUpEmitsUnreadActivityForSmallOutput() async throws {
        let fixture = await makeFixture()
        let focusedPaneId = PaneId.generateUUIDv7()
        let visibleSiblingPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(focusedPaneId, to: fixture)
        addVisiblePaneToActiveTab(visibleSiblingPaneId, to: fixture)
        makeWindowKey(fixture.windowLifecycle)

        await postScrollbackBurst(
            paneId: visibleSiblingPaneId,
            totals: [100, 101],
            pinnedToBottom: false,
            to: fixture
        )

        await assertEventuallyMain("scrolled-up visible sibling small output should create unread activity") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == false
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false
        }
        let notification = try #require(fixture.inboxAtom.notifications.first)
        #expect(fixture.inboxAtom.globalUnreadCount == 1)
        #expect(notification.paneId == visibleSiblingPaneId.uuid)
        #expect(notification.kind == .unseenActivity)
        #expect(fixture.inboxAtom.visiblePaneInboxUnreadCount(forPaneIds: [visibleSiblingPaneId.uuid]) == 1)

        await fixture.shutdown()
    }

    @Test("visible split sibling pinned to bottom ignores small output")
    func visibleSplitSiblingPinnedToBottomIgnoresSmallOutput() async {
        let fixture = await makeFixture()
        let focusedPaneId = PaneId.generateUUIDv7()
        let visibleSiblingPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(focusedPaneId, to: fixture)
        addVisiblePaneToActiveTab(visibleSiblingPaneId, to: fixture)
        makeWindowKey(fixture.windowLifecycle)

        await postScrollbackBurst(
            paneId: visibleSiblingPaneId,
            totals: [100, 101],
            pinnedToBottom: true,
            to: fixture
        )

        await assertEventuallyMain("bottom-pinned visible sibling small output should not create inbox noise") {
            fixture.terminalActivity.snapshot(for: visibleSiblingPaneId.uuid)?.outputBurst != nil
        }
        #expect(fixture.inboxAtom.notifications.isEmpty)
        #expect(fixture.inboxAtom.globalUnreadCount == 0)

        await fixture.shutdown()
    }

    @Test("bottom-pinned small output resets before visible sibling scrolls up")
    func bottomPinnedSmallOutputResetsBeforeVisibleSiblingScrollsUp() async throws {
        let fixture = await makeFixture()
        let focusedPaneId = PaneId.generateUUIDv7()
        let visibleSiblingPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(focusedPaneId, to: fixture)
        addVisiblePaneToActiveTab(visibleSiblingPaneId, to: fixture)
        makeWindowKey(fixture.windowLifecycle)

        await postScrollbackBurst(
            paneId: visibleSiblingPaneId,
            totals: [100, 101],
            pinnedToBottom: true,
            to: fixture
        )
        await assertEventuallyMain("bottom-pinned small output should be classified before transition") {
            fixture.terminalActivity.snapshot(for: visibleSiblingPaneId.uuid)?.outputBurst != nil
        }
        #expect(fixture.inboxAtom.notifications.isEmpty)

        await postScrollbackBurst(
            paneId: visibleSiblingPaneId,
            totals: [102, 103],
            pinnedToBottom: false,
            to: fixture,
            startingSeq: 10
        )

        await assertEventuallyMain("scrolled-up output after bottom-pinned suppression should create unread activity") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == false
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false
        }
        let notification = try #require(fixture.inboxAtom.notifications.first)
        #expect(notification.paneId == visibleSiblingPaneId.uuid)
        #expect(notification.kind == .unseenActivity)
        #expect(fixture.inboxAtom.globalUnreadCount == 1)

        await fixture.shutdown()
    }

    @Test("hidden drawer child emits unread activity for small output even when pinned")
    func hiddenDrawerChildEmitsUnreadActivityForSmallOutputEvenWhenPinned() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        let drawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        fixture.paneAtom.toggleDrawer(for: parentPaneId.uuid)
        makeWindowKey(fixture.windowLifecycle)
        #expect(fixture.paneAtom.pane(parentPaneId.uuid)?.drawer?.isExpanded == false)

        await postScrollbackBurst(
            paneId: PaneId(existingUUID: drawerPane.id),
            totals: [100, 101],
            pinnedToBottom: true,
            to: fixture
        )

        await assertEventuallyMain("hidden drawer child small output should create unread activity") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == false
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false
        }
        let notification = try #require(fixture.inboxAtom.notifications.first)
        let scope = PaneInboxScopeResolver.resolve(
            anchorPaneId: parentPaneId.uuid,
            pane: { fixture.paneAtom.pane($0) }
        )
        let visibleRows = PaneInboxNotificationPopover.relevantNotifications(
            paneIds: scope.paneIds,
            notifications: fixture.inboxAtom.notifications,
            contentMode: .activity
        )
        #expect(fixture.inboxAtom.globalUnreadCount == 1)
        #expect(notification.paneId == drawerPane.id)
        #expect(notification.kind == .unseenActivity)
        #expect(visibleRows.map(\.paneId) == [drawerPane.id])

        await fixture.shutdown()
    }

    @Test("expanded drawer hidden inactive child emits unread activity for small output even when pinned")
    func expandedDrawerHiddenInactiveChildEmitsUnreadActivityForSmallOutputEvenWhenPinned() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        let hiddenDrawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        let activeDrawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        makeWindowKey(fixture.windowLifecycle)
        #expect(fixture.paneAtom.pane(parentPaneId.uuid)?.drawer?.isExpanded == true)
        #expect(drawerView(for: parentPaneId.uuid, in: fixture)?.activeChildId == activeDrawerPane.id)

        await postScrollbackBurst(
            paneId: PaneId(existingUUID: hiddenDrawerPane.id),
            totals: [100, 101],
            pinnedToBottom: true,
            to: fixture
        )

        await assertEventuallyMain("hidden inactive drawer child small output should create unread activity") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == false
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false
        }
        let notification = try #require(fixture.inboxAtom.notifications.first)
        #expect(notification.paneId == hiddenDrawerPane.id)
        #expect(notification.kind == .unseenActivity)
        #expect(fixture.inboxAtom.globalUnreadCount == 1)

        await fixture.shutdown()
    }

    @Test("minimized split sibling stays unobserved even when bottom pinned")
    func minimizedSplitSiblingStaysUnobservedEvenWhenBottomPinned() async {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        let minimizedSiblingPaneId = PaneId.generateUUIDv7()
        let tabId = addTerminalPane(parentPaneId, to: fixture)
        addVisiblePaneToActiveTab(minimizedSiblingPaneId, to: fixture)
        makeWindowKey(fixture.windowLifecycle)
        #expect(fixture.tabLayout.minimizePane(minimizedSiblingPaneId.uuid, inTab: tabId) == true)

        await postScrollbackBurst(
            paneId: minimizedSiblingPaneId,
            totals: [100, 120, 140],
            pinnedToBottom: true,
            to: fixture
        )

        await assertEventuallyMain("bottom-pinned minimized sibling should still create unread activity") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == false
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false
        }
        #expect(fixture.inboxAtom.globalUnreadCount == 1)
        #expect(fixture.inboxAtom.notifications[0].paneId == minimizedSiblingPaneId.uuid)

        await fixture.shutdown()
    }

    @Test("Zoom-hidden split sibling stays unobserved even when bottom pinned")
    func zoomHiddenSplitSiblingStaysUnobservedEvenWhenBottomPinned() async {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        let hiddenSiblingPaneId = PaneId.generateUUIDv7()
        let tabId = addTerminalPane(parentPaneId, to: fixture)
        addVisiblePaneToActiveTab(hiddenSiblingPaneId, to: fixture)
        makeWindowKey(fixture.windowLifecycle)
        guard fixture.tabLayout.tab(tabId) != nil else {
            Issue.record("Expected terminal activity fixture tab")
            await fixture.shutdown()
            return
        }
        fixture.tabLayout.arrangementAtom.presentationAtom.enterZoom(
            inTab: tabId,
            sourcePaneId: parentPaneId.uuid,
            viewerPresentation: .unavailable
        )

        await postScrollbackBurst(
            paneId: hiddenSiblingPaneId,
            totals: [100, 120, 140],
            pinnedToBottom: true,
            to: fixture
        )

        await assertEventuallyMain("bottom-pinned Zoom-hidden sibling should still create unread activity") {
            fixture.inboxAtom.notifications.count == 1
                && fixture.inboxAtom.notifications[0].isRead == false
                && fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false
        }
        #expect(fixture.inboxAtom.globalUnreadCount == 1)
        #expect(fixture.inboxAtom.notifications[0].paneId == hiddenSiblingPaneId.uuid)

        await fixture.shutdown()
    }

    @Test("main pane hidden by expanded empty drawer emits unseen activity")
    func mainPaneHiddenByExpandedEmptyDrawerEmitsUnseenActivity() async {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        makeWindowKey(fixture.windowLifecycle)
        fixture.paneAtom.toggleDrawer(for: parentPaneId.uuid)

        await postScrollbackBurst(paneId: parentPaneId, to: fixture)

        await assertEventuallyMain("empty expanded drawer should hide the main pane for activity classification") {
            fixture.inboxAtom.notifications.count == 1
        }
        #expect(fixture.inboxAtom.notifications[0].paneId == parentPaneId.uuid)
        #expect(fixture.inboxAtom.notifications[0].kind == .unseenActivity)
        #expect(fixture.inboxAtom.notifications[0].isRead == false)
        #expect(fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false)

        await fixture.shutdown()
    }

    @Test("main pane hidden by all minimized drawer emits unseen activity")
    func mainPaneHiddenByAllMinimizedDrawerEmitsUnseenActivity() async throws {
        let fixture = await makeFixture()
        let parentPaneId = PaneId.generateUUIDv7()
        _ = addTerminalPane(parentPaneId, to: fixture)
        let drawerPane = try #require(
            addDrawerPane(to: parentPaneId.uuid, in: fixture)
        )
        makeWindowKey(fixture.windowLifecycle)
        #expect(minimizeDrawerPane(drawerPane.id, parentPaneId: parentPaneId.uuid, in: fixture) == true)
        #expect(fixture.paneAtom.pane(parentPaneId.uuid)?.drawer?.isExpanded == true)

        await postScrollbackBurst(paneId: parentPaneId, to: fixture)

        await assertEventuallyMain("all-minimized expanded drawer should hide the main pane") {
            fixture.inboxAtom.notifications.count == 1
        }
        #expect(fixture.inboxAtom.notifications[0].paneId == parentPaneId.uuid)
        #expect(fixture.inboxAtom.notifications[0].kind == .unseenActivity)
        #expect(fixture.inboxAtom.notifications[0].isRead == false)
        #expect(fixture.inboxAtom.notifications[0].isDismissedFromPaneInbox == false)

        await fixture.shutdown()
    }
}

extension DerivedActivityNotificationIntegrationTests {
    private func addTerminalPane(
        _ paneId: PaneId,
        to fixture: Fixture
    ) -> UUID {
        let metadata = PaneMetadata(
            paneId: paneId,
            contentType: .terminal,
            launchDirectory: FileManager.default.homeDirectoryForCurrentUser,
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

    private func addDrawerPane(to parentPaneId: UUID, in fixture: Fixture) -> Pane? {
        guard
            let drawerPane = fixture.paneAtom.addDrawerPane(
                to: parentPaneId,
                parentFallbackCWD: nil,
                zmxSessionID: .generateUUIDv7()
            )
        else {
            return nil
        }
        guard let drawer = fixture.paneAtom.pane(parentPaneId)?.drawer,
            let tabId = fixture.tabLayout.tabContaining(paneId: parentPaneId)?.id
        else {
            return drawerPane
        }
        fixture.tabLayout.arrangementAtom.addDrawerPaneView(
            drawerId: drawer.drawerId,
            parentPaneId: parentPaneId,
            drawerPaneId: drawerPane.id,
            inTab: tabId
        )
        return drawerPane
    }

    private func setActiveDrawerPane(_ drawerPaneId: UUID, parentPaneId: UUID, in fixture: Fixture) {
        guard let drawer = fixture.paneAtom.pane(parentPaneId)?.drawer,
            let tabId = fixture.tabLayout.tabContaining(paneId: parentPaneId)?.id
        else {
            return
        }
        fixture.tabLayout.arrangementAtom.setActiveDrawerPane(
            drawerPaneId,
            drawerId: drawer.drawerId,
            inTab: tabId
        )
    }

    private func minimizeDrawerPane(_ drawerPaneId: UUID, parentPaneId: UUID, in fixture: Fixture) -> Bool {
        guard let drawer = fixture.paneAtom.pane(parentPaneId)?.drawer,
            let tabId = fixture.tabLayout.tabContaining(paneId: parentPaneId)?.id
        else {
            return false
        }
        return fixture.tabLayout.arrangementAtom.minimizeDrawerPane(
            drawerPaneId,
            drawerId: drawer.drawerId,
            tabId: tabId
        )
    }

    private func drawerView(for parentPaneId: UUID, in fixture: Fixture) -> DrawerView? {
        guard let drawer = fixture.paneAtom.pane(parentPaneId)?.drawer,
            let tabId = fixture.tabLayout.tabContaining(paneId: parentPaneId)?.id
        else {
            return nil
        }
        return fixture.tabLayout.arrangementAtom.arrangementState(tabId)?.arrangements
            .first { $0.id == fixture.tabLayout.tab(tabId)?.activeArrangementId }?
            .drawerViews[drawer.drawerId]
    }

    private func addVisiblePaneToActiveTab(
        _ paneId: PaneId,
        to fixture: Fixture
    ) {
        let pane = Pane(
            id: paneId.uuid,
            content: .terminal(
                TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())
            ),
            metadata: PaneMetadata(
                paneId: paneId,
                contentType: .terminal,
                launchDirectory: FileManager.default.homeDirectoryForCurrentUser,
                title: "Terminal"
            )
        )
        fixture.paneAtom.addPane(pane)
        guard let activeTab = fixture.tabLayout.activeTab, let activePaneId = activeTab.activePaneId else {
            Issue.record("Expected active tab and pane before adding visible sibling")
            return
        }
        #expect(
            fixture.tabLayout.insertPane(
                pane.id,
                inTab: activeTab.id,
                at: activePaneId,
                direction: .horizontal,
                position: .after,
                sizingMode: .proportional
            ) == true
        )
        fixture.tabLayout.setActivePane(activePaneId, inTab: activeTab.id)
    }

    private func makeWindowKey(_ atom: WindowLifecycleAtom) {
        let id = UUID()
        atom.recordWindowRegistered(id)
        atom.recordWindowBecameKey(id)
    }

    private func waitForAttendedPane(_ paneId: UUID, in fixture: Fixture, description: String) async {
        await assertEventuallyMain(description) {
            fixture.attendedPane.attendedPaneId == paneId
        }
    }

    private func waitForTerminalRouterAttendance(
        paneId: UUID,
        in fixture: Fixture,
        description: String
    ) async {
        await assertEventuallyMain(description) {
            PaneObservationResolver.isPaneCurrentlyAttended(
                paneId: paneId,
                attendedPaneId: fixture.attendedPane.attendedPaneId,
                pane: { fixture.paneAtom.pane($0) },
                drawerView: { drawerView(for: $0, in: fixture) }
            )
        }
    }

    private static func settledActivities(
        from recorder: RecordingSubscriber<RuntimeEnvelope>
    ) async -> [TerminalSettledActivity] {
        RuntimeEnvelopeHarness.paneEvents(from: await recorder.snapshot()).compactMap { record in
            guard case .terminalActivity(.unseenActivitySettled(let activity)) = record.event else {
                return nil
            }
            return activity
        }
    }

    private func waitForRecordedActivityObservation(paneId: UUID, in fixture: Fixture) async {
        await assertEventuallyMain("activity observation should reach the terminal router") {
            fixture.paneActivityObservationRecorder.paneIds.contains(paneId)
        }
        await fixture.terminalRouterBox.joinLatestObservation()
    }

    private func postScrollbackBurst(
        paneId: PaneId,
        totals: [Int] = [100, 120, 140],
        pinnedToBottom: Bool = false,
        to fixture: Fixture,
        startingSeq: UInt64 = 1,
        settle: Bool = true
    ) async {
        guard let firstTotal = totals.first, let latestTotal = totals.last else { return }
        let firstState = scrollbarState(totalRows: firstTotal, pinnedToBottom: pinnedToBottom)
        let startedAtMilliseconds = Int64(startingSeq) * 100
        var aggregate = TerminalScrollbarActivityAggregate(
            state: firstState,
            observedAtMilliseconds: startedAtMilliseconds
        )
        for (index, totalRows) in totals.dropFirst().enumerated() {
            aggregate.merge(
                state: scrollbarState(totalRows: totalRows, pinnedToBottom: pinnedToBottom),
                observedAtMilliseconds: startedAtMilliseconds + Int64((index + 1) * 100)
            )
        }
        let initialSleepGeneration = fixture.clock.scheduledSleepGeneration
        await fixture.terminalRouter.consumeTerminalActivityInput(
            .aggregate(
                surfaceID: paneId.uuid,
                paneID: paneId.uuid,
                input: TerminalActivityAggregateInput(
                    aggregate: aggregate,
                    latestState: scrollbarState(totalRows: latestTotal, pinnedToBottom: pinnedToBottom),
                    context: TerminalActivityProjectionContext(
                        isAttended: PaneObservationResolver.isPaneCurrentlyAttended(
                            paneId: paneId.uuid,
                            attendedPaneId: fixture.attendedPane.attendedPaneId,
                            pane: { fixture.paneAtom.pane($0) },
                            drawerView: { drawerView(for: $0, in: fixture) }
                        ),
                        isAgentClassified: false,
                        outputBurstThreshold: fixture.terminalActivity.outputBurstThreshold
                    )
                )
            )
        )
        await assertEventuallyMain("terminal activity atom should observe latest rows") {
            fixture.terminalActivity.snapshot(for: paneId.uuid)?.scrollbarState?.total == latestTotal
        }
        guard settle else { return }
        await fixture.clock.waitForPendingSleepGeneration(initialSleepGeneration)
        fixture.clock.advance(by: AppPolicies.InboxNotification.terminalActivityQuietDebounceDuration)
    }

    private func scrollbarState(totalRows: Int, pinnedToBottom: Bool) -> ScrollbarState {
        let bottom = pinnedToBottom ? totalRows : 10
        let top = pinnedToBottom ? max(0, totalRows - 10) : 0
        return ScrollbarState(top: top, bottom: bottom, total: totalRows)
    }
}
