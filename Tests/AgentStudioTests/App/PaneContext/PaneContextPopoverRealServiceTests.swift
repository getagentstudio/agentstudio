import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Real service popover interactions", .serialized)
struct PaneContextPopoverRealServiceTests {
    @Test("a real drawer-only provider prompt reaches the main-pane Messages scope without an unread message")
    func drawerOnlyProviderPromptReachesOwner() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        do {
            let result = try await fixture.composition.ingestion.submitHook(
                .init(
                    paneId: fixture.drawerId.uuid, providerIdentifier: "codex", providerVersion: "9.9.9",
                    sessionId: "drawer-provider",
                    eventName: SessionProviderSignal.permission(toolName: "Bash", questions: nil).name,
                    turnId: "drawer-turn", signal: .permission(toolName: "Bash", questions: nil),
                    recordId: UUIDv7.generate(), admittedAt: fixture.now, chain: TestMainAgentChain.observation))
            guard case .committed = result else { throw PopoverServiceProofFailure.detailUnavailable }
            let source = try #require(
                try await fixture.composition.ingestion.sessionSummary(paneId: fixture.drawerId.uuid))
            #expect(source.providerPrompts.count == 1)
            let service = fixture.composition.paneContextService
            let controller = PaneContextPopoverController(
                reader: service, person: service, location: .pane,
                titleForPane: { $0 == fixture.drawerId ? "Review drawer" : "Owner" },
                refreshKeyForPane: { _ in .init(displayRevision: nil, sources: []) })
            defer { controller.close() }
            await controller.open(fixture.ownerId)
            let shaped = try #require(controller.state)
            let prompts = PaneContextPopoverShapingTests.prompts(shaped)
            #expect(prompts.count == 1)
            #expect(prompts.first?.reasonText == "Needs you · approval")
            #expect(prompts.first?.sourceLabel == "Review drawer")
            #expect(prompts.first?.sourcePaneId == fixture.drawerId.uuid)
            #expect(await service.readDisplay(paneId: fixture.ownerId)?.includingDrawers.kinds.unread == 0)
            controller.close()
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    @Test(
        "existing forms answer through the real controller and SQLite from either Messages location",
        arguments: ExistingPopoverForm.allCases, [PaneContextPopoverLocation.sidebar, .pane])
    func existingFormsAnswerFromEitherMessagesLocation(
        form: ExistingPopoverForm,
        location: PaneContextPopoverLocation
    ) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let id = AgentMessageId.generateUUIDv7()
            let requestedForm = try form.request()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: try fixture.sender(binding),
                        sourceOccurredAt: nil,
                        importance: .attention, body: "Answer this request", why: nil, actions: [],
                        shape: .ask(reason: .question, form: requestedForm, waiting: .nonBlocking))) == .created(id))
            let controller = PaneContextPopoverController(
                reader: service, person: service, location: location, titleForPane: { _ in "Source" },
                refreshKeyForPane: { _ in .init(displayRevision: nil, sources: []) })
            defer { controller.close() }
            await controller.open(fixture.ownerId)
            await controller.answerDraft(messageId: id, source: fixture.ownerId, draft: form.draft())
            let result = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            guard case .detail(let detail) = result else { throw PopoverServiceProofFailure.detailUnavailable }
            let stored = try #require(detail.messages.first { $0.id == id })
            #expect(
                stored.shape
                    == .ask(
                        .question, requestedForm, .nonBlocking,
                        .answered(by: .localUser, value: try form.expectedAnswer(), receipt: .notYetConfirmed)))
            let rendered = controller.state.map(PaneContextPopoverShapingTests.rows)?.first { $0.id == id.uuid }
            guard case .ask(_, _, _, let state)? = rendered?.shape else {
                throw PopoverServiceProofFailure.detailUnavailable
            }
            #expect(state == .answered(by: .localUser, value: form.expectedRenderAnswer(), receipt: .notYetConfirmed))
            controller.close()
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
}

enum ExistingPopoverForm: CaseIterable, Sendable {
    case singleChoice, multipleChoice, freeText, elicitation

    func request() throws -> AskForm {
        switch self {
        case .singleChoice, .multipleChoice:
            return .choice(
                options: [
                    .init(id: try .init("red"), label: "Red"), .init(id: try .init("blue"), label: "Blue"),
                ], allowsMultiple: self == .multipleChoice)
        case .freeText: return .freeText(placeholder: "Reply")
        case .elicitation:
            return .elicitation(
                .init(
                    properties: [
                        .init(
                            name: "project", title: "Project", description: nil,
                            type: .string(.init(choices: nil, minLength: nil, maxLength: nil, format: nil))),
                        .init(name: "enabled", title: "Enabled", description: nil, type: .boolean),
                        .init(
                            name: "workers", title: "Workers", description: nil,
                            type: .integer(.init(minimum: nil, maximum: nil))),
                    ], required: ["project", "enabled", "workers"]))
        }
    }

    func draft() -> AskFormDraft {
        var draft = AskFormDraft()
        switch self {
        case .singleChoice: draft.setChoice("blue", selected: true, allowsMultiple: false)
        case .multipleChoice:
            draft.setChoice("blue", selected: true, allowsMultiple: true)
            draft.setChoice("red", selected: true, allowsMultiple: true)
        case .freeText: draft.text = "A real response"
        case .elicitation:
            draft.fields = ["project": "staging", "workers": "2"]
            draft.booleans = ["enabled": true]
        }
        return draft
    }

    func expectedAnswer() throws -> AskAnswerValue {
        switch self {
        case .singleChoice: .choices([try .init("blue")])
        case .multipleChoice: .choices([try .init("blue"), try .init("red")])
        case .freeText: .text("A real response")
        case .elicitation:
            .form(
                .init(properties: [
                    "project": .string("staging"), "enabled": .boolean(true), "workers": .integer(2),
                ]))
        }
    }

    func expectedRenderAnswer() -> AskAnswerModel {
        switch self {
        case .singleChoice: .choices(["blue"])
        case .multipleChoice: .choices(["blue", "red"])
        case .freeText: .text("A real response")
        case .elicitation:
            .form([
                "project": .string("staging"), "enabled": .boolean(true), "workers": .integer(2),
            ])
        }
    }
}

private enum PopoverServiceProofFailure: Error { case detailUnavailable }
