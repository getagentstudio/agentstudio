import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextCardControllerTests {
    @Test("moving the same selected source key to another owner clears display before reading")
    func changedOwnerClearsSameSourceKeyBeforeReading() async throws {
        let firstOwner = PaneId.generateUUIDv7()
        let nextOwner = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextPopoverControllerTests.askDetail(
            pane: firstOwner, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        let controller = PaneContextPopoverController(
            reader: ports, person: ports, location: .card, titleForPane: { _ in nil },
            refreshKeyForPane: { _ in
                .init(
                    displayRevision: .init(1),
                    sources: [firstOwner, nextOwner].map {
                        .init(paneId: $0, promptListRevision: 0)
                    })
            }, countsForPane: { _ in .zero })
        let sameSelection = CardRequestSelection.ask(source: firstOwner, message: id)
        await controller.openCard(firstOwner, selection: sameSelection)
        try #require(controller.selectedAsk != nil)
        let move = Task {
            await controller.openCard(nextOwner, selection: sameSelection)
            await ports.detailProducerEnded(beforeRead: 1)
        }
        var released = false
        do {
            try await ports.reads.expectNext(in: 1, .started(.init(paneId: nextOwner, page: .first)))
            #expect(controller.selectedAsk == nil, "Matching source/message alone cannot retain across owners")
            await ports.release(1)
            released = true
            await move.value
            controller.close()
            try await ports.finish()
        } catch {
            controller.close()
            if !released { await ports.release(1) }
            await move.value
            try? await ports.finish()
            throw error
        }
    }
}
