import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverControllerPagingTests {
    @Test("Dismiss all pages through truncated notice sources without touching asks")
    func dismissAllNoticesPagesRemainingSources() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let first = try PaneContextPopoverShapingTests.message(
            paneId: owner, shape: .notice(.unread), importance: .info, sentAt: 3)
        let ask = try PaneContextPopoverShapingTests.message(
            paneId: owner,
            shape: .ask(.question, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .open),
            importance: .attention, sentAt: 2)
        let second = try PaneContextPopoverShapingTests.message(
            paneId: owner, shape: .notice(.unread), importance: .done, sentAt: 1)
        let third = try PaneContextPopoverShapingTests.message(
            paneId: drawer, shape: .notice(.read), importance: .info, sentAt: 0)
        let initial = PaneContextPopoverShapingTests.detail(
            paneId: owner, messages: [first, ask],
            truncation: .init(
                omitted: [.init(source: owner, openAsks: 0, unreadNotices: 1, next: .init(rank: 1, position: 12))],
                remainingLiveSources: 1, nextSourcesAfter: owner))
        let page = PaneContextPopoverShapingTests.detail(paneId: owner, messages: [second])
        let sourcePage = PaneContextPopoverShapingTests.detail(
            paneId: owner, drawers: [.init(sourcePaneId: drawer, messages: [third])])
        let ports = PaneContextPopoverTestPorts(
            initial, results: [.detail(initial), .detail(page), .detail(sourcePage), .detail(initial)])
        let controller = makePopoverController(ports: ports)
        await controller.open(owner)
        await controller.dismissAllNotices()
        #expect(await ports.dismissals.map(\.0) == [first.id, second.id, third.id])
        #expect(await ports.dismissals.contains { $0.0 == ask.id } == false)
        #expect(
            await ports.requests.map(\.page) == [
                .first, .more(source: owner, after: .init(rank: 1, position: 12)),
                .moreSources(after: owner), .first,
            ])
        controller.close()
        try await ports.finish()
    }

    @Test
    func messagePagingAndSourcePagingAccumulateWithoutLosingOtherCursors() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let first = try PaneContextPopoverShapingTests.message(
            paneId: owner, shape: .notice(.unread), importance: .info, sentAt: 3)
        let second = try PaneContextPopoverShapingTests.message(
            paneId: owner, shape: .notice(.unread), importance: .attention, sentAt: 2)
        let third = try PaneContextPopoverShapingTests.message(
            paneId: drawer, shape: .notice(.unread), importance: .info, sentAt: 1)
        let initial = PaneContextPopoverShapingTests.detail(
            paneId: owner, messages: [first],
            truncation: .init(
                omitted: [.init(source: owner, openAsks: 0, unreadNotices: 1, next: .init(rank: 1, position: 12))],
                remainingLiveSources: 1, nextSourcesAfter: owner))
        let ports = PaneContextPopoverTestPorts(initial)
        let controller = makePopoverController(ports: ports)
        await controller.open(owner)
        await ports.enqueue(.detail(PaneContextPopoverShapingTests.detail(paneId: owner, messages: [second])))
        await controller.moreMessages(source: owner, after: .init(rank: 1, position: 12))
        #expect(controller.state?.messages.partitions.all.flatMap(\.rows).map(\.id) == [first.id.uuid, second.id.uuid])
        #expect(controller.state?.messages.pages.isEmpty == true)
        #expect(controller.state?.messages.nextSourcesAfter == owner.uuid)
        await ports.enqueue(
            .detail(
                PaneContextPopoverShapingTests.detail(
                    paneId: owner, drawers: [.init(sourcePaneId: drawer, messages: [third])])))
        await controller.moreSources(after: owner)
        #expect(
            controller.state?.messages.partitions.all.flatMap(\.rows).map(\.id) == [
                first.id.uuid, second.id.uuid, third.id.uuid,
            ])
        #expect(controller.state?.messages.nextSourcesAfter == nil)
        #expect(
            await ports.requests.map(\.page) == [
                .first, .more(source: owner, after: .init(rank: 1, position: 12)), .moreSources(after: owner),
            ])
        controller.close()
        try await ports.finish()
    }

    @Test
    func pagingAcrossARevisionRestartsInsteadOfKeepingStaleRows() async throws {
        let owner = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let initial = try PaneContextPopoverControllerTests.askDetail(pane: owner, id: id, state: .open, revision: 1)
        let current = try PaneContextPopoverControllerTests.askDetail(pane: owner, id: id, state: .expired, revision: 2)
        let ports = PaneContextPopoverTestPorts(initial)
        let controller = makePopoverController(ports: ports)
        await controller.open(owner)
        await ports.enqueue(.detail(current))
        await ports.setDetail(current)
        await controller.moreMessages(source: owner, after: .init(rank: 0, position: 12))
        #expect(controller.state?.revision == .init(2))
        #expect(await ports.requests.last?.page == .first)
        #expect(
            PaneContextPopoverControllerTests.firstRow(controller)?.shape
                == .ask(
                    reason: .question, form: .freeText(placeholder: "Reply"), waiting: .nonBlocking, state: .expired))
        controller.close()
        try await ports.finish()
    }

    @Test
    func booleanDraftAndNumericInputCrossTheTypedAnswerBoundary() async throws {
        let owner = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let message = AgentMessageDetail(
            id: id, sourcePaneId: owner,
            sender: .session(
                provider: try .init("codex"), sessionRef: try .init("session"), bindingGeneration: UUIDv7.generate()),
            sentAt: .distantPast, sourceOccurredAt: nil, importance: .attention, body: "Form", why: nil, actions: [],
            shape: .ask(
                .question,
                .elicitation(
                    .init(
                        properties: [
                            .init(name: "enabled", title: nil, description: nil, type: .boolean),
                            .init(
                                name: "count", title: nil, description: nil,
                                type: .integer(.init(minimum: 1, maximum: 5))),
                        ], required: ["enabled", "count"])), .nonBlocking, .open))
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: owner, messages: [message]))
        let controller = makePopoverController(ports: ports)
        await controller.open(owner)
        var draft = AskFormDraft()
        draft.booleans["enabled"] = true
        draft.fields["count"] = "3"
        await controller.answerDraft(messageId: id, source: owner, draft: draft)
        #expect(
            await ports.answers.last?.value
                == .form(.init(properties: ["enabled": .boolean(true), "count": .integer(3)])))
        draft.fields["count"] = "not a number"
        await controller.answerDraft(messageId: id, source: owner, draft: draft)
        #expect(controller.actionFeedback == "Invalid answer: field count")
        #expect(await ports.answers.count == 1)
        controller.close()
        try await ports.finish()
    }
}
