import AgentStudioCore
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextCardControllerTests {
    @Test("moving the same selected source key to another owner clears display before reading")
    func changedOwnerClearsSameSourceKeyBeforeReading() async throws {
        let firstOwner = PaneId.generateUUIDv7()
        let nextOwner = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let selected = PaneContextMessageKey(paneId: firstOwner, messageId: id)
        let detail = try PaneContextMessageFixtures.askDetail(pane: firstOwner, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: firstOwner, ports: ports, location: .card, content: .card,
            sources: [firstOwner: PaneContextPreparedDetailFixture.cardSource(firstOwner, selected: selected)]
        ) { fixture, first in
            try #require(first.atom.value?.selectedAsk?.key == selected)
            await fixture.bindings.beginClose(first.key).value
            fixture.setSource(
                PaneContextPreparedDetailFixture.cardSource(
                    nextOwner, selected: selected,
                    children: [firstOwner]), for: nextOwner)
            fixture.setSource(PaneContextPreparedDetailFixture.source(firstOwner, parent: nextOwner), for: firstOwner)
            await ports.setDetail(
                PaneContextPopoverShapingTests.detail(
                    paneId: nextOwner,
                    drawers: [.init(sourcePaneId: firstOwner, messages: detail.messages)]))
            let nextKey = PaneContextPopoverConsumerKey(
                hostId: first.key.hostId, surface: .managementCard, paneId: nextOwner)
            let setup = fixture.bindings.beginOpen(
                nextKey,
                demand: .init(
                    content: .card, location: .card,
                    includingDrawers: true, screenVisibleWidth: 1400))
            var monitor: Task<Void, Never>?
            do {
                let next = try #require(await setup.value)
                monitor = Task {
                    await next.opening.initialExecution.task.value
                    await ports.detailProducerEnded(beforeRead: 1)
                }
                try await ports.reads.expectNext(in: 1, .started(.init(paneId: nextOwner, page: .first)))
                #expect(
                    next.atom.value?.selectedAsk == nil, "Matching source/message alone cannot retain across owners")
                #expect(next.atom.value?.card?.request == CardModel.Request.none)
                if let retired = first.atom.latestAcceptedValue {
                    #expect(!first.atom.isCurrent(retired.publication.request))
                }
                await ports.release(1)
                _ = try await fixture.completed(next.opening.initialExecution, for: next)
                await monitor?.value
                #expect(
                    next.atom.value?.selectedAsk?.key == selected,
                    "The current read may validate that source for its new owner")
            } catch {
                await ports.release(1)
                await monitor?.value
                throw error
            }
        }
    }
}
