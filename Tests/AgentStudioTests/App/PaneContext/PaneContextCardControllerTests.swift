import AgentStudioCore
import AgentStudioInfrastructure
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
        let detail = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail)
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, location: .card, content: .card,
            sources: [pane: PaneContextPreparedDetailFixture.cardSource(pane, selected: target)]
        ) { fixture, handle in
            #expect(handle.atom.value?.selectedAsk?.detail == detail.messages.first)
            await ports.configureExactReads([.unavailable(.databaseUnavailable)])
            try await fixture.refresh(handle)
            #expect(handle.atom.value?.selectedAsk == nil)
            #expect(handle.atom.value?.content.feedback == "Context unavailable: database unavailable")
            var draft = AskFormDraft()
            draft.text = "Do not submit a cached form"
            _ = await fixture.bindings.performPerson(.answer(target, draft), handle: handle)
            _ = await fixture.bindings.performPerson(.dismiss(target), handle: handle)
            #expect(await ports.answers.isEmpty)
            #expect(await ports.dismissals.isEmpty)
            #expect(handle.atom.value?.selectedAsk == nil, "A stale form command must not revive a cleared request")
        }
    }

    @Test("a stale exact read cannot replace a newer selection or revive a hidden card", arguments: [true, false])
    func outOfOrderExactReadIsDiscarded(hide: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let first = AgentMessageId.generateUUIDv7()
        let second = AgentMessageId.generateUUIDv7()
        let old = try PaneContextMessageFixtures.askDetail(pane: pane, id: first, state: .open, revision: 1)
        let newer = try PaneContextMessageFixtures.askDetail(pane: pane, id: second, state: .open, revision: 2)
        let ports = PaneContextPopoverTestPorts(old)
        await ports.configureExactReads([.found(old.messages[0]), .found(newer.messages[0])], held: [0])
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: ports, person: ports))
        fixture.setSource(
            PaneContextPreparedDetailFixture.cardSource(
                pane,
                selected: .init(paneId: pane, messageId: first)), for: pane)
        let key = PaneContextPopoverConsumerKey(hostId: UUIDv7.generate(), surface: .managementCard, paneId: pane)
        let setup = fixture.bindings.beginOpen(
            key,
            demand: .init(
                content: .card, location: .card,
                includingDrawers: true, screenVisibleWidth: 1400))
        var monitor: Task<Void, Never>?
        var transition: Task<Void, Never>?
        do {
            let handle = try #require(await setup.value)
            monitor = Task {
                await handle.opening.initialExecution.task.value
                await ports.exactProducerEnded(beforeRead: 0)
            }
            try await ports.exactReads.expectNext(in: 0, .started(pane, first))
            #expect(handle.atom.value?.selectedAsk == nil)
            if hide {
                transition = fixture.bindings.beginClose(key)
            } else {
                fixture.setSource(
                    PaneContextPreparedDetailFixture.cardSource(
                        pane,
                        selected: .init(paneId: pane, messageId: second), revision: 2), for: pane)
                await ports.setDetail(newer)
                await fixture.bindings.owner.refreshImmediately(key, opening: handle.opening.epoch)
            }
            await ports.releaseExact(0)
            await monitor?.value
            if hide {
                await transition?.value
                #expect(await fixture.bindings.owner.latestExecution(for: key) == nil)
                if let value = handle.atom.latestAcceptedValue {
                    #expect(!handle.atom.isCurrent(value.publication.request))
                }
            } else {
                let next = try #require(await fixture.bindings.owner.latestExecution(for: key))
                _ = try await fixture.completed(next, for: handle)
                #expect(handle.atom.value?.selectedAsk?.key == .init(paneId: pane, messageId: second))
            }
            try await fixture.finish()
            try await ports.finish()
        } catch {
            await ports.releaseExact(0)
            await monitor?.value
            await transition?.value
            try? await fixture.finish()
            try? await ports.finish()
            throw error
        }
    }

    @Test("an exact card target outside the current canonical source scope is not read")
    func detachedSourceCannotSupplyTheCardForm() async throws {
        let pane = PaneId.generateUUIDv7()
        let other = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail)
        let otherDetail = try PaneContextMessageFixtures.askDetail(pane: other, id: id, state: .open, revision: 1)
        await ports.configureExactReads([.found(otherDetail.messages[0])])
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, location: .card, content: .card,
            sources: [
                pane: PaneContextPreparedDetailFixture.cardSource(
                    pane,
                    selected: .init(paneId: other, messageId: id))
            ]
        ) { _, handle in
            #expect(handle.atom.value?.selectedAsk == nil)
            #expect(await ports.exactRequests.isEmpty)
        }
    }

    @Test("Answer navigation includes the exact omitted request and parses its own schema")
    func messagesNavigationReadsItsExactTarget() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let exact = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane))
        await ports.configureExactReads([.found(exact.messages[0])])
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, content: .messages(.message(target))
        ) { fixture, handle in
            #expect(handle.atom.value?.shape?.messages.messageRows.map(\.id) == [id.uuid])
            var draft = AskFormDraft()
            draft.text = "Exact target"
            _ = await fixture.bindings.performPerson(.answer(target, draft), handle: handle)
            #expect(
                await ports.answers == [
                    .init(messageId: id, paneId: pane, by: .localUser, value: .text("Exact target"))
                ])
        }
    }
}
