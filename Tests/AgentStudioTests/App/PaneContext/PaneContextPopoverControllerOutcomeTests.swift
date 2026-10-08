import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverControllerOutcomeTests {
    struct AnswerCase: Sendable {
        let result: AnswerAskResult
        let shown: String
    }
    nonisolated static let answerCases: [AnswerCase] = [
        .init(result: .answered, shown: "Answered"),
        .init(result: .refused(.alreadyAnswered), shown: "Already answered"),
        .init(result: .refused(.handedBack), shown: "Handed back"),
        .init(result: .refused(.dismissed), shown: "Dismissed"),
        .init(result: .refused(.expired), shown: "Expired"),
        .init(result: .refused(.withdrawn), shown: "Withdrawn"),
        .init(result: .refused(.stale), shown: "Stale"),
        .init(result: .refused(.notFound), shown: "Message not found"),
        .init(result: .refused(.invalidAnswer(.formMismatch)), shown: "Invalid answer: form mismatch"),
        .init(
            result: .refused(.invalidAnswer(.unknownChoice(try! .init("unknown")))),
            shown: "Invalid answer: unknown choice unknown"),
        .init(result: .refused(.invalidAnswer(.choiceCount)), shown: "Invalid answer: choice count"),
        .init(result: .refused(.invalidAnswer(.textTooLarge)), shown: "Invalid answer: text too large"),
        .init(result: .refused(.invalidAnswer(.invalidField("count"))), shown: "Invalid answer: field count"),
        .init(result: .unavailable(.databaseUnavailable), shown: "Answer unavailable: database unavailable"),
        .init(result: .unavailable(.commitFailed), shown: "Answer unavailable: commit failed"),
        .init(result: .unavailable(.decodeFailed("field")), shown: "Answer unavailable: decode failed: field"),
    ]

    @Test(arguments: answerCases)
    func everyAnswerOutcomeIsVisibleAndTheCallerIsLocal(scenario: AnswerCase) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let initial = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(initial)
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        await ports.configureAnswer(scenario.result)
        let settled: AskState
        switch scenario.result {
        case .answered, .refused(.alreadyAnswered):
            settled = .answered(by: .localUser, value: .text("Yes"), receipt: .notYetConfirmed)
        case .refused(.handedBack): settled = .handedBack
        case .refused(.dismissed): settled = .dismissed
        case .refused(.expired): settled = .expired
        case .refused(.withdrawn): settled = .withdrawn
        case .refused(.stale): settled = .stale
        case .refused(.notFound), .refused(.invalidAnswer), .unavailable: settled = .open
        }
        await ports.setDetail(
            try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: settled, revision: 2))
        await controller.answer(messageId: id, source: pane, value: .text("Yes"))
        #expect(controller.actionFeedback == scenario.shown)
        #expect(await ports.answers == [.init(messageId: id, paneId: pane, by: .localUser, value: .text("Yes"))])
        await controller.refresh()
        #expect(controller.actionFeedback == scenario.shown)
        controller.close()
        try await ports.finish()
    }

    struct DismissCase: Sendable {
        let result: DismissResult
        let shown: String
    }
    nonisolated static let dismissCases: [DismissCase] = [
        .init(result: .done, shown: "Dismissed"),
        .init(
            result: .alreadySettled(
                .ask(.answered(by: .localUser, value: .text("Yes"), receipt: .confirmed(at: .distantPast)))),
            shown: "Already answered"),
        .init(result: .alreadySettled(.ask(.handedBack)), shown: "Already handed back"),
        .init(result: .alreadySettled(.ask(.dismissed)), shown: "Already dismissed"),
        .init(result: .alreadySettled(.ask(.expired)), shown: "Already expired"),
        .init(result: .alreadySettled(.ask(.withdrawn)), shown: "Already withdrawn"),
        .init(result: .alreadySettled(.ask(.stale)), shown: "Already stale"),
        .init(result: .alreadySettled(.notice(.dismissed)), shown: "Already dismissed"),
        .init(result: .alreadySettled(.notice(.withdrawn)), shown: "Already withdrawn"),
        .init(result: .notFound, shown: "Message not found"),
        .init(result: .unavailable(.databaseUnavailable), shown: "Dismiss unavailable: database unavailable"),
    ]
    @Test(arguments: dismissCases)
    func everyDismissOutcomeIsVisible(scenario: DismissCase) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(
            try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1))
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        await ports.configureDismiss(scenario.result)
        await controller.dismiss(messageId: id, source: pane)
        #expect(controller.actionFeedback == scenario.shown)
        controller.close()
        try await ports.finish()
    }

    struct ReadCase: Sendable {
        let result: MarkReadResult
        let shown: String
    }
    @Test(arguments: [
        ReadCase(result: .done, shown: "Marked read"), .init(result: .alreadyRead, shown: "Already read"),
        .init(result: .notFound, shown: "Message not found"),
        .init(result: .unavailable(.databaseUnavailable), shown: "Mark read unavailable: database unavailable"),
    ])
    func everyMarkReadOutcomeIsVisible(scenario: ReadCase) async throws {
        let pane = PaneId.generateUUIDv7()
        let notice = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info)
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [notice]))
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        await ports.configureMarkRead(scenario.result)
        await controller.markRead(messageId: notice.id, source: pane)
        #expect(controller.actionFeedback == scenario.shown)
        controller.close()
        try await ports.finish()
    }

    struct ActionCase: Sendable {
        let result: MessageActionResult
        let shown: String
    }
    nonisolated static let actionCases: [ActionCase] = [
        .init(result: .openFile(.opened), shown: "File opened"), .init(result: .openFile(.shown), shown: "File shown"),
        .init(result: .openFile(.declined), shown: "File take-over declined"),
        .init(result: .openFile(.notFound), shown: "File not found"),
        .init(result: .openFile(.paneUnavailable), shown: "Pane unavailable"),
        .init(result: .openPullRequest(.opened), shown: "Pull request opened"),
        .init(result: .openPullRequest(.notFound), shown: "Pull request not found"),
        .init(result: .openPullRequest(.failed), shown: "Pull request open failed"),
        .init(result: .goToPane(.focused), shown: "Pane focused"),
        .init(result: .goToPane(.paneGone), shown: "Pane gone"),
        .init(result: .notFound, shown: "Message not found"),
        .init(result: .unavailable(.databaseUnavailable), shown: "Action unavailable: database unavailable"),
    ]
    @Test(arguments: actionCases)
    func everyMessageActionOutcomeIsVisible(scenario: ActionCase) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(
            try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1))
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        await ports.configureAction(scenario.result)
        let action: MessageAction
        switch scenario.result {
        case .openPullRequest:
            action = .openPullRequest(try .init(host: "github.com", owner: "org", repository: "repo", number: 7))
        case .goToPane: action = .goToPane(pane)
        case .openFile, .notFound, .unavailable: action = .openFile(path: "file.swift", line: 3)
        }
        await controller.runAction(messageId: id, source: pane, action: action)
        #expect(controller.actionFeedback == scenario.shown)
        #expect(await ports.actions == [.init(messageId: id, paneId: pane, action: action)])
        controller.close()
        try await ports.finish()
    }

    @Test
    func competingAnswersLeaveOneCommittedAnswerAndShowTheLosingRefusal() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(
            try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1),
            heldReads: [1])
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        await ports.configureAnswers([.answered, .refused(.alreadyAnswered)])
        await ports.setDetail(
            try PaneContextPopoverControllerTests.askDetail(
                pane: pane, id: id, state: .answered(by: .localUser, value: .text("First"), receipt: .notYetConfirmed),
                revision: 2))
        let first = Task { await controller.answer(messageId: id, source: pane, value: .text("First")) }
        try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
        await controller.answer(messageId: id, source: pane, value: .text("Second"))
        await ports.release(1)
        await first.value
        #expect(await ports.answers.count == 2)
        #expect(controller.actionFeedback == "Already answered")
        #expect(
            PaneContextPopoverControllerTests.firstRow(controller)?.shape
                == .ask(
                    reason: .question, form: .freeText(placeholder: "Reply"), waiting: .nonBlocking,
                    state: .answered(by: .localUser, value: .text("First"), receipt: .notYetConfirmed)))
        controller.close()
        try await ports.finish()
    }

    @Test
    func dismissingABlockingAskShowsHandedBackFromTheCommittedReread() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let message = AgentMessageDetail(
            id: id, sourcePaneId: pane,
            sender: .session(
                provider: try .init("codex"), sessionRef: try .init("session"), bindingGeneration: UUIDv7.generate()),
            sentAt: .distantPast, sourceOccurredAt: nil, importance: .attention, body: "Approval", why: nil,
            actions: [],
            shape: .ask(.approval, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .open))
        let initial = PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message])
        let ports = PaneContextPopoverTestPorts(initial)
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        let settled = AgentMessageDetail(
            id: id, sourcePaneId: pane, sender: message.sender, sentAt: message.sentAt,
            sourceOccurredAt: nil, importance: message.importance, body: message.body, why: nil, actions: [],
            shape: .ask(.approval, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .handedBack))
        await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [settled]))
        await controller.dismiss(messageId: id, source: pane)
        #expect(controller.actionFeedback == "Handed back")
        #expect(
            PaneContextPopoverControllerTests.firstRow(controller)?.shape
                == .ask(
                    reason: .approval, form: .freeText(placeholder: nil), waiting: .blocking(deadline: .distantFuture),
                    state: .handedBack))
        controller.close()
        try await ports.finish()
    }

    @Test
    func sidebarRejectsAskAnswerDismissAndMessageActions() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(
            try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1))
        let controller = makePopoverController(ports: ports, location: .sidebar)
        await controller.open(pane)
        await controller.answer(messageId: id, source: pane, value: .text("Yes"))
        await controller.dismiss(messageId: id, source: pane)
        await controller.runAction(messageId: id, source: pane, action: .goToPane(pane))
        #expect(await ports.answers.isEmpty)
        #expect(await ports.dismissals.isEmpty)
        #expect(await ports.actions.isEmpty)
        controller.close()
        try await ports.finish()
    }
}
