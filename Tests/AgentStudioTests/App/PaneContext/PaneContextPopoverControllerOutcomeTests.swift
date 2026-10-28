import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Prepared person outcomes and committed rereads", .serialized)
struct PaneContextPopoverControllerOutcomeTests {
    @Test(arguments: PaneContextPersonOutcomeCases.answerCases)
    func everyAnswerOutcomeIsVisibleAndTheCallerIsLocal(scenario: PaneContextPersonOutcomeCases.AnswerCase) async throws
    {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(
            try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1))
        try await PaneContextPreparedDetailFixture.withOpen(pane: pane, ports: ports) { fixture, handle in
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
                try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: settled, revision: 2))
            var draft = AskFormDraft()
            draft.text = "Yes"
            _ = await fixture.bindings.performPerson(.answer(.init(paneId: pane, messageId: id), draft), handle: handle)
            #expect(handle.atom.value?.content.feedback == scenario.shown)
            #expect(await ports.answers == [.init(messageId: id, paneId: pane, by: .localUser, value: .text("Yes"))])
            try await fixture.refresh(handle)
            #expect(handle.atom.value?.content.feedback == scenario.shown)
        }
    }

    @Test(arguments: PaneContextPersonOutcomeCases.dismissCases)
    func everyDismissOutcomeIsVisible(scenario: PaneContextPersonOutcomeCases.DismissCase) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(
            try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1))
        try await PaneContextPreparedDetailFixture.withOpen(pane: pane, ports: ports) { fixture, handle in
            await ports.configureDismiss(scenario.result)
            _ = await fixture.bindings.performPerson(.dismiss(.init(paneId: pane, messageId: id)), handle: handle)
            #expect(handle.atom.value?.content.feedback == scenario.shown)
        }
    }

    @Test(arguments: PaneContextPersonOutcomeCases.actionCases)
    func everyMessageActionOutcomeIsVisible(scenario: PaneContextPersonOutcomeCases.ActionCase) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let notice = AgentMessageDetail(
            id: id, sourcePaneId: pane, sender: .pane(pane), sentAt: .distantPast,
            sourceOccurredAt: nil, importance: .info, body: "Notice", why: nil, actions: [], shape: .notice(.unread))
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [notice]))
        try await PaneContextPreparedDetailFixture.withOpen(pane: pane, ports: ports) { fixture, handle in
            await ports.configureAction(scenario.result)
            let action: MessageAction
            let presentation: MessageActionModel
            switch scenario.result {
            case .openPullRequest:
                action = .openPullRequest(try .init(host: "github.com", owner: "org", repository: "repo", number: 7))
                presentation = .openPullRequest(.init(host: "github.com", owner: "org", repository: "repo", number: 7))
            case .goToPane:
                action = .goToPane(pane)
                presentation = .goToPane(pane.uuid)
            case .openFile, .notFound, .unavailable:
                action = .openFile(path: "file.swift", line: 3)
                presentation = .openFile(path: "file.swift", line: 3)
            }
            _ = await fixture.bindings.performPerson(
                .runAction(.init(paneId: pane, messageId: id), presentation), handle: handle)
            #expect(handle.atom.value?.content.feedback == scenario.shown)
            #expect(await ports.actions == [.init(messageId: id, paneId: pane, action: action)])
        }
    }

    @Test
    func competingAnswersLeaveOneCommittedAnswerAndShowTheLosingRefusal() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let ports = PaneContextPopoverTestPorts(
            try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1), heldReads: [1])
        try await PaneContextPreparedDetailFixture.withOpen(pane: pane, ports: ports) { fixture, handle in
            await ports.configureAnswers([.answered, .refused(.alreadyAnswered)])
            await ports.setDetail(
                try PaneContextMessageFixtures.askDetail(
                    pane: pane, id: id,
                    state: .answered(by: .localUser, value: .text("First"), receipt: .notYetConfirmed), revision: 2))
            var firstDraft = AskFormDraft()
            firstDraft.text = "First"
            let first = Task { await fixture.bindings.performPerson(.answer(target, firstDraft), handle: handle) }
            let firstMonitor = Task {
                _ = await first.value
                await ports.detailProducerEnded(beforeRead: 1)
            }
            var second: Task<PaneContextPopoverPersonCompletion, Never>?
            var secondMonitor: Task<Void, Never>?
            do {
                try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
                var secondDraft = AskFormDraft()
                secondDraft.text = "Second"
                let producer = Task {
                    await fixture.bindings.performPerson(.answer(target, secondDraft), handle: handle)
                }
                second = producer
                secondMonitor = Task {
                    _ = await producer.value
                    await ports.answerProducerEnded(beforeAnswer: 1)
                }
                try await ports.answerFacts.expectNext(
                    in: 1,
                    .recorded(
                        .init(
                            messageId: id, paneId: pane,
                            by: .localUser, value: .text("Second"))))
                await ports.release(1)
                _ = await first.value
                _ = await producer.value
                await firstMonitor.value
                await secondMonitor?.value
                #expect(await ports.answers.count == 2)
                #expect(handle.atom.value?.content.feedback == "Already answered")
                #expect(
                    handle.atom.value?.shape?.messages.messageRows.first?.shape
                        == .ask(
                            reason: .question,
                            form: .freeText(placeholder: "Reply"), waiting: .nonBlocking,
                            state: .answered(by: .localUser, value: .text("First"), receipt: .notYetConfirmed)))
            } catch {
                await ports.release(1)
                first.cancel()
                second?.cancel()
                _ = await first.value
                _ = await second?.value
                await firstMonitor.value
                await secondMonitor?.value
                throw error
            }
        }
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
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
        try await PaneContextPreparedDetailFixture.withOpen(pane: pane, ports: ports) { fixture, handle in
            let settled = AgentMessageDetail(
                id: id, sourcePaneId: pane, sender: message.sender, sentAt: message.sentAt,
                sourceOccurredAt: nil, importance: message.importance, body: message.body, why: nil, actions: [],
                shape: .ask(.approval, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .handedBack))
            await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [settled]))
            _ = await fixture.bindings.performPerson(.dismiss(.init(paneId: pane, messageId: id)), handle: handle)
            #expect(handle.atom.value?.content.feedback == "Handed back")
            #expect(
                handle.atom.value?.shape?.messages.messageRows.first?.shape
                    == .ask(
                        reason: .approval,
                        form: .freeText(placeholder: nil), waiting: .blocking(deadline: .distantFuture),
                        state: .handedBack))
        }
    }

    @Test
    func sidebarPermitsAskAnswerAndDismissButAsksHaveNoNoticeActions() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let ports = PaneContextPopoverTestPorts(
            try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1))
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, location: .sidebar
        ) { fixture, handle in
            var draft = AskFormDraft()
            draft.text = "Yes"
            _ = await fixture.bindings.performPerson(.answer(target, draft), handle: handle)
            _ = await fixture.bindings.performPerson(.dismiss(target), handle: handle)
            _ = await fixture.bindings.performPerson(.runAction(target, .goToPane(pane.uuid)), handle: handle)
            #expect(await ports.answers == [.init(messageId: id, paneId: pane, by: .localUser, value: .text("Yes"))])
            #expect(await ports.dismissals.count == 1)
            #expect(await ports.actions.isEmpty)
        }
    }
}
