import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio

// D44: gate assertions cover the exact request handed to the proxy. Actual Info/focused-row
// clip placement and post-user-scroll position are J9 journey proof on the declared build.
@MainActor
@Suite("Messages scroll proxy requests", .serialized)
struct PaneContextPopoverScrollNativeTests {
    @Test("The shared panel keeps overlay scrolling under a process-local legacy preference")
    func sharedPanelOpensWithOverlayScroller() async throws {
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previousArguments
        arguments["AppleShowScrollBars"] = "Always"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        try #require(NSScroller.preferredScrollerStyle == .legacy)
        let fixture = PaneContextNativeScrollFixture()
        try await fixture.run(fixture.window()) { mounted in
            try await mounted.open()
            try await mounted.rendered()
            let heading = try #require(mounted.native.find("pane-context.group.info") as? NSView)
            let scroll = try #require(heading.enclosingScrollView)
            #expect(scroll.scrollerStyle == .overlay)
            #expect(scroll.autohidesScrollers)
            #expect(!scroll.drawsBackground)
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            // AppKit applies the preferred style by sending this setter to existing scroll views.
            scroll.scrollerStyle = NSScroller.preferredScrollerStyle
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            #expect(scroll.scrollerStyle == .overlay)
        }
    }

    @Test("Info hands its section to the proxy and the age frame still refreshes; clip placement is J9 proof")
    func infoChipRequestsItsSectionAndAgeRefreshes() async throws {
        let fixture = PaneContextNativeScrollFixture()
        try await fixture.run(fixture.window()) { mounted in
            let origin = mounted.clock.now
            try await mounted.open()
            let outcome = try await mounted.native.scrolling.completed(
                requested: .section(.info), handingToProxy: .section(.info))
            #expect(outcome == .applied)
            #expect(mounted.interactions.selectedFilter == 8)
            try mounted.native.press(PaneContextPopoverControlProjection.controls().filters[1].identifier)
            try await mounted.bodyLayoutsPrepared()
            #expect(mounted.interactions.selectedFilter == 9)
            #expect(await fixture.ports.requests == [.init(paneId: fixture.pane, page: .first)])
            #expect(await fixture.ports.exactRequests.isEmpty)
            try await mounted.advance(by: .seconds(60), registeredAt: origin.advanced(by: .seconds(60)))
            #expect(mounted.interactions.selectedFilter == 9, "Age publication must preserve the user's union")
            let key = MessageRowModel.Key(sourcePaneId: fixture.pane.uuid, messageId: fixture.info.id.uuid)
            _ = try mounted.appliedMessage(
                key, expectedLabel: "info message line 1\ninfo message line 2\ninfo message line 3 1 min ago",
                age: "1 min ago", isRead: false)
        }
    }

    @Test("The Messages bell hands top to the scroll proxy")
    func bellRequestsTop() async throws {
        let fixture = PaneContextNativeScrollFixture()
        let entry = PaneContextPopoverEntry.messagesAction(
            PaneContextPopoverControlProjection.controls().messages, target: .top)
        try await fixture.run(fixture.window(entry: entry)) { mounted in
            try await mounted.open()
            let outcome = try await mounted.native.scrolling.completed(requested: .top, handingToProxy: .top)
            #expect(outcome == .applied)
            #expect(mounted.interactions.selectedFilter == 15)
            try expectEveryFilterOn(mounted)
        }
    }

    @Test("An absent kind hands top to the proxy without another page")
    func absentSectionRequestsTopWithoutExtraRead() async throws {
        let fixture = PaneContextNativeScrollFixture(omitDone: true)
        try await fixture.run(fixture.window(kind: .done)) { mounted in
            try await mounted.open()
            let outcome = try await mounted.native.scrolling.completed(requested: .section(.done), handingToProxy: .top)
            #expect(outcome == .fellBackToTop)
            #expect(mounted.native.find("pane-context.group.done") == nil)
            #expect(await fixture.ports.requests == [.init(paneId: fixture.pane, page: .first)])
            #expect(await fixture.ports.exactRequests.isEmpty)
        }
    }

    @Test("The focused-message entry hands its exact row identity to the proxy")
    func focusedMessageRequestsItsExactRow() async throws {
        let fixture = PaneContextNativeScrollFixture()
        let key = PaneContextMessageKey(paneId: fixture.pane, messageId: fixture.info.id)
        let entry = PaneContextPopoverEntry.messagesAction(
            PaneContextPopoverControlProjection.control(
                .showPaneMessages, identifier: "pane-context.messages"),
            target: .message(key))
        try await fixture.run(fixture.window(entry: entry)) { mounted in
            try await mounted.open()
            let outcome = try await mounted.native.scrolling.completed(
                requested: .message(key),
                handingToProxy: .message(.init(sourcePaneId: fixture.pane.uuid, messageId: fixture.info.id.uuid)))
            #expect(outcome == .applied)
            #expect(await fixture.ports.exactRequests == [key])
            #expect(mounted.interactions.selectedFilter == 15)
            try expectEveryFilterOn(mounted)
        }
    }

