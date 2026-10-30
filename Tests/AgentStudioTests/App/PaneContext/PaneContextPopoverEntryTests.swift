import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

struct PaneContextPopoverEntryTests {
    @Test(
        "Ages do not repeat a chip-open scroll, while another open does",
        arguments: [KindChipModel.Kind.failure, .needsYou, .done, .info])
    func chipScrollFollowsOpenRequests(kind: KindChipModel.Kind) async throws {
        let (initial, aged) = try await messageAges()
        let entry = PaneContextPopoverEntry.kind(.init(kind: kind, count: 1))
        let first = entry.messagesScrollTrigger(openRequest: 1, messages: initial)
        #expect(entry.messagesScrollTrigger(openRequest: 1, messages: aged) == first)
        #expect(entry.messagesScrollTrigger(openRequest: 2, messages: initial) != first)
    }

    @Test("Only a focused message keeps the existing content-driven scroll", arguments: [false, true])
    func cardEntryKeepsItsDeclaredFocus(focused: Bool) async throws {
        let (initial, aged) = try await messageAges()
        let key = PaneContextMessageKey(paneId: .generateUUIDv7(), messageId: .generateUUIDv7())
        let entry = PaneContextPopoverEntry.messagesAction(
            PaneContextPopoverControlProjection.controls().messages, target: focused ? .message(key) : .top)
        let first = entry.messagesScrollTrigger(openRequest: 1, messages: initial)
        #expect((entry.messagesScrollTrigger(openRequest: 1, messages: aged) == first) == !focused)
        #expect((entry.messagesScrollTrigger(openRequest: 2, messages: initial) != first) == !focused)
    }

    @Test("Card +N remains generic and age updates do not repeat its top scroll")
    func cardMoreRemainsGenericAcrossAgeUpdates() async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info)
        let entry = PaneContextPopoverEntry.messagesAction(
            PaneContextPopoverControlProjection.control(
                .showMorePaneNeedsYou(count: 1), identifier: "pane-context.card-more"), target: .top)
        #expect(entry.messagesTarget.initialFilterSelection == 15)
        let shape = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]), sourceTitles: [:],
            counts: .init(failure: 1, needsYou: 1, done: 0, info: 1), messagesTarget: entry.messagesTarget,
            now: Date(timeIntervalSince1970: 2))
        #expect(shape.messagesTarget == .top)
        #expect(shape.messages.filters[15].groups.map(\.kind) == [.info])
        #expect(shape.messages.filters[15].noLoadedContent == nil)
        let aged = await PaneContextPopoverShaping.refresh(
            shape, content: .messages, now: Date(timeIntervalSince1970: 62))
        #expect(entry.messagesScrollTrigger(openRequest: 1, messages: shape.messages) == .opening(1))
        #expect(entry.messagesScrollTrigger(openRequest: 1, messages: aged.shape.messages) == .opening(1))
        #expect(entry.messagesScrollTrigger(openRequest: 2, messages: aged.shape.messages) == .opening(2))
    }

    private func messageAges() async throws -> (MessagesPopoverModel, MessagesPopoverModel) {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info)
        let shape = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]), sourceTitles: [:],
            counts: .init(failure: 0, needsYou: 0, done: 0, info: 1), now: Date(timeIntervalSince1970: 2))
        let aged = await PaneContextPopoverShaping.refresh(
            shape, content: .messages, now: Date(timeIntervalSince1970: 62))
        #expect(shape.messages != aged.shape.messages)
        return (shape.messages, aged.shape.messages)
    }
}
