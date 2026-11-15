import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Off-main popover person commands", .serialized)
struct PaneContextPopoverPersonCommandTests {
    @Test(
        "S4 person answers preserve the existing typed outcomes, local caller and feedback",
        arguments: PaneContextPersonOutcomeCases.answerCases)
    func answersKeepExistingOutcomeContract(scenario: PaneContextPersonOutcomeCases.AnswerCase) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let harness = PopoverOwnerHarness(detail: detail)
        do {
            let opening = try await harness.open()
            _ = try await harness.completed(opening.initialExecution)
            await harness.ports.configureAnswer(scenario.result)
            var draft = AskFormDraft()
            draft.text = "Yes"
            let result = await harness.owner.performPerson(
                .answer(.init(paneId: pane, messageId: id), draft), for: harness.key, opening: opening.epoch)
            #expect(result.resolution == .answer(scenario.result))
            #expect(result.presentation == .keepPopover)
            #expect(
                await harness.ports.answers == [.init(messageId: id, paneId: pane, by: .localUser, value: .text("Yes"))]
            )
            #expect(await harness.projections.requests.last?.actionFeedback == scenario.shown)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test(
        "S4 person dismissals preserve the existing typed outcomes and feedback",
        arguments: PaneContextPersonOutcomeCases.dismissCases)
    func dismissalsKeepExistingOutcomeContract(scenario: PaneContextPersonOutcomeCases.DismissCase)
        async throws
    {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let harness = PopoverOwnerHarness(detail: detail)
        do {
            let opening = try await harness.open()
            _ = try await harness.completed(opening.initialExecution)
            await harness.ports.configureDismiss(scenario.result)
            let result = await harness.owner.performPerson(
                .dismiss(.init(paneId: pane, messageId: id)), for: harness.key, opening: opening.epoch)
            #expect(result.resolution == .dismiss(scenario.result))
            #expect(await harness.ports.dismissals.count == 1)
            #expect(await harness.ports.dismissals.first?.0 == id)
            #expect(await harness.ports.dismissals.first?.1 == pane)
            #expect(await harness.projections.requests.last?.actionFeedback == scenario.shown)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test(
        "S4 admitted message actions retain typed results, feedback and D32 dismissal",
        arguments: PaneContextPersonOutcomeCases.actionCases)
    func actionsKeepExistingOutcomeAndDismissalContract(scenario: PaneContextPersonOutcomeCases.ActionCase)
        async throws
    {
        let pane = PaneId.generateUUIDv7()
        let row = try PaneContextPopoverShapingTests.message(paneId: pane, shape: .notice(.unread), importance: .info)
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [row]))
        do {
            let opening = try await harness.open()
            _ = try await harness.completed(opening.initialExecution)
            await harness.ports.configureAction(scenario.result)
            let model: MessageActionModel
            let core: MessageAction
            switch scenario.result {
            case .openPullRequest:
                model = .openPullRequest(.init(host: "github.com", owner: "org", repository: "repo", number: 7))
                core = .openPullRequest(try .init(host: "github.com", owner: "org", repository: "repo", number: 7))
            case .goToPane:
                model = .goToPane(pane.uuid)
                core = .goToPane(pane)
            case .openFile, .notFound, .unavailable:
                model = .openFile(path: "file.swift", line: 3)
                core = .openFile(path: "file.swift", line: 3)
            }
            let result = await harness.owner.performPerson(
                .runAction(.init(paneId: pane, messageId: row.id), model), for: harness.key, opening: opening.epoch)
            #expect(result.resolution == .action(scenario.result))
            #expect(result.presentation == (scenario.result == .goToPane(.focused) ? .dismissPopover : .keepPopover))
            #expect(await harness.ports.actions == [.init(messageId: row.id, paneId: pane, action: core)])
            #expect(await harness.projections.requests.last?.actionFeedback == scenario.shown)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }
}
