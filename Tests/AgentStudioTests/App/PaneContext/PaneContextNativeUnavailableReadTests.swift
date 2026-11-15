import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Native unavailable read attribution", .serialized)
struct PaneContextNativeUnavailableReadTests {
    @Test(
        "F04 standalone card and nested Messages keep their nil completion with its producer",
        arguments: [false, true])
    func unavailableReadsRetainTheirOrigin(cardInitiallyUnavailable: Bool) async throws {
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let pane = store.createPane(title: "Unavailable read owner")
        defer { store.removePane(pane.id) }
        let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: pane.id))
        var window: PaneContextPreparedNativeHost?
        do {
            let service = fixture.composition.paneContextService
            let message = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: message, sender: .pane(fixture.ownerId),
                        sourceOccurredAt: nil, importance: .failure, body: "A real unread notice", why: nil,
                        actions: [], shape: .notice)) == .created(message))
            await fixture.composition.presentationLane.publishPending()
            var adapter: PaneContextUIAdapter? = cardInitiallyUnavailable ? nil : .init(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = owners.makeNativeCardHost(
                context: .project(paneId: pane.id, store: store), wallNow: fixture.now)
            window = mounted
            try await mounted.open()
            let cardValue = try #require(mounted.cardValue)
            try #require(cardValue.card != nil, "The actual card producer must publish its own prepared card")
            #expect(
                (cardValue.content.feedback == "Not available right now") == cardInitiallyUnavailable,
                "The card's own service-unavailable feedback must match its opening")
            if !cardInitiallyUnavailable { #expect(mounted.handle?.key.surface == .managementCard) }
            try await mounted.renderedCard()
            #expect(mounted.native.labels().contains("1 unread ·"))
            let canonicalDisplay = fixture.presentationAtom.value(for: fixture.ownerId)
            adapter = nil
            let messages = try mounted.beginOpening()
            try await mounted.completeOpening(messages)
            mounted.native.layout()
            try await mounted.renderedNote("Not available right now")
            #expect(
                fixture.presentationAtom.value(for: fixture.ownerId) == canonicalDisplay,
                "Unavailable service does not change facts")
            #expect(mounted.value?.shape == nil, "Messages must retain its own unavailable value and producer")
            #expect(mounted.native.labels().contains("Not available right now"))
            let panel = try #require(mounted.native.find("pane-context.popover-panel") as? NSView)
            #expect(panel.bounds.width == 480)
            try await mounted.close()
            #expect(mounted.clock.pendingSleepCount == 0)
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }
}
