import AgentStudioCore
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextCardControllerTests {
    @Test("same-key display survives held detail and exact reads while stale actions are refused")
    func sameKeyRefreshRetainsDisplayUntilRevalidated() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        await ports.configureExactReads([], held: [1])
        let controller = makePopoverController(ports: ports, location: .card)
        await controller.openCard(pane, selection: .ask(source: pane, message: id))
        let committed = try #require(controller.selectedAsk)
        let refresh = Task {
            await controller.refresh()
            await ports.detailProducerEnded(beforeRead: 1)
            await ports.exactProducerEnded(beforeRead: 1)
        }
        var detailReleased = false
        var exactReleased = false
        do {
            try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
            #expect(controller.selectedAsk == committed, "The same ask must remain displayed during the detail read")
            await ports.release(1)
            detailReleased = true
            try await ports.exactReads.expectNext(in: 1, .started(pane, id))
            #expect(controller.selectedAsk == committed, "The same ask must remain displayed during exact validation")
            await assertStaleActionsAreRefused(controller, ports: ports, pane: pane, id: id)
            await ports.releaseExact(1)
            exactReleased = true
            await refresh.value
            #expect(controller.selectedAsk?.key == committed.key)
            #expect(controller.selectedAsk?.generation != committed.generation)
            var draft = AskFormDraft()
            draft.text = "Current generation"
            await controller.answerDraft(messageId: id, source: pane, draft: draft)
            #expect(await ports.answers.map(\.value) == [.text("Current generation")])
            controller.close()
            try await ports.finish()
        } catch {
            controller.close()
            if !detailReleased { await ports.release(1) }
            if !exactReleased { await ports.releaseExact(1) }
            await refresh.value
            try? await ports.finish()
            throw error
        }
    }

    private func assertStaleActionsAreRefused(
        _ controller: PaneContextPopoverController, ports: PaneContextPopoverTestPorts,
        pane: PaneId, id: AgentMessageId
    ) async {
        var draft = AskFormDraft()
        draft.text = "Stale generation"
        await controller.answerDraft(messageId: id, source: pane, draft: draft)
        await controller.answer(messageId: id, source: pane, value: .text("Stale direct answer"))
        await controller.dismiss(messageId: id, source: pane)
        #expect(await ports.answers.isEmpty, "A retained display snapshot cannot authorize an answer")
        #expect(await ports.dismissals.isEmpty, "A retained display snapshot cannot authorize dismissal")
    }

    enum RefreshEnd: Sendable, CaseIterable {
        case detailUnavailable, exactUnavailable, notFound, settled
    }

    @Test(
        "every final unavailable, missing or settled read removes the retained request", arguments: RefreshEnd.allCases)
    func finalReadRemovesRetainedAsk(outcome: RefreshEnd) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail)
        let controller = makePopoverController(ports: ports, location: .card)
        await controller.openCard(pane, selection: .ask(source: pane, message: id))
        try #require(controller.selectedAsk != nil)
        switch outcome {
        case .detailUnavailable: await ports.enqueue(.unavailable(.databaseUnavailable))
        case .exactUnavailable: await ports.configureExactReads([.unavailable(.databaseUnavailable)])
        case .notFound: await ports.configureExactReads([.notFound])
        case .settled:
            let settled = try PaneContextPopoverControllerTests.askDetail(
                pane: pane, id: id, state: .expired, revision: 2)
            await ports.configureExactReads([.found(settled.messages[0])])
        }
        await controller.refresh()
        #expect(controller.selectedAsk == nil)
        await assertStaleActionsAreRefused(controller, ports: ports, pane: pane, id: id)
        controller.close()
        try await ports.finish()
    }

    @Test("changing the selected key immediately clears a committed request before the next read")
    func changedKeyClearsCommittedAskBeforeReading() async throws {
        let pane = PaneId.generateUUIDv7()
        let first = AgentMessageId.generateUUIDv7()
        let second = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: first, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        let controller = makePopoverController(ports: ports, location: .card)
        await controller.openCard(pane, selection: .ask(source: pane, message: first))
        try #require(controller.selectedAsk != nil)
        let change = Task {
            await controller.openCard(pane, selection: .ask(source: pane, message: second))
            await ports.detailProducerEnded(beforeRead: 1)
        }
        do {
            try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
            #expect(controller.selectedAsk == nil)
            await ports.release(1)
            await change.value
            controller.close()
            try await ports.finish()
        } catch {
            controller.close()
            await ports.release(1)
            await change.value
            try? await ports.finish()
            throw error
        }
    }
}
