import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane context answer positions")
struct PaneContextAnswerPositionTests {
    @Test("Reading answers confirms only the caller-reported position, never the returned next position")
    func receiptRequiresReportedPosition() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask()
            try await fixture.sendCreated(ask, to: service)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("answer")))
                    == .answered)

            let first = try await fixture.changes(service)
            let entry = try #require(first.entries.first)
            #expect(entry.messageId == ask.messageId)
            #expect(entry.kind == .answer(.text("answer")))
            #expect(entry.position.value > 0)
            #expect(first.nextPosition == entry.position)
            #expect(try await answerReceipt(fixture, service, id: ask.messageId) == .notYetConfirmed)
            #expect(try await fixture.changes(service).entries == first.entries)

            let confirmed = try await fixture.changes(service, after: first.nextPosition.value)
            #expect(confirmed.entries.isEmpty)
            #expect(try await answerReceipt(fixture, service, id: ask.messageId) == .confirmed(at: fixture.time.now))
            #expect(try await fixture.changes(service, after: 0).entries == first.entries)
            #expect(try await answerReceipt(fixture, service, id: ask.messageId) == .confirmed(at: fixture.time.now))
        }
    }

    @Test("Position acknowledgment does not mark an unrelated notice read")
    func answerReadsKeepPersonReadStateSeparate() async throws {
        try await withPaneContextService { fixture, service in
            let notice = fixture.message()
            let ask = fixture.ask()
            try await fixture.sendCreated(notice, to: service)
            try await fixture.sendCreated(ask, to: service)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("ok")))
                    == .answered)
            let page = try await fixture.changes(service)

            _ = try await fixture.changes(service, after: page.nextPosition.value)

            #expect(
                try await fixture.detail(service).messages.first { $0.id == notice.messageId }?.shape
                    == .notice(.unread))
        }
    }

    @Test("The answer position orders records even when wall time moves backward")
    func positionsUseAdmissionOrder() async throws {
        try await withPaneContextService { fixture, service in
            let first = fixture.ask()
            let second = fixture.ask()
            try await fixture.sendCreated(first, to: service)
            try await fixture.sendCreated(second, to: service)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: first.messageId, paneId: fixture.paneId, by: .localUser, value: .text("first")))
                    == .answered)
            fixture.time.shiftWallTime(by: -3600)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: second.messageId, paneId: fixture.paneId, by: .localUser, value: .text("second")))
                    == .answered)

            let page = try await fixture.changes(service)

            #expect(page.entries.map(\.messageId) == [first.messageId, second.messageId])
            #expect(page.entries[0].position.value < page.entries[1].position.value)
        }
    }

    @Test("Answers and person dismissals are delivered only to their owning session")
    func changesAreScopedToSender() async throws {
        try await withPaneContextService { fixture, service in
            let first = fixture.message()
            try await fixture.sendCreated(first, to: service)
            let replacement = AgentMessageSender.session(
                provider: try BridgeAgentProviderName("claude-code"), sessionRef: try BridgeAgentSessionRef("other"),
                bindingGeneration: UUIDv7.generate())
            try await fixture.bind(replacement)
            let second = fixture.message(sender: replacement)
            try await fixture.sendCreated(second, to: service)
            try #require(await service.dismiss(messageId: first.messageId, paneId: fixture.paneId) == .done)
            try #require(await service.dismiss(messageId: second.messageId, paneId: fixture.paneId) == .done)

            #expect(try await fixture.changes(service).entries.map(\.messageId) == [first.messageId])
            #expect(
                try await fixture.changes(service, sender: replacement).entries.map(\.messageId) == [second.messageId])
        }
    }

    @Test("A session ending before its receipt confirmation leaves the answer unconfirmed")
    func sessionEndCannotClaimReceipt() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask()
            try await fixture.sendCreated(ask, to: service)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("ok")))
                    == .answered)

            await service.sessionEnded(bindingGenerationId: try fixture.bindingGenerationId)

            #expect(try await answerReceipt(fixture, service, id: ask.messageId) == .unconfirmed)
        }
    }

    @Test("Unread changes survive a day; acknowledgment plus age permits pruning")
    func changeRetentionRequiresBothConditions() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask()
            try await fixture.sendCreated(ask, to: service)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("durable")))
                    == .answered)
            let original = try await fixture.changes(service)
            _ = try #require(original.entries.first)
            fixture.clock.advance(by: .seconds(86_401))

            #expect(try await fixture.changes(service).entries == original.entries)
            _ = try await fixture.changes(service, after: original.nextPosition.value)
            #expect(try await fixture.changes(service, after: 0).entries.isEmpty)
        }
    }

    @Test("A reset bookmark replays an acknowledged answer within the day-long retention window")
    func resetBookmarkDoesNotLoseRecentAnswers() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask()
            try await fixture.sendCreated(ask, to: service)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("kept")))
                    == .answered)
            let original = try await fixture.changes(service)
            _ = try await fixture.changes(service, after: original.nextPosition.value)

            #expect(try await fixture.changes(service, after: 0).entries == original.entries)
        }
    }

    @Test("Change pages stop at two hundred entries and resume from the last returned position")
    func changeEntryCountPaging() async throws {
        try await withPaneContextService { fixture, service in
            var expected: [AgentMessageId] = []
            for _ in 0..<205 {
                let ask = fixture.ask()
                try await fixture.sendCreated(ask, to: service)
                try #require(
                    await service.answer(
                        AnswerAskRequest(
                            messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("answer")))
                        == .answered)
                expected.append(ask.messageId)
            }

            let first = try await fixture.changes(service)
            #expect(first.entries.count == 200)
            #expect(first.more)
            #expect(first.nextPosition == first.entries.last?.position)
            let second = try await fixture.changes(service, after: first.nextPosition.value)
            #expect(second.entries.count == 5)
            #expect(!second.more)
            #expect((first.entries + second.entries).map(\.messageId) == expected)
        }
    }

    @Test("Change byte budget takes precedence over the two-hundred-entry cap")
    func changeBytePaging() async throws {
        try await withPaneContextService { fixture, service in
            var expected = Set<AgentMessageId>()
            let answer = AskAnswerValue.text(String(repeating: "x", count: 8192))
            for _ in 0..<64 {
                let ask = fixture.ask()
                try await fixture.sendCreated(ask, to: service)
                try #require(
                    await service.answer(
                        AnswerAskRequest(
                            messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: answer))
                        == .answered)
                expected.insert(ask.messageId)
            }
            let first = try await fixture.changes(service)
            try #require(first.more)
            #expect(first.entries.count < 64)
            var seen = Set(first.entries.map(\.messageId))
            var previous = first.nextPosition.value
            var more = first.more
            while more {
                let page = try await fixture.changes(service, after: previous)
                try #require(!page.entries.isEmpty)
                try #require(page.nextPosition.value > previous)
                #expect(
                    page.entries.reduce(0) { count, entry in
                        if case .answer(.text(let value)) = entry.kind { count + value.utf8.count } else { count }
                    } <= 262_144)
                for entry in page.entries { #expect(seen.insert(entry.messageId).inserted) }
                previous = page.nextPosition.value
                more = page.more
            }
            #expect(seen == expected)
        }
    }
}

private func answerReceipt(_ fixture: PaneContextServiceFixture, _ service: PaneContextService, id: AgentMessageId)
    async throws -> AnswerReceipt
{
    let message = try #require(try await fixture.detail(service).messages.first { $0.id == id })
    let receipt: AnswerReceipt?
    if case .ask(_, _, _, .answered(_, _, let value)) = message.shape { receipt = value } else { receipt = nil }
    return try #require(receipt)
}
