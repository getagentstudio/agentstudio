import AgentStudioCore
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextCardControllerTests {
    @Test(
        "canonical drawer detachment clears retained display and rejects an old exact result", arguments: [false, true])
    func detachedDrawerCannotRetainOrReviveAsk(detachDuringExact: Bool) async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let key = PaneContextMessageKey(paneId: drawer, messageId: id)
        let ask = try PaneContextMessageFixtures.askDetail(pane: drawer, id: id, state: .open, revision: 1).messages[0]
        let detail = PaneContextPopoverShapingTests.detail(
            paneId: owner,
            drawers: [.init(sourcePaneId: drawer, messages: [ask])])
        let ports = PaneContextPopoverTestPorts(detail, heldReads: detachDuringExact ? [] : [1])
        await ports.configureExactReads([], held: detachDuringExact ? [1] : [])
        let sources = [
            owner: PaneContextPreparedDetailFixture.cardSource(owner, selected: key, children: [drawer]),
            drawer: PaneContextPreparedDetailFixture.source(drawer, parent: owner),
        ]
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: owner, ports: ports,
            location: .card, content: .card, sources: sources
        ) { fixture, handle in
            try #require(handle.atom.value?.selectedAsk?.key == key)
            if !detachDuringExact {
                fixture.setSource(PaneContextPreparedDetailFixture.cardSource(owner, selected: key), for: owner)
            }
            await fixture.bindings.owner.refreshImmediately(handle.key, opening: handle.opening.epoch)
            let execution = try #require(await fixture.bindings.owner.latestExecution(for: handle.key))
            let monitor = Task {
                await execution.task.value
                await ports.detailProducerEnded(beforeRead: 1)
                await ports.exactProducerEnded(beforeRead: 1)
            }
            do {
                if detachDuringExact {
                    try await ports.exactReads.expectNext(in: 1, .started(drawer, id))
                    fixture.setSource(PaneContextPreparedDetailFixture.cardSource(owner, selected: key), for: owner)
                    await ports.releaseExact(1)
                } else {
                    try await ports.reads.expectNext(in: 1, .started(.init(paneId: owner, page: .first)))
                    #expect(handle.atom.value?.selectedAsk == nil, "Known detachment must clear before the held read")
                    await ports.release(1)
                }
                await monitor.value
                let actor = try #require(fixture.bindings.owner as? PaneContextPopoverRefreshOwner<TestPushClock>)
                #expect(
                    await actor.consumers[handle.key]?.capture?.sources[owner]?.structuralFacts?.ownedDrawerPaneIDs
                        .isEmpty == true,
                    "The real owner must have captured the canonical detachment before this assertion")
                #expect(
                    handle.atom.value?.selectedAsk == nil,
                    "An old exact result cannot revive a source already known detached")
                #expect(
                    handle.atom.value?.card?.request == CardModel.Request.none,
                    "The prepared request consumed by the real card must also be empty")
                #expect(await ports.requests.count == 2, "The input clear must not issue another data read")
                if detachDuringExact {
                    let publication = try #require(handle.atom.latestAcceptedValue?.publication)
                    guard case .input(let operation) = publication.producer else {
                        Issue.record("The late known-detachment clear must come from its input work")
                        throw DetachmentProofFailure.wrongProducer
                    }
                    #expect(fixture.bridge.didFinish(.input(operation)))
                }
                #expect(await ports.exactRequests.count == (detachDuringExact ? 2 : 1))
            } catch {
                if detachDuringExact { await ports.releaseExact(1) } else { await ports.release(1) }
                await monitor.value
                throw error
            }
        }
    }
}

private enum DetachmentProofFailure: Error { case wrongProducer }
