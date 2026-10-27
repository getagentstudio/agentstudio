import AgentStudioCore
import AgentStudioSharedComponents
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
        let ask = try PaneContextPopoverControllerTests.askDetail(pane: drawer, id: id, state: .open, revision: 1)
            .messages[0]
        let detail = PaneContextPopoverShapingTests.detail(
            paneId: owner, drawers: [.init(sourcePaneId: drawer, messages: [ask])])
        let ports = PaneContextPopoverTestPorts(detail, heldReads: detachDuringExact ? [] : [1])
        await ports.configureExactReads([], held: detachDuringExact ? [1] : [])
        let scope = CardTestSourceScope([owner, drawer])
        let controller = PaneContextPopoverController(
            reader: ports, person: ports, location: .card, titleForPane: { _ in nil },
            refreshKeyForPane: { _ in
                .init(
                    displayRevision: .init(1),
                    sources: scope.sources.map {
                        .init(paneId: $0, promptListRevision: 0)
                    })
            }, countsForPane: { _ in .zero })
        await controller.openCard(owner, selection: .ask(source: drawer, message: id))
        try #require(controller.selectedAsk?.key == .init(paneId: drawer, messageId: id))
        if !detachDuringExact { scope.sources = [owner] }
        let refresh = Task {
            await controller.refresh()
            await ports.detailProducerEnded(beforeRead: 1)
            await ports.exactProducerEnded(beforeRead: 1)
        }
        do {
            if detachDuringExact {
                try await ports.exactReads.expectNext(in: 1, .started(drawer, id))
                scope.sources = [owner]
                await ports.releaseExact(1)
            } else {
                try await ports.reads.expectNext(in: 1, .started(.init(paneId: owner, page: .first)))
                #expect(controller.selectedAsk == nil, "Known detachment must clear before the held read")
                await ports.release(1)
            }
            await refresh.value
            #expect(controller.selectedAsk == nil, "An old exact result cannot revive a detached source")
            #expect(await ports.exactRequests.count == (detachDuringExact ? 2 : 1))
            controller.close()
            try await ports.finish()
        } catch {
            controller.close()
            if detachDuringExact { await ports.releaseExact(1) } else { await ports.release(1) }
            await refresh.value
            try? await ports.finish()
            throw error
        }
    }
}

@MainActor
private final class CardTestSourceScope {
    var sources: [PaneId]
    init(_ sources: [PaneId]) { self.sources = sources }
}
