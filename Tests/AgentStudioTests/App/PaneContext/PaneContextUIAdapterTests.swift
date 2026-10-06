import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio

@Suite("Pane context UI adapter")
struct PaneContextUIAdapterTests {
    @Test("The detail seam reads the real service and current Sessions binding")
    func detailSeamUsesRealService() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("ui-detail")
            let sender = try fixture.sender(binding)
            let ask = fixture.ask(writer: sender, reason: .question)
            try #require(await fixture.service.send(ask) == .created(ask.messageId))
            let reader: any PaneContextDetailReading = PaneContextUIAdapter(service: fixture.service)
            let request = PaneContextReadRequest(paneId: fixture.paneId, page: .first)
            let expected = await fixture.service.readDetail(request)
            #expect(await reader.readDetail(request) == expected)
            #expect(await reader.readDetail(.init(paneId: .generateUUIDv7(), page: .first)) == .paneGone)
        }
    }

    @Test("A person answer reaches the real commit and duplicate-answer refusal")
    func answerSeamCommitsTypedValue() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("ui-answer")
            let ask = fixture.ask(writer: try fixture.sender(binding), reason: .question)
            try #require(await fixture.service.send(ask) == .created(ask.messageId))
            let actor: any PaneContextPersonActing = PaneContextUIAdapter(service: fixture.service)
            let request = AnswerAskRequest(
                messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("reply"))
            #expect(await actor.answer(request) == .answered)
            #expect(await actor.answer(request) == .refused(.alreadyAnswered))
            let message = try #require(try await fixture.detail().messages.first)
            #expect(
                message.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), .nonBlocking,
                        .answered(by: .localUser, value: .text("reply"), receipt: .notYetConfirmed)))
        }
    }

    @Test("Dismiss delegates to settlement, including the typed terminal reply")
    func dismissSeamPreservesTerminalResult() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("ui-dismiss")
            let ask = fixture.ask(writer: try fixture.sender(binding), reason: .approval)
            try #require(await fixture.service.send(ask) == .created(ask.messageId))
            let actor: any PaneContextPersonActing = PaneContextUIAdapter(service: fixture.service)
            #expect(await actor.dismiss(messageId: ask.messageId, paneId: fixture.paneId) == .done)
            #expect(
                await actor.dismiss(messageId: ask.messageId, paneId: fixture.paneId)
                    == .alreadySettled(.ask(.dismissed)))
            #expect(
                try await fixture.detail().messages.first?.shape
                    == .ask(
                        .approval, .freeText(placeholder: nil), .nonBlocking, .dismissed))
        }
    }

    @Test("Dismiss-all delegates through the person seam and returns its typed count")
    func dismissAllSeamUsesRealService() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let notice = PaneMessageSendRequest(
                paneId: fixture.paneId, messageId: .generateUUIDv7(), sender: .pane(fixture.paneId),
                sourceOccurredAt: nil, importance: .attention, body: "Notice", why: nil, actions: [], shape: .notice)
            let created = await fixture.service.send(notice)
            #expect(created == .created(notice.messageId))
            let person: any PaneContextPersonActing = PaneContextUIAdapter(service: fixture.service)
            let dismissed = await person.dismissAllNotices(paneId: fixture.paneId, includingDrawers: false)
            #expect(dismissed == .dismissed(count: 1))
            let detail = try await fixture.detail()
            #expect(detail.messages.first { $0.id == notice.messageId }?.shape == .notice(.dismissed))
            let repeated = await person.dismissAllNotices(paneId: fixture.paneId, includingDrawers: true)
            #expect(repeated == .dismissed(count: 0))
        }
    }

    @Test("Mark-read reaches the notice record and preserves idempotent results")
    func readSeamCommitsNoticeState() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let notice = PaneMessageSendRequest(
                paneId: fixture.paneId, messageId: .generateUUIDv7(), sender: .pane(fixture.paneId),
                sourceOccurredAt: nil, importance: .attention, body: "Unread", why: nil, actions: [], shape: .notice)
            try #require(await fixture.service.send(notice) == .created(notice.messageId))
            let actor: any PaneContextPersonActing = PaneContextUIAdapter(service: fixture.service)
            #expect(await actor.markRead(messageId: notice.messageId, paneId: fixture.paneId) == .done)
            #expect(await actor.markRead(messageId: notice.messageId, paneId: fixture.paneId) == .alreadyRead)
            #expect(try await fixture.detail().messages.first?.shape == .notice(.read))
        }
    }

    @Test("An unlisted action is refused by the real service, without a native effect")
    func actionSeamPreservesAdmission() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let notice = PaneMessageSendRequest(
                paneId: fixture.paneId, messageId: .generateUUIDv7(), sender: .pane(fixture.paneId),
                sourceOccurredAt: nil, importance: .info, body: "No actions", why: nil, actions: [], shape: .notice)
            try #require(await fixture.service.send(notice) == .created(notice.messageId))
            let actor: any PaneContextPersonActing = PaneContextUIAdapter(service: fixture.service)
            #expect(
                await actor.runAction(
                    .init(
                        messageId: notice.messageId, paneId: fixture.paneId, action: .goToPane(fixture.paneId)))
                    == .notFound)
        }
    }

    @Test("Missing records preserve typed refusals through every person seam")
    func missingRecordsRemainTyped() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let actor: any PaneContextPersonActing = PaneContextUIAdapter(service: fixture.service)
            let missing = AgentMessageId.generateUUIDv7()
            #expect(
                await actor.answer(
                    .init(
                        messageId: missing, paneId: fixture.paneId, by: .localUser, value: .text("missing")))
                    == .refused(.notFound))
            #expect(await actor.dismiss(messageId: missing, paneId: fixture.paneId) == .notFound)
            #expect(await actor.markRead(messageId: missing, paneId: fixture.paneId) == .notFound)
            #expect(
                await actor.runAction(
                    .init(
                        messageId: missing, paneId: fixture.paneId, action: .goToPane(fixture.paneId))) == .notFound)
        }
    }

    @Test("An admitted action reaches the injected native-effect port through the UI seam")
    func admittedActionPreservesNativeResult() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let service = PaneContextService(
                sqliteAccess: fixture.sqliteAccess, clock: fixture.clock, wallNow: { fixture.time.now },
                membership: fixture.membership,
                currentBindingGeneration: { paneId, database in
                    try PaneContextSessionsBridge.currentBindingGeneration(paneId: paneId, in: database)
                },
                actionRunner: { action in
                    action == .goToPane(fixture.paneId) ? .goToPane(.focused) : .notFound
                })
            do {
                let action = MessageAction.goToPane(fixture.paneId)
                let notice = PaneMessageSendRequest(
                    paneId: fixture.paneId, messageId: .generateUUIDv7(), sender: .pane(fixture.paneId),
                    sourceOccurredAt: nil, importance: .info, body: "Go to pane", why: nil,
                    actions: [action], shape: .notice)
                try #require(await service.send(notice) == .created(notice.messageId))
                let actor: any PaneContextPersonActing = PaneContextUIAdapter(service: service)
                #expect(
                    await actor.runAction(
                        .init(
                            messageId: notice.messageId, paneId: fixture.paneId, action: action)) == .goToPane(.focused)
                )
                await service.stop()
            } catch {
                await service.stop()
                throw error
            }
        }
    }
}
