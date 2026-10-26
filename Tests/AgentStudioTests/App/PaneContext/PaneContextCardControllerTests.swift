import AgentStudioCore
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Exact card request lifetime", .serialized)
struct PaneContextCardControllerTests {
    @Test("a failed exact refresh removes the form and prevents actions from falling back to the page")
    func failedExactReadRemovesActionableSnapshot() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail)
        let controller = makePopoverController(ports: ports, location: .card)
        await controller.openCard(pane, selection: .ask(source: pane, message: id))
        #expect(controller.selectedAsk?.detail == detail.messages.first)
        await ports.configureExactReads([.unavailable(.databaseUnavailable)])
        await controller.refresh()
        #expect(controller.selectedAsk == nil)
        #expect(controller.unavailableNote == "Context unavailable: database unavailable")
        var draft = AskFormDraft()
        draft.text = "Do not submit a cached form"
        await controller.answerDraft(messageId: id, source: pane, draft: draft)
        await controller.dismiss(messageId: id, source: pane)
        #expect(await ports.answers.isEmpty)
        #expect(await ports.dismissals.isEmpty)
        controller.close()
        try await ports.finish()
    }

    @Test("a stale exact read cannot replace a newer selection or revive a hidden card", arguments: [true, false])
    func outOfOrderExactReadIsDiscarded(hide: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let first = AgentMessageId.generateUUIDv7()
        let second = AgentMessageId.generateUUIDv7()
        let old = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: first, state: .open, revision: 1)
        let newer = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: second, state: .open, revision: 2)
        let ports = PaneContextPopoverTestPorts(old)
        await ports.configureExactReads([.found(old.messages[0]), .found(newer.messages[0])], held: [0])
        let controller = makePopoverController(ports: ports, location: .card)
        let oldRead = Task { await controller.openCard(pane, selection: .ask(source: pane, message: first)) }
        do {
            try await ports.exactReads.expectNext(in: 0, .started(pane, first))
            #expect(controller.selectedAsk == nil)
            if hide {
                controller.close()
            } else {
                await controller.openCard(pane, selection: .ask(source: pane, message: second))
                #expect(controller.selectedAsk?.key == .init(paneId: pane, messageId: second))
            }
            await ports.releaseExact(0)
            await oldRead.value
            #expect(controller.selectedAsk?.key == (hide ? nil : .init(paneId: pane, messageId: second)))
            #expect(controller.paneId == (hide ? nil : pane))
            controller.close()
            try await ports.finish()
        } catch {
            controller.close()
            await ports.releaseExact(0)
            await oldRead.value
            try? await ports.finish()
            throw error
        }
    }

    @Test("an exact card target outside the current canonical source scope is not read")
    func detachedSourceCannotSupplyTheCardForm() async throws {
        let pane = PaneId.generateUUIDv7()
        let other = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail)
        let otherDetail = try PaneContextPopoverControllerTests.askDetail(
            pane: other, id: id, state: .open, revision: 1)
        await ports.configureExactReads([.found(otherDetail.messages[0])])
        let controller = makePopoverController(ports: ports, location: .card)
        await controller.openCard(pane, selection: .ask(source: other, message: id))
        #expect(controller.selectedAsk == nil)
        controller.close()
        try await ports.finish()
    }

    @Test("Answer navigation includes the exact omitted request and parses its own schema")
    func messagesNavigationReadsItsExactTarget() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let exact = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane))
        await ports.configureExactReads([.found(exact.messages[0])])
        let controller = makePopoverController(ports: ports)
        await controller.openMessages(pane, focusedMessage: .init(paneId: pane, messageId: id))
        #expect(controller.state?.messages.messageRows.map(\.id) == [id.uuid])
        var draft = AskFormDraft()
        draft.text = "Exact target"
        await controller.answerDraft(messageId: id, source: pane, draft: draft)
        #expect(
            await ports.answers == [.init(messageId: id, paneId: pane, by: .localUser, value: .text("Exact target"))])
        controller.close()
        try await ports.finish()
    }
}
