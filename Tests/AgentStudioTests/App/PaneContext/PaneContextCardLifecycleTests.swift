import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Native card lifecycle", .serialized)
struct PaneContextCardLifecycleTests {
    @Test("the notice-only card displays its unread count and opens the real Messages list")
    func unreadCardLinkOpensMessagesWithoutARequestBlock() async throws {
        let host = try await PaneContextCardServiceHost.make(form: .freeText(placeholder: "Reply"))
        let fixture = host.fixture
        let service = fixture.composition.paneContextService
        do {
            try await host.open()
            try #require(await service.dismiss(messageId: host.id, paneId: fixture.ownerId) == .done)
            let notice = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: notice, sender: .pane(fixture.ownerId),
                        sourceOccurredAt: nil, importance: .info, body: "A retained unread notice", why: nil,
                        actions: [], shape: .notice)) == .created(notice))
            await fixture.composition.presentationLane.publishPending()
            try await host.window.refresh()
            try await host.window.renderedCard()
            #expect(host.window.native.labels().contains("1 unread ·"))
            #expect(host.window.native.labels().contains("Show messages"))
            #expect(host.window.native.find("pane-context.card-more") == nil)
            #expect(host.window.native.find("pane-context.answer-in-messages") == nil)
            let messagesOpening = try host.window.beginOpening()
            try await host.window.completeOpening(messagesOpening)
            try await host.window.rendered()
            #expect(
                host.window.value?.shape?.messages.messageRows.contains {
                    $0.id == notice.uuid && $0.body == "A retained unread notice"
                } == true)
            #expect(await service.readDisplay(paneId: fixture.ownerId)?.own.kinds.unread == 1)
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }
}
