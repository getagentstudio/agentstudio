import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Exact card request lifetime", .serialized)
struct PaneContextCardControllerTests {
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
