import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane message kind counts from SQLite")
struct PaneMessageKindCountsServiceTests {
    @Test("The real compact read retains all four notice kinds and an independent oldest ask")
    func compactCountsKeepEveryNoticeKind() async throws {
        try await withPaneContextService { fixture, service in
            var notices: [PaneMessageSendRequest] = []
            for importance: MessageImportance in [.failure, .attention, .done, .info] {
                let request = PaneMessageSendRequest(
                    paneId: fixture.paneId, messageId: .generateUUIDv7(), sender: .pane(fixture.paneId),
                    sourceOccurredAt: nil, importance: importance, body: "Notice", why: nil, actions: [], shape: .notice
                )
                try await fixture.sendCreated(request, to: service)
                notices.append(request)
            }
            let initial = try #require(await service.readDisplay(paneId: fixture.paneId))
            #expect(initial.own.kinds == .init(failure: 1, needsYou: 1, done: 1, info: 1))
            #expect(initial.own.kinds.unread == 4)
            #expect(initial.own.oldestOpenAsk == nil)
            let ask = fixture.ask()
            try await fixture.sendCreated(ask, to: service)
            let withAsk = try #require(await service.readDisplay(paneId: fixture.paneId))
            #expect(withAsk.own.kinds == .init(failure: 1, needsYou: 2, done: 1, info: 1))
            #expect(withAsk.own.oldestOpenAsk == .init(paneId: fixture.paneId, messageId: ask.messageId))

            for notice in notices {
                try #require(await service.markRead(messageId: notice.messageId, paneId: fixture.paneId) == .done)
            }
            let read = try #require(await service.readDisplay(paneId: fixture.paneId))
            #expect(read.own.kinds == .init(failure: 0, needsYou: 1, done: 0, info: 0))
            #expect(read.own.oldestOpenAsk == .init(paneId: fixture.paneId, messageId: ask.messageId))
            try #require(await service.dismiss(messageId: ask.messageId, paneId: fixture.paneId) == .done)
            #expect(await service.readDisplay(paneId: fixture.paneId)?.own == .zero)
        }
    }
}
