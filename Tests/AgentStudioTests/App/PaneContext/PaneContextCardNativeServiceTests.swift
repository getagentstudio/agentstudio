import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

/// Uses the service's real bounded-page operation; the exact read is unchanged.
struct PaneContextBudgetedTestReader: PaneContextDetailReading {
    let service: PaneContextService
    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        await service.readDetail(request, maximumDetailBytes: 0)
    }
    func readMessage(source: PaneId, message: AgentMessageId) async -> MessageReadResult {
        await service.readMessage(source: source, message: message)
    }
}

@MainActor
@Suite("Live native card requests", .serialized)
struct PaneContextCardNativeServiceTests {
    @Test(
        "G09/G13/G14/G17 the card submits its omitted oldest ask exactly once and removes settled controls",
        arguments: [ExistingPopoverForm.singleChoice, .multipleChoice, .freeText], [false, true])
    func omittedOldestAskUsesTheExactCardForm(form: ExistingPopoverForm, drawer: Bool) async throws {
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let owner = store.createPane(title: "Card owner")
        let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: owner.id))
        let service = fixture.composition.paneContextService
        _ = store.paneAtom.addDrawerPane(
            to: owner.id, content: owner.content, metadata: owner.metadata,
            childPaneId: fixture.drawerId.uuid, expandsDrawer: false)
        defer { store.removePane(owner.id) }
        var window: PaneContextPreparedNativeHost?
        do {
            let source = drawer ? fixture.drawerId : fixture.ownerId
            let binding = try await fixture.bind(paneId: source)
            let sender = try fixture.sender(binding)
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: source, messageId: id, sender: sender,
                        sourceOccurredAt: nil, importance: .attention, body: "The oldest selected request",
                        why: "Card proof",
                        actions: [], shape: .ask(reason: .question, form: try form.request(), waiting: .nonBlocking)))
                    == .created(id))
            for _ in 0..<16 {
                let later = AgentMessageId.generateUUIDv7()
                try #require(
                    await service.send(
                        .init(
                            paneId: source, messageId: later, sender: sender,
                            sourceOccurredAt: nil, importance: .attention, body: String(repeating: "x", count: 4096),
                            why: nil, actions: [],
                            shape: .ask(
                                reason: .question,
                                form: .freeText(placeholder: String(repeating: "p", count: 8000)), waiting: .nonBlocking
                            ))) == .created(later))
            }
            let reader = PaneContextBudgetedTestReader(service: service)
            guard case .detail(let first) = await reader.readDetail(.init(paneId: fixture.ownerId, page: .first)) else {
                Issue.record("Missing bounded page")
                return
            }
            #expect(!(first.messages + first.drawerMessages.flatMap(\.messages)).contains { $0.id == id })
            await fixture.composition.presentationLane.publishPending()
            #expect(
                fixture.presentationAtom.value(for: fixture.ownerId)?.includingDrawers.oldestOpenAsk
                    == .init(paneId: source, messageId: id))
            let person = PaneContextNativePersonRecorder(service)
            let adapter = PaneContextUIAdapter(reader: reader, person: person, invalidations: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = owners.makeNativeCardHost(
                context: .project(paneId: owner.id, store: store), wallNow: fixture.now)
            window = mounted
            try await mounted.open()
            #expect(mounted.cardValue?.selectedAsk?.key == .init(paneId: source, messageId: id))
            try await mounted.renderedCard()
            let scope = "\(source.uuid).\(id.uuid)"
            try fillAndSubmit(form, in: mounted, row: .init(sourcePaneId: source.uuid, messageId: id.uuid))
            try await mounted.actionCompleted()
            try await mounted.renderedCard()
            #expect(
                await person.answers == [
                    .init(
                        messageId: id, paneId: source,
                        by: .localUser, value: try form.expectedAnswer())
                ])
            for prefix in [
                "pane-context.choice.red", "pane-context.choice.blue", "pane-context.submit", "pane-context.dismiss",
            ] {
                #expect(mounted.native.find(prefix + "." + scope) == nil)
            }
            guard case .found(let settled) = await service.readMessage(source: source, message: id) else {
                Issue.record("Missing settled exact request")
                return
            }
            #expect(
                settled.shape
                    == .ask(
                        .question, try form.request(), .nonBlocking,
                        .answered(by: .localUser, value: try form.expectedAnswer(), receipt: .notYetConfirmed)))
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func fillAndSubmit(
        _ form: ExistingPopoverForm, in host: PaneContextPreparedNativeHost, row: MessageRowModel.Key
    )
        throws
    {
        let window = host.native
        let scope = row.controlScope
        switch form {
        case .singleChoice:
            try host.bindSingleChoice("blue", row: row)
            try window.press("pane-context.submit.\(scope)")
        case .multipleChoice:
            try window.press("pane-context.choice.blue.\(scope)")
            window.layout()
            try window.press("pane-context.choice.red.\(scope)")
            window.layout()
            try window.press("pane-context.submit.\(scope)")
        case .freeText:
            try window.typeText(placeholder: "Reply", value: "A real response")
            try window.press("pane-context.submit.\(scope)")
        case .elicitation: Issue.record("The card routes elicitation to Messages")
        }
    }
}
