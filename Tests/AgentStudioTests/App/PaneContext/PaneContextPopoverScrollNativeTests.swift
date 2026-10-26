import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Messages scroll destinations", .serialized)
struct PaneContextPopoverScrollNativeTests {
    @Test("Info opens below the fold; an age refresh preserves the user's later scroll")
    func infoChipScrollsIntoViewportAndAgeDoesNotJumpBack() async throws {
        let fixture = PaneContextNativeScrollFixture()
        try await fixture.run(fixture.window()) { mounted in
            let origin = mounted.clock.now
            try await mounted.open()
            #expect(try await mounted.scrolling.completed(requested: .section(.info)) == .applied)
            mounted.layout()
            let scroll = try PaneContextNativeScrollFixture.scrollView(in: mounted)
            let document = try #require(scroll.documentView)
            let info = try PaneContextNativeScrollFixture.frame(
                "pane-context.group.info", in: mounted, document: document)
            #expect(info.intersects(scroll.documentVisibleRect), "The actual Info header must be inside the clip")
            var top = scroll.documentVisibleRect
            top.origin.y = document.isFlipped ? document.bounds.minY : document.bounds.maxY - top.height
            #expect(!info.intersects(top), "Info must start outside the unscrolled viewport")
            #expect(document.bounds.height > 2 * scroll.contentView.bounds.height)
            #expect(await fixture.ports.requests == [.init(paneId: fixture.pane, page: .first)])
            #expect(await fixture.ports.exactRequests.isEmpty)
            try await mounted.clock.registered(
                origin.advanced(by: .seconds(60)), pane: fixture.pane.uuid, currentInput: nil)
            scroll.contentView.scroll(to: top.origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            mounted.layout()
            let userPosition = scroll.documentVisibleRect
            let operations = mounted.scrolling.operations
            mounted.clock.advance(by: .seconds(60))
            try await mounted.clock.registered(
                origin.advanced(by: .seconds(120)), pane: fixture.pane.uuid, currentInput: nil)
            mounted.layout()
            await mounted.scrolling.joinAnnouncedProducers()
            mounted.layout()
            #expect(mounted.labels().contains { $0.contains("info message line 3 1 min ago") })
            #expect(scroll.documentVisibleRect == userPosition, "An age update must preserve the user's position")
            #expect(
                mounted.scrolling.operations == operations, "An age update must not consume the opening trigger again")
            #expect(!info.intersects(scroll.documentVisibleRect))
        }
    }

    @Test("The real Messages bell opens a long multi-section list at the top")
    func bellOpensAtTop() async throws {
        let fixture = PaneContextNativeScrollFixture()
        let entry = PaneContextPopoverEntry.messagesAction(
            PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil)
        try await fixture.run(fixture.window(entry: entry)) { mounted in
            try await mounted.open()
            #expect(try await mounted.scrolling.completed(requested: .top) == .applied)
            mounted.layout()
            try PaneContextNativeScrollFixture.assertTop(
                PaneContextNativeScrollFixture.scrollView(in: mounted), in: mounted)
        }
    }

    @Test("An absent kind opens the actual viewport at the top without another page")
    func absentSectionOpensAtTopWithoutExtraRead() async throws {
        let fixture = PaneContextNativeScrollFixture(omitDone: true)
        try await fixture.run(fixture.window(kind: .done)) { mounted in
            try await mounted.open()
            #expect(try await mounted.scrolling.completed(requested: .section(.done)) == .fellBackToTop)
            mounted.layout()
            try PaneContextNativeScrollFixture.assertTop(
                PaneContextNativeScrollFixture.scrollView(in: mounted), in: mounted)
            #expect(mounted.find("pane-context.group.done") == nil)
            #expect(await fixture.ports.requests == [.init(paneId: fixture.pane, page: .first)])
            #expect(await fixture.ports.exactRequests.isEmpty)
        }
    }

    @Test("The focused-message entry retains its actual row scroll destination")
    func focusedMessageScrollsItsRowIntoViewport() async throws {
        let fixture = PaneContextNativeScrollFixture()
        let key = PaneContextMessageKey(paneId: fixture.pane, messageId: fixture.info.id)
        let entry = PaneContextPopoverEntry.messagesAction(
            PaneContextPopoverControlProjection.control(
                .answerPaneMessageInMessages, identifier: "pane-context.answer-in-messages"),
            focusedMessage: key)
        try await fixture.run(fixture.window(entry: entry)) { mounted in
            try await mounted.open()
            #expect(try await mounted.scrolling.completed(requested: .message(key)) == .applied)
            mounted.layout()
            let scroll = try PaneContextNativeScrollFixture.scrollView(in: mounted)
            let document = try #require(scroll.documentView)
            let row = try PaneContextNativeScrollFixture.frame(
                "pane-context.message-text.\(fixture.pane.uuid).\(fixture.info.id.uuid)", in: mounted,
                document: document)
            #expect(row.intersects(scroll.documentVisibleRect))
            #expect(scroll.documentVisibleRect.minY > document.bounds.minY)
            #expect(await fixture.ports.exactRequests == [key])
        }
    }

    @Test("The card's actual Show messages control opens at the top")
    func cardMessagesOpensAtTop() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Scroll card")
            defer { store.removePane(pane.id) }
            let fixture = PaneContextNativeScrollFixture(pane: .init(existingUUID: pane.id))
            let mounted = PaneContextNativePopoverWindow(
                paneId: fixture.pane, readers: fixture.readers, location: .card,
                wallNow: Date(timeIntervalSince1970: 2), card: (.project(paneId: pane.id, store: store), store))
            try await fixture.run(mounted) { mounted in
                try await mounted.renderedCard()
                try mounted.press("pane-context.card-messages")
                try await mounted.readCompleted()
                try await mounted.rendered()
                #expect(try await mounted.scrolling.completed(requested: .top) == .applied)
                mounted.layout()
                try PaneContextNativeScrollFixture.assertTop(
                    PaneContextNativeScrollFixture.scrollView(in: mounted), in: mounted)
            }
        }
    }
}
