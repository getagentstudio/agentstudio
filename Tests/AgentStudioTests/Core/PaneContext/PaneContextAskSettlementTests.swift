import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane context ask settlement")
struct PaneContextAskSettlementTests {
    @Test("Only the first person answer commits, with an unconfirmed receipt")
    func answerSettlesOnce() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: true)
            try await fixture.sendCreated(ask, to: service)
            let request = AnswerAskRequest(
                messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("first"))

            #expect(await service.answer(request) == .answered)
            #expect(await service.answer(request) == .refused(.alreadyAnswered))
            #expect(
                await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId)
                    == .answered(.text("first")))
            #expect(
                try await fixture.detail(service).messages.first?.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), askWaiting(ask),
                        .answered(by: .localUser, value: .text("first"), receipt: .notYetConfirmed)))
            #expect(try await fixture.changes(service).entries.count == 1)
        }
    }

    @Test("Dismissal hands blocking asks back and dismisses nonblocking asks", arguments: [false, true])
    func dismissMatchesWaitingMode(blocking: Bool) async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: blocking)
            try await fixture.sendCreated(ask, to: service)

            #expect(await service.dismiss(messageId: ask.messageId, paneId: fixture.paneId) == .done)
            let terminal: AskState = blocking ? .handedBack : .dismissed
            #expect(
                try await fixture.detail(service).messages.first?.shape
                    == .ask(.question, .freeText(placeholder: nil), askWaiting(ask), terminal))
            let refusal: AnswerRefusal = blocking ? .handedBack : .dismissed
            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("late")))
                    == .refused(refusal))
            if blocking {
                #expect(
                    await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId) == .handedBack)
            }
        }
    }

    @Test("Caller disconnect withdraws only a blocking ask", arguments: [false, true])
    func callerGoneMatchesWaitingMode(blocking: Bool) async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: blocking)
            try await fixture.sendCreated(ask, to: service)

            _ = await service.settleAsk(ask.messageId, paneId: fixture.paneId, cause: .callerGone)

            #expect(
                try await fixture.detail(service).messages.first?.shape
                    == .ask(.question, .freeText(placeholder: nil), askWaiting(ask), blocking ? .withdrawn : .open))
            if blocking {
                #expect(await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId) == .withdrawn)
            }
        }
    }

    @Test("EOF commits while an answer's write is held; the answer is refused")
    func callerGoneWinsHeldAnswer() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: true)
            try await fixture.sendCreated(ask, to: service)
            let answer = AnswerAskRequest(
                messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("late"))

            let result = try await withHeldPaneContextWrite(
                fixture: fixture, name: "answer transaction before EOF", operation: { await service.answer(answer) },
                whileHeld: {
                    #expect(
                        await service.settleAsk(ask.messageId, paneId: fixture.paneId, cause: .callerGone)
                            == .settled(.withdrawn))
                }
            )

            #expect(result == .refused(.withdrawn))
            #expect(await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId) == .withdrawn)
            #expect(try await fixture.changes(service).entries.count == 1)
        }
    }

    @Test("An answer commits while EOF's write is held; later EOF cannot change it")
    func answerWinsHeldCallerGone() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: true)
            try await fixture.sendCreated(ask, to: service)
            let result = try await withHeldPaneContextWrite(
                fixture: fixture, name: "EOF transaction before answer",
                operation: { await service.settleAsk(ask.messageId, paneId: fixture.paneId, cause: .callerGone) },
                whileHeld: {
                    #expect(
                        await service.answer(
                            AnswerAskRequest(
                                messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("won")))
                            == .answered)
                }
            )

            #expect(
                result == .alreadySettled(.answered(by: .localUser, value: .text("won"), receipt: .notYetConfirmed)))
            #expect(
                await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId)
                    == .answered(.text("won")))
            #expect(try await fixture.changes(service).entries.count == 1)
        }
    }

    @Test("Late answer sees the deadline at commit even while the expiry transaction is held")
    func lateAnswerCannotBeatHeldExpiry() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: true, deadline: fixture.time.now.addingTimeInterval(10))
            try await fixture.sendCreated(ask, to: service)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            let expiry = HeldStep<Void>("expiry transaction held past deadline", cancellation: .holdThroughCancellation)
            await fixture.sqliteAccess.holdNextWrite(expiry)
            fixture.clock.advance(by: .seconds(10))
            do {
                try await expiry.firstArrival()
                #expect(
                    await service.answer(
                        AnswerAskRequest(
                            messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("too late")))
                        == .refused(.expired))
                expiry.release()
                #expect(await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId) == .expired)
            } catch {
                expiry.retire()
                throw error
            }
            let hasAnswer = try await fixture.changes(service).entries.contains {
                if case .answer = $0.kind { true } else { false }
            }
            #expect(!hasAnswer)
        }
    }

    @Test("A controlled deadline automatically resolves the wait without another write")
    func deadlineResolvesWait() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: true, deadline: fixture.time.now.addingTimeInterval(10))
            try await fixture.sendCreated(ask, to: service)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)

            fixture.clock.advance(by: .seconds(10))

            #expect(await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId) == .expired)
            #expect(await service.send(ask) == .existing(ask.messageId))
        }
    }

    @Test("Shutdown makes a waiting blocking ask stale, not withdrawn")
    func appStoppingIsStale() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: true)
            try await fixture.sendCreated(ask, to: service)

            #expect(
                await service.settleAsk(ask.messageId, paneId: fixture.paneId, cause: .appStopping) == .settled(.stale))
            #expect(await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId) == .stale)
        }
    }

    @Test("First open of a new service makes persisted blocking asks stale but keeps nonblocking asks open")
    func startupRecoversPersistedAsks() async throws {
        try await withPaneContextService { fixture, service in
            let blocking = fixture.ask(blocking: true)
            let nonblocking = fixture.ask()
            try await fixture.sendCreated(blocking, to: service)
            try await fixture.sendCreated(nonblocking, to: service)
            let restarted = fixture.makeService()
            do {
                let detail = try await fixture.detail(restarted)
                #expect(
                    detail.messages.first { $0.id == blocking.messageId }?.shape
                        == .ask(.question, .freeText(placeholder: nil), askWaiting(blocking), .stale))
                #expect(
                    detail.messages.first { $0.id == nonblocking.messageId }?.shape
                        == .ask(.question, .freeText(placeholder: nil), .nonBlocking, .open))
                #expect(
                    await restarted.waitForAskOutcome(messageId: blocking.messageId, paneId: fixture.paneId) == .stale)
                await restarted.stop()
            } catch {
                await restarted.stop()
                throw error
            }
        }
    }

    @Test("Choice validation refuses unknown ids and multiple values for a single-choice ask")
    func choiceValidationIsAtCommit() async throws {
        try await withPaneContextService { fixture, service in
            let allow = try AskChoiceId("allow")
            let deny = try AskChoiceId("deny")
            let missing = try AskChoiceId("missing")
            let form = AskForm.choice(
                options: [AskChoice(id: allow, label: "Allow"), AskChoice(id: deny, label: "Deny")],
                allowsMultiple: false)
            let ask = fixture.ask(form: form)
            try await fixture.sendCreated(ask, to: service)
            let before = try await fixture.detail(service)

            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .choices([missing])))
                    == .refused(.invalidAnswer(.unknownChoice(missing))))
            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser,
                        value: .choices([allow, deny]))) == .refused(.invalidAnswer(.choiceCount)))
            #expect(try await fixture.detail(service) == before)
            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .choices([allow])))
                    == .answered)
        }
    }

    @Test("Wrong answer form and oversized text leave the ask open")
    func textValidationLeavesOpenAsk() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask()
            try await fixture.sendCreated(ask, to: service)
            let before = try await fixture.detail(service)

            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .choices([])))
                    == .refused(.invalidAnswer(.formMismatch)))
            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser,
                        value: .text(String(repeating: "x", count: 8193)))) == .refused(.invalidAnswer(.textTooLarge)))
            #expect(try await fixture.detail(service) == before)
        }
    }

    @Test("A failing SQLite answer transaction rolls back the ask and its change entry")
    func failedCommitLeavesAskUnchanged() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask()
            try await fixture.sendCreated(ask, to: service)
            let before = try await fixture.detail(service)
            try await fixture.databasePool.write { database in
                try database.execute(
                    sql:
                        "CREATE TRIGGER test_reject_pane_answer BEFORE INSERT ON pane_event WHEN NEW.kind = 'answer' BEGIN SELECT RAISE(ABORT, 'forced test failure'); END"
                )
            }

            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("answer")))
                    == .unavailable(.commitFailed))

            #expect(try await fixture.detail(service) == before)
            #expect(try await fixture.changes(service).entries.isEmpty)
        }
    }

    @Test("Sender withdrawal settles an open ask once and rejects any later answer")
    func senderWithdrawsAsk() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask(blocking: true)
            try await fixture.sendCreated(ask, to: service)

            #expect(
                await service.withdraw(messageId: ask.messageId, paneId: fixture.paneId, writer: fixture.sender)
                    == .withdrawn)
            #expect(await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId) == .withdrawn)
            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("late")))
                    == .refused(.withdrawn))
            #expect(try await fixture.changes(service).entries.count == 1)
        }
    }

    @Test("Flat elicitation validates required fields, integer bounds and value kinds")
    func elicitationAnswerValidation() async throws {
        try await withPaneContextService { fixture, service in
            let schema = ElicitationSchema(
                properties: [
                    ElicitationProperty(
                        name: "name", title: nil, description: nil,
                        type: .string(
                            ElicitationStringConstraints(choices: nil, minLength: 1, maxLength: 20, format: nil))),
                    ElicitationProperty(
                        name: "count", title: nil, description: nil,
                        type: .integer(ElicitationNumberConstraints(minimum: 1, maximum: 10))),
                    ElicitationProperty(name: "enabled", title: nil, description: nil, type: .boolean),
                ],
                required: ["name", "count"]
            )
            let ask = fixture.ask(form: .elicitation(schema))
            try await fixture.sendCreated(ask, to: service)
            let before = try await fixture.detail(service)
            let missing = AskAnswerValue.form(ElicitationValues(properties: ["count": .integer(2)]))
            let badCount = AskAnswerValue.form(
                ElicitationValues(properties: ["name": .string("value"), "count": .integer(11)]))

            #expect(
                await service.answer(
                    AnswerAskRequest(messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: missing))
                    == .refused(.invalidAnswer(.invalidField("name"))))
            #expect(
                await service.answer(
                    AnswerAskRequest(messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: badCount))
                    == .refused(.invalidAnswer(.invalidField("count"))))
            #expect(try await fixture.detail(service) == before)
            let valid = AskAnswerValue.form(
                ElicitationValues(properties: [
                    "name": .string("value"), "count": .integer(2), "enabled": .boolean(true),
                ]))
            #expect(
                await service.answer(
                    AnswerAskRequest(messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: valid))
                    == .answered)
        }
    }
}

private func askWaiting(_ request: PaneMessageSendRequest) -> AskWaiting {
    if case .ask(_, _, let waiting) = request.shape { return waiting }
    return .nonBlocking
}
