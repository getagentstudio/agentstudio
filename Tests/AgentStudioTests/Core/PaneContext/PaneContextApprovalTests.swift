import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane approval persistence and admission")
struct PaneContextApprovalTests {
    struct DecisionCase: Sendable {
        let decision: PaneMessageApprovalDecision
        let reason: String?
        let storedValue: String
        let confirmedLabel: String
    }

    @Test(
        "Approval decisions survive real full/compact reads with the exact existing-column encoding",
        arguments: [
            DecisionCase(
                decision: .approve, reason: "Reviewed the migration", storedValue: "approve",
                confirmedLabel: "Answered: Approved · Reviewed the migration"),
            .init(decision: .approve, reason: nil, storedValue: "approve", confirmedLabel: "Answered: Approved"),
            .init(
                decision: .deny, reason: "The migration is unsafe", storedValue: "deny",
                confirmedLabel: "Answered: Denied · The migration is unsafe"),
            .init(decision: .deny, reason: nil, storedValue: "deny", confirmedLabel: "Answered: Denied"),
        ])
    func approvalRoundTripsThroughSQLite(_ input: DecisionCase) async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.ask(form: .approval, blocking: true)
            try await fixture.sendCreated(request, to: service)
            let answer = AskAnswerValue.decision(input.decision, reason: input.reason)
            let person = AnswerAskRequest(
                messageId: request.messageId, paneId: fixture.paneId, by: .localUser, value: answer)

            #expect(await service.answer(person) == .answered)
            #expect(await service.answer(person) == .refused(.alreadyAnswered))
            #expect(
                await service.waitForAskOutcome(messageId: request.messageId, paneId: fixture.paneId)
                    == .answered(answer))

            let detail = try await fixture.detail(service)
            #expect(
                detail.messages.first?.shape
                    == .ask(
                        .question, .approval, .blocking(deadline: fixture.time.now.addingTimeInterval(60)),
                        .answered(by: .localUser, value: answer, receipt: .notYetConfirmed)))
            let display = try #require(await service.readDisplay(paneId: fixture.paneId))
            #expect(display.own.kinds == .zero)
            #expect(display.own.oldestOpenAsk == nil)
            let pending = try await fixture.changes(service)
            #expect(pending.entries.map(\.kind) == [.answer(answer)])
            #expect(try await fixture.changes(service, after: pending.nextPosition.value).entries.isEmpty)
            let confirmed = try #require(try await fixture.detail(service).messages.first)
            #expect(PaneContextPresentationRules.settledLabel(confirmed) == input.confirmedLabel)
            let messageId = request.messageId.uuid.uuidString
            let encoded: [String?] = try await fixture.databasePool.read { database in
                let row = try #require(
                    try Row.fetchOne(
                        database,
                        sql: "SELECT * FROM pane_request WHERE message_id = ?", arguments: [messageId]))
                let requestId: String = row["id"]
                let children = try Row.fetchAll(
                    database,
                    sql: "SELECT * FROM pane_request_answer_value WHERE request_id = ?", arguments: [requestId])
                try #require(children.count == 1)
                let ordinal: Int = children[0]["ordinal"]
                let choices = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM pane_request_choice WHERE request_id = ?", arguments: [requestId])
                let properties = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM pane_request_property WHERE request_id = ?", arguments: [requestId])
                #expect(ordinal == 0)
                #expect(choices == 0)
                #expect(properties == 0)
                return [
                    row["form_kind"], row["answer_kind"], row["answer_text"],
                    children[0]["field_name"], children[0]["value_kind"], children[0]["text_value"],
                ]
            }
            #expect(encoded == ["approval", "decision", input.reason, "decision", "decision", input.storedValue])
        }
    }

    @Test("Approval accepts only decisions; every other form refuses decisions")
    func mismatchedAnswersRemainOpen() async throws {
        try await withPaneContextService { fixture, service in
            let choice = AskChoice(id: try .init("yes"), label: "Yes")
            let pairs: [(AskForm, AskAnswerValue)] = [
                (.approval, .text("approve")), (.approval, .choices([choice.id])),
                (.approval, .form(.init(properties: [:]))),
                (.freeText(placeholder: nil), .decision(.approve, reason: nil)),
                (.choice(options: [choice], allowsMultiple: false), .decision(.deny, reason: "No")),
                (.elicitation(.init(properties: [], required: [])), .decision(.approve, reason: nil)),
            ]
            for (form, answer) in pairs {
                let request = fixture.ask(form: form)
                try await fixture.sendCreated(request, to: service)
                #expect(
                    await service.answer(
                        .init(
                            messageId: request.messageId, paneId: fixture.paneId, by: .localUser, value: answer))
                        == .refused(.invalidAnswer(.formMismatch)))
                guard
                    case .found(let stored) = await service.readMessage(
                        source: fixture.paneId, message: request.messageId)
                else {
                    Issue.record("Missing refused request")
                    return
                }
                #expect(stored.shape == .ask(.question, form, .nonBlocking, .open))
            }
            let oversized = fixture.ask(form: .approval)
            try await fixture.sendCreated(oversized, to: service)
            #expect(
                await service.answer(
                    .init(
                        messageId: oversized.messageId, paneId: fixture.paneId,
                        by: .localUser, value: .decision(.approve, reason: String(repeating: "r", count: 8193))))
                    == .refused(.invalidAnswer(.textTooLarge)))
            #expect(try await fixture.changes(service).entries.isEmpty)
        }
    }

    @Test(
        "The explicit decision decoder rejects malformed child rows",
        arguments: [
            "DELETE FROM pane_request_answer_value",
            "UPDATE pane_request_answer_value SET ordinal = 1",
            "UPDATE pane_request_answer_value SET field_name = 'other'",
            "UPDATE pane_request_answer_value SET value_kind = 'text'",
            "UPDATE pane_request_answer_value SET text_value = 'maybe'",
            "INSERT INTO pane_request_answer_value (request_id, ordinal, field_name, value_kind, text_value) SELECT request_id, 1, field_name, value_kind, text_value FROM pane_request_answer_value",
        ])
    func malformedDecisionCannotDecode(statement: String) async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.ask(form: .approval)
            try await fixture.sendCreated(request, to: service)
            try #require(
                await service.answer(
                    .init(
                        messageId: request.messageId, paneId: fixture.paneId,
                        by: .localUser, value: .decision(.deny, reason: nil))) == .answered)
            try await fixture.databasePool.write { database in try database.execute(sql: statement) }

            let result = await service.readDetail(.init(paneId: fixture.paneId, page: .first))

            #expect(result == .unavailable(.decodeFailed("answer_decision")))
        }
    }
}
