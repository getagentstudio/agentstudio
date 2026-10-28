import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

// D44: gate assertions cover the exact request handed to the proxy. Actual Info/focused-row
// clip placement and post-user-scroll position are J9 journey proof on the declared build.
@MainActor
@Suite("Messages scroll proxy requests", .serialized)
struct PaneContextPopoverScrollNativeTests {
    @Test("Info hands its section to the proxy and the age frame still refreshes; clip placement is J9 proof")
    func infoChipRequestsItsSectionAndAgeRefreshes() async throws {
        let fixture = PaneContextNativeScrollFixture()
        try await fixture.run(fixture.window()) { mounted in
            let origin = mounted.clock.now
            try await mounted.open()
            let outcome = try await mounted.native.scrolling.completed(
                requested: .section(.info), handingToProxy: .section(.info))
            #expect(outcome == .applied)
            #expect(await fixture.ports.requests == [.init(paneId: fixture.pane, page: .first)])
            #expect(await fixture.ports.exactRequests.isEmpty)
            try await mounted.advance(by: .seconds(60), registeredAt: origin.advanced(by: .seconds(60)))
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
            PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil)
        try await fixture.run(fixture.window(entry: entry)) { mounted in
            try await mounted.open()
            let outcome = try await mounted.native.scrolling.completed(requested: .top, handingToProxy: .top)
            #expect(outcome == .applied)
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
                .answerPaneMessageInMessages, identifier: "pane-context.answer-in-messages"),
            focusedMessage: key)
        try await fixture.run(fixture.window(entry: entry)) { mounted in
            try await mounted.open()
            let outcome = try await mounted.native.scrolling.completed(
                requested: .message(key),
                handingToProxy: .message(.init(sourcePaneId: fixture.pane.uuid, messageId: fixture.info.id.uuid)))
            #expect(outcome == .applied)
            #expect(await fixture.ports.exactRequests == [key])
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
            }
        }
    }
}
