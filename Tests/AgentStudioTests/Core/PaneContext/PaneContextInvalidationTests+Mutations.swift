import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

extension PaneContextInvalidationTests {
    enum Mutation: CaseIterable, Equatable, Sendable {
        case title, line, markRead, dismiss, dismissAll, withdraw, answer, confirmReceipt, sessionEnd, deadline, retire,
            retention
    }

    @Test("D52 every committed detail mutation advances only its source's runtime token", arguments: Mutation.allCases)
    func mutationPathsInvalidateTheirSource(_ mutation: Mutation) async throws {
        try await withPaneContextService { fixture, service in
            let request: PaneMessageSendRequest
            switch mutation {
            case .answer, .confirmReceipt, .sessionEnd: request = fixture.ask()
            case .deadline: request = fixture.ask(blocking: true)
            default: request = fixture.message()
            }
            try await fixture.sendCreated(request, to: service)
            let epoch = try await fixture.epoch(service, stream: mutation == .line ? .line : .title)
            if mutation == .confirmReceipt || mutation == .sessionEnd {
                #expect(
                    await service.answer(
                        .init(messageId: request.messageId, paneId: fixture.paneId, by: .localUser, value: .text("Yes"))
                    ) == .answered)
            }
            if mutation == .retention {
                #expect(await service.markRead(messageId: request.messageId, paneId: fixture.paneId) == .done)
            }
            let unrelated = PaneId.generateUUIDv7()
            let before = await service.invalidationGenerations(for: [fixture.paneId, unrelated])
            let stream = await service.invalidations(for: [fixture.paneId, unrelated])
            try await perform(mutation, request: request, epoch: epoch, fixture: fixture, service: service)
            let next = (before[fixture.paneId] ?? 0) + 1
            #expect(
                await service.invalidationGenerations(for: [fixture.paneId, unrelated]) == [
                    fixture.paneId: next, unrelated: 0,
                ])
            let observed = try await Self.stopAndCollectInvalidations(service, stream: stream)
            #expect(observed == [.init(sourcePaneId: fixture.paneId, generation: next)])
        }
    }

    private func perform(
        _ mutation: Mutation, request: PaneMessageSendRequest, epoch: UInt64,
        fixture: PaneContextServiceFixture, service: PaneContextService
    ) async throws {
        switch mutation {
        case .title: #expect(await service.setTitle(fixture.title("Current", epoch: epoch, counter: 1)) == .applied)
        case .line: #expect(await service.setLine(fixture.line("Working", epoch: epoch, counter: 1)) == .applied)
        case .markRead: #expect(await service.markRead(messageId: request.messageId, paneId: fixture.paneId) == .done)
        case .dismiss: #expect(await service.dismiss(messageId: request.messageId, paneId: fixture.paneId) == .done)
        case .dismissAll:
            #expect(
                await service.dismissAllNotices(paneId: fixture.paneId, includingDrawers: false) == .dismissed(count: 1)
            )
        case .withdraw:
            #expect(
                await service.withdraw(messageId: request.messageId, paneId: fixture.paneId, writer: fixture.sender)
                    == .withdrawn)
        case .answer:
            #expect(
                await service.answer(
                    .init(messageId: request.messageId, paneId: fixture.paneId, by: .localUser, value: .text("Yes")))
                    == .answered)
        case .confirmReceipt:
            let page = try await fixture.changes(service)
            _ = try await fixture.changes(service, after: page.nextPosition.value)
            let detail = try await fixture.detail(service)
            guard case .ask(_, _, _, .answered(_, _, .confirmed)) = detail.messages.first?.shape else {
                Issue.record("The real receipt was not confirmed")
                return
            }
        case .sessionEnd: await service.sessionEnded(bindingGenerationId: try fixture.bindingGenerationId)
        case .deadline:
            fixture.time.shiftWallTime(by: 60)
            await service.deadlineReached()
            let detail = try await fixture.detail(service)
            guard case .ask(_, _, _, .expired) = detail.messages.first?.shape else {
                Issue.record("The real deadline did not expire its ask")
                return
            }
        case .retire:
            service.retire([fixture.paneId])
            try await service.drainRetirements()
            #expect(await service.readDetail(.init(paneId: fixture.paneId, page: .first)) == .paneGone)
        case .retention:
            fixture.time.shiftWallTime(by: AppPolicies.PaneContext.settledMessageLifetime)
            let display = try #require(await service.readDisplay(paneId: fixture.paneId))
            #expect(display.own.kinds == .zero)
            #expect(try await fixture.detail(service).messages.isEmpty)
        }
    }
}