    @Test("The card's Show messages control hands top to the proxy")
    func cardMessagesRequestsTop() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Scroll card")
            defer { store.removePane(pane.id) }
            let fixture = PaneContextNativeScrollFixture(pane: .init(existingUUID: pane.id))
            let owners = PaneContextTestSourceOwners(
                sessionStatus: fixture.owners.sessionStatus,
                presentation: fixture.owners.presentation, pane: { store.paneAtom.pane($0.uuid) },
                serviceProvider: fixture.owners.serviceProvider)
            let mounted = owners.makeNativeCardHost(
                context: .project(paneId: pane.id, store: store),
                wallNow: Date(timeIntervalSince1970: 2))
            try await fixture.run(mounted) { mounted in
                try await mounted.open()
                try await mounted.renderedCard()
                try await mounted.completeOpening(try mounted.beginOpening())
                try await mounted.rendered()
                let outcome = try await mounted.native.scrolling.completed(requested: .top, handingToProxy: .top)
                #expect(outcome == .applied)
                // The fixture exposes the card's local state; its child Messages opening owns another state.
                #expect(mounted.interactions.selectedFilter == 0)
                try expectEveryFilterOn(mounted)
            }
        }
    }

    @Test(
        "Manual union survives paging; a fresh type or generic counter opening seeds its membership again",
        arguments: [false, true])
    func typedOpeningKeepsManualSelectionThroughPagingAndReseedsOnReopen(genericCounter: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let info = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info, sentAt: 3)
        let needsYou = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .attention, sentAt: 2)
        let initial = PaneContextPopoverShapingTests.detail(
            paneId: pane, messages: [info],
            truncation: .init(
                omitted: [.init(source: pane, openAsks: 0, unreadNotices: 1, next: .init(rank: 1, position: 12))],
                remainingLiveSources: 0, nextSourcesAfter: nil))
        let ports = PaneContextPopoverTestPorts(initial)
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: .init(), presentation: .init(), pane: { _ in nil }, serviceProvider: { adapter })
        let controls = PaneContextPopoverControlProjection.controls()
        let entry: PaneContextPopoverEntry =
            genericCounter
            ? .messagesAction(controls.messages, target: .top) : .kind(.init(kind: .info, count: 1))
        let initialSelection = genericCounter ? 15 : 8
        let manualSelection = genericCounter ? 14 : 9
        let mounted = owners.makeNativeHost(
            paneId: pane, entry: entry, wallNow: Date(timeIntervalSince1970: 4))
        do {
            try await mounted.open()
            try await mounted.rendered()
            try await mounted.bodyLayoutsPrepared()
            let originalOpening = try #require(mounted.handle).opening.epoch
            #expect(mounted.interactions.selectedFilter == initialSelection)
            try mounted.native.press(controls.filters[1].identifier)
            try await mounted.bodyLayoutsPrepared()
            #expect(mounted.interactions.selectedFilter == manualSelection)
            await ports.enqueue(.detail(initial))
            await ports.enqueue(.detail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [needsYou])))
            try mounted.native.press(controls.moreMessages.identifier(in: pane.uuid.uuidString))
            try await mounted.actionCompleted()
            try await mounted.rendered()
            #expect(mounted.interactions.selectedFilter == manualSelection)
            #expect(mounted.handle?.opening.epoch == originalOpening)
            #expect((mounted.native.find("pane-context.group.needsYou") != nil) == !genericCounter)
            #expect(mounted.native.find("pane-context.group.info") != nil)
            #expect(
                Set(mounted.value?.shape?.messages.messageRows.map(\.id) ?? []) == [info.id.uuid, needsYou.id.uuid])
            try await mounted.open()
            try await mounted.rendered()
            #expect(mounted.handle?.opening.epoch != originalOpening)
            #expect(mounted.interactions.selectedFilter == initialSelection)
            #expect(mounted.native.find("pane-context.group.needsYou") == nil)
            #expect(mounted.native.find("pane-context.group.info") != nil)
            #expect(
                await ports.requests.map(\.page) == [
                    .first, .first, .more(source: pane, after: .init(rank: 1, position: 12)), .first,
                ])
            try await mounted.close()
            #expect(mounted.interactions.selectedFilter == 0)
            try await ports.finish()
        } catch {
            try? await mounted.close()
            try? await ports.finish()
            throw error
        }
    }

    private func expectEveryFilterOn(_ mounted: PaneContextPreparedNativeHost) throws {
        for control in PaneContextPopoverControlProjection.controls().filters.dropFirst() {
            let chip = try #require(mounted.native.find(control.identifier) as? any NSAccessibilityProtocol)
            #expect(chip.isAccessibilitySelected())
        }
    }
}
