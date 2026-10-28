import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Exact pane message reads")
struct PaneContextMessageReadingTests {
    @Test("an exact read refuses a retired source even while its stored message remains")
    func retiredSourceHasNoExactMessage() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.ask()
            try await fixture.sendCreated(request, to: service)
            guard case .found = await service.readMessage(source: fixture.paneId, message: request.messageId) else {
                Issue.record("The live ask must be readable before retirement")
                return
            }
            fixture.membership.removePane(fixture.paneId)
            service.retire([fixture.paneId])
            #expect(await service.readMessage(source: fixture.paneId, message: request.messageId) == .notFound)
        }
    }
    @Test("an exact request read reaches the oldest open ask beyond a detail-page budget")
    func exactReadFindsAnOmittedOldestAsk() async throws {
        try await withPaneContextService { fixture, service in
            var asks: [AgentMessageId] = []
            for _ in 0..<16 {
                let id = AgentMessageId.generateUUIDv7()
                asks.append(id)
                let request = PaneMessageSendRequest(
                    paneId: fixture.paneId, messageId: id, sender: fixture.sender,
                    sourceOccurredAt: nil, importance: .attention, body: String(repeating: "r", count: 4096),
                    why: nil, actions: [],
                    shape: .ask(
                        reason: .question,
                        form: .freeText(placeholder: String(repeating: "p", count: 8000)), waiting: .nonBlocking))
                try await fixture.sendCreated(request, to: service)
            }
            guard
                case .detail(let page) = await service.readDetail(
                    .init(paneId: fixture.paneId, page: .first),
                    maximumDetailBytes: 0)
            else {
                Issue.record("Missing bounded detail")
                return
            }
            let oldest = try #require(asks.first)
            #expect(!page.messages.contains { $0.id == oldest })
            guard case .found(let exact) = await service.readMessage(source: fixture.paneId, message: oldest) else {
                Issue.record("The exact reader lost an open request omitted by the detail budget")
                return
            }
            #expect(exact.id == oldest)
            #expect(exact.sourcePaneId == fixture.paneId)
            #expect(exact.body == String(repeating: "r", count: 4096))
            #expect(await service.readMessage(source: .generateUUIDv7(), message: oldest) == .notFound)
            #expect(await service.readMessage(source: fixture.paneId, message: .generateUUIDv7()) == .notFound)
        }
    }
}
