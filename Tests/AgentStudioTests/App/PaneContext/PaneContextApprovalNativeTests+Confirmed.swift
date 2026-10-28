import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

extension PaneContextApprovalNativeTests {
    @Test(
        "F02 a receipt-confirmed approval renders its full stored answer in Resolved", arguments: [true, false],
        [true, false])
    func confirmedDecisionKeepsItsReason(approve: Bool, hasReason: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var window: PaneContextPreparedNativeHost?
        do {
            let service = fixture.composition.paneContextService
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let sender = try fixture.sender(binding)
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                        importance: .attention, body: "A reviewed migration", why: nil, actions: [],
                        shape: .ask(reason: .approval, form: .approval, waiting: .nonBlocking))) == .created(id))
            let reason = hasReason ? "Reviewed the migration" : nil
            let value = AskAnswerValue.decision(approve ? .approve : .deny, reason: reason)
            #expect(
                await service.answer(.init(messageId: id, paneId: fixture.ownerId, by: .localUser, value: value))
                    == .answered)
            guard
                case .page(let pending) = await service.changes(
                    .init(paneId: fixture.ownerId, writer: sender, after: .init(0))),
                case .page(let confirmed) = await service.changes(
                    .init(paneId: fixture.ownerId, writer: sender, after: pending.nextPosition))
            else { throw ConfirmedApprovalFailure.missingReceipt }
            #expect(pending.entries.map(\.kind) == [.answer(value)])
            #expect(confirmed.entries.isEmpty)
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(paneId: fixture.ownerId, wallNow: fixture.now)
            window = mounted
            try await mounted.open()
            try await mounted.rendered()
            let expected =
                (approve ? "Answered: Approved" : "Answered: Denied")
                + (hasReason ? " · Reviewed the migration" : "")
            #expect(mounted.native.labels().contains("Resolved"))
            #expect(mounted.native.labels().contains(expected))
            let row = mounted.value?.shape?.messages.groups.first { $0.kind == .resolved }?.items.first
            guard case .message(let message) = row else { throw ConfirmedApprovalFailure.missingRow }
            #expect(message.settledLabel == expected)
            #expect(message.availability == .none)
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }
}

private enum ConfirmedApprovalFailure: Error { case missingReceipt, missingRow }
