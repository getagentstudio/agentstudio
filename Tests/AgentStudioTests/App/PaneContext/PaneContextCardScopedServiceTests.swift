import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Scoped exact card service", .serialized)
struct PaneContextCardScopedServiceTests {
    @Test("G09/G17 real scope ties, two drawers, unrelated pane and colliding message identities")
    func scopedOldestSelectionAndAnswersKeepCompositeIdentity() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        let secondDrawer = PaneId.generateUUIDv7()
        let unrelated = PaneId.generateUUIDv7()
        fixture.directory.install(
            .init(
                workspaceId: fixture.workspaceId, membershipRevision: 2,
                entries: [
                    .init(
                        paneId: fixture.ownerId, placement: .layout,
                        ownedDrawerChildIds: [fixture.drawerId, secondDrawer]),
                    .init(
                        paneId: fixture.drawerId, placement: .drawerChild(parentPaneID: fixture.ownerId.uuid),
                        ownedDrawerChildIds: []),
                    .init(
                        paneId: secondDrawer, placement: .drawerChild(parentPaneID: fixture.ownerId.uuid),
                        ownedDrawerChildIds: []),
                    .init(paneId: unrelated, placement: .layout, ownedDrawerChildIds: []),
                ]))
        let controller = PaneContextPopoverController(
            reader: service, person: service, location: .card,
            titleForPane: { _ in nil }, refreshKeyForPane: { _ in .init(displayRevision: nil, sources: []) })
        do {
            let id = AgentMessageId.generateUUIDv7()
            // Drawer arrives first; receive-time ties still prefer the main pane.
            for source in [unrelated, secondDrawer, fixture.drawerId, fixture.ownerId] {
                let binding = try await fixture.bind(paneId: source)
                let form: AskForm =
                    source == fixture.ownerId
                    ? try ExistingPopoverForm.singleChoice.request() : .freeText(placeholder: "Drawer reply")
                try #require(
                    await service.send(
                        .init(
                            paneId: source, messageId: id, sender: try fixture.sender(binding),
                            sourceOccurredAt: nil, importance: .attention, body: "Scoped question", why: nil,
                            actions: [],
                            shape: .ask(reason: .question, form: form, waiting: .nonBlocking))) == .created(id))
            }
            let ownerDisplay = try #require(await service.readDisplay(paneId: fixture.ownerId))
            #expect(ownerDisplay.includingDrawers.kinds.needsYou == 3)
            let ownerKey = try #require(ownerDisplay.includingDrawers.oldestOpenAsk)
            #expect(ownerKey == .init(paneId: fixture.ownerId, messageId: id))
            await controller.openCard(
                fixture.ownerId, selection: .ask(source: ownerKey.paneId, message: ownerKey.messageId))
            #expect(controller.selectedAsk?.key == ownerKey)
            await controller.answerDraft(
                messageId: id, source: fixture.ownerId, draft: ExistingPopoverForm.singleChoice.draft())
            guard case .found(let own) = await service.readMessage(source: fixture.ownerId, message: id) else {
                throw ScopedCardServiceFailure.missingMessage
            }
            #expect(
                own.shape
                    == .ask(
                        .question, try ExistingPopoverForm.singleChoice.request(), .nonBlocking,
                        .answered(by: .localUser, value: .choices([try .init("blue")]), receipt: .notYetConfirmed)))
            #expect(
                await service.readDisplay(paneId: fixture.ownerId)?.includingDrawers.oldestOpenAsk
                    == .init(paneId: fixture.drawerId, messageId: id))
            let drawerDisplay = try #require(await service.readDisplay(paneId: fixture.drawerId))
            #expect(drawerDisplay.own == drawerDisplay.includingDrawers)
            #expect(drawerDisplay.own.kinds.needsYou == 1)
            await controller.openCard(fixture.drawerId, selection: .ask(source: fixture.drawerId, message: id))
            var draft = AskFormDraft()
            draft.text = "Only this drawer"
            await controller.answerDraft(messageId: id, source: fixture.drawerId, draft: draft)
            for source in [secondDrawer, unrelated] {
                guard case .found(let untouched) = await service.readMessage(source: source, message: id) else {
                    throw ScopedCardServiceFailure.missingMessage
                }
                #expect(untouched.shape == .ask(.question, .freeText(placeholder: "Drawer reply"), .nonBlocking, .open))
            }
            guard case .found(let answeredDrawer) = await service.readMessage(source: fixture.drawerId, message: id)
            else {
                throw ScopedCardServiceFailure.missingMessage
            }
            #expect(
                answeredDrawer.shape
                    == .ask(
                        .question, .freeText(placeholder: "Drawer reply"), .nonBlocking,
                        .answered(by: .localUser, value: .text("Only this drawer"), receipt: .notYetConfirmed)))
            controller.close()
            try await fixture.close()
        } catch {
            controller.close()
            try? await fixture.close()
            throw error
        }
    }
}
private enum ScopedCardServiceFailure: Error { case missingMessage }
