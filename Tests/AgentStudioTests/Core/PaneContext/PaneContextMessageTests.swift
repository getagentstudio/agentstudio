import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane context messages")
struct PaneContextMessageTests {
    @Test("A notice keeps exact text, attribution and source time; reading has no effect")
    func noticeReadIsPure() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message(
                sourceOccurredAt: fixture.time.now, body: "First line\n第二行 🛰️", why: "A reason")
            try await fixture.sendCreated(request, to: service)

            let first = try await fixture.detail(service)
            let second = try await fixture.detail(service)
            let message = try #require(first.messages.first)
            #expect(message.body == request.body)
            #expect(message.why == request.why)
            #expect(message.sender == fixture.sender)
            #expect(message.sourcePaneId == fixture.paneId)
            #expect(message.sourceOccurredAt == request.sourceOccurredAt)
            #expect(message.shape == .notice(.unread))
            #expect(second == first)
        }
    }

    @Test("Equivalent message replay preserves one row, receive time and revision")
    func equivalentNoticeReplays() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message()
            try await fixture.sendCreated(request, to: service)
            let before = try await fixture.detail(service)
            fixture.time.shiftWallTime(by: 100)

            #expect(await service.send(request) == .existing(request.messageId))

            #expect(try await fixture.detail(service) == before)
            let count = try await fixture.databasePool.read { database in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM pane_event WHERE kind = 'notice'")
            }
            #expect(count == 1)
        }
    }

    @Test("Changed content with the same message identity conflicts without effects")
    func conflictingMessageDoesNotMutate() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message()
            try await fixture.sendCreated(request, to: service)
            let before = try await fixture.detail(service)

            let conflict = fixture.message(id: request.messageId, body: "Different content")
            #expect(await service.send(conflict) == .refused(.conflict))
            #expect(try await fixture.detail(service) == before)
        }
    }

    @Test("Notice identity is scoped by source pane")
    func sameMessageIdOnDifferentPanes() async throws {
        try await withPaneContextService { fixture, service in
            let otherPane = PaneId.generateUUIDv7()
            fixture.membership.addPane(otherPane)
            let first = fixture.message(sender: .pane(fixture.paneId))
            let second = fixture.message(id: first.messageId, paneId: otherPane, sender: .pane(otherPane))

            try await fixture.sendCreated(first, to: service)
            try await fixture.sendCreated(second, to: service)

            #expect(try await fixture.detail(service).messages.count == 1)
            #expect(try await fixture.detail(service, paneId: otherPane).messages.count == 1)
        }
    }

    @Test("Future source time is omitted while receive time is app-owned")
    func rejectsFutureSourceTime() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message(sourceOccurredAt: fixture.time.now.addingTimeInterval(301))
            try await fixture.sendCreated(request, to: service)

            let message = try #require(try await fixture.detail(service).messages.first)
            #expect(message.sourceOccurredAt == nil)
            #expect(message.sentAt == fixture.time.now)
        }
    }

    @Test("Person marking read bumps detail revision once and preserves content")
    func personReadIsIdempotent() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message()
            try await fixture.sendCreated(request, to: service)
            let before = try await fixture.detail(service)

            #expect(await service.markRead(messageId: request.messageId, paneId: fixture.paneId) == .done)
            let after = try await fixture.detail(service)
            #expect(after.revision.value > before.revision.value)
            #expect(after.messages.first?.shape == .notice(.read))
            #expect(await service.markRead(messageId: request.messageId, paneId: fixture.paneId) == .alreadyRead)
            #expect(try await fixture.detail(service) == after)
        }
    }

    @Test("An agent cannot withdraw another sender's notice or a person-read notice")
    func withdrawalHonorsSenderAndReadState() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message()
            try await fixture.sendCreated(request, to: service)
            let before = try await fixture.detail(service)
            #expect(
                await service.withdraw(
                    messageId: request.messageId, paneId: fixture.paneId, writer: .pane(fixture.paneId))
                    == .refused(.notSender))
            #expect(try await fixture.detail(service) == before)
            try #require(await service.markRead(messageId: request.messageId, paneId: fixture.paneId) == .done)

            #expect(
                await service.withdraw(messageId: request.messageId, paneId: fixture.paneId, writer: fixture.sender)
                    == .refused(.noticeAlreadyRead))
            #expect(try await fixture.detail(service).messages.first?.shape == .notice(.read))
        }
    }

    @Test("A withdrawn notice stays withdrawn when a new service reads the same SQLite")
    func withdrawnNoticeSurvivesRestart() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message()
            try await fixture.sendCreated(request, to: service)
            try #require(
                await service.withdraw(messageId: request.messageId, paneId: fixture.paneId, writer: fixture.sender)
                    == .withdrawn)
            await service.stop()
            let restarted = fixture.makeService()
            do {
                #expect(try await fixture.detail(restarted).messages.first?.shape == .notice(.withdrawn))
                #expect(await restarted.send(request) == .existing(request.messageId))
                await restarted.stop()
            } catch {
                await restarted.stop()
                throw error
            }
        }
    }

    @Test("Notice replay after binding replacement keeps the original sender")
    func earlierSessionNoticeReplaysAfterReplacement() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message()
            try await fixture.sendCreated(request, to: service)
            let replacement = AgentMessageSender.session(
                provider: try BridgeAgentProviderName("claude-code"),
                sessionRef: try BridgeAgentSessionRef("replacement"),
                bindingGeneration: UUIDv7.generate()
            )
            try await fixture.bind(replacement)

            #expect(await service.send(request) == .existing(request.messageId))
            #expect(try await fixture.detail(service).messages.first?.sender == fixture.sender)
            let oldNotice = fixture.message(body: "Late notice from earlier session")
            try await fixture.sendCreated(oldNotice, to: service)
            #expect(
                try await fixture.detail(service).messages.contains {
                    $0.id == oldNotice.messageId && $0.sender == fixture.sender
                })
        }
    }

    @Test("Pane writers can post notices but cannot create asks")
    func asksRequireBinding() async throws {
        try await withPaneContextService { fixture, service in
            let notice = fixture.message(sender: .pane(fixture.paneId))
            try await fixture.sendCreated(notice, to: service)
            let ask = fixture.message(
                sender: .pane(fixture.paneId),
                shape: .ask(reason: .blocked, form: .freeText(placeholder: nil), waiting: .nonBlocking))

            #expect(await service.send(ask) == .refused(.bindingRequired))
            #expect(try await fixture.detail(service).messages.count == 1)
        }
    }
}
