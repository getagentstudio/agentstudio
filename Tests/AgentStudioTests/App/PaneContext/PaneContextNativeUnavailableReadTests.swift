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
        var window: PaneContextNativePopoverWindow?
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
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = PaneContextNativePopoverWindow(
                paneId: fixture.ownerId, readers: readers, location: .card, wallNow: fixture.now,
                card: (.project(paneId: pane.id, store: store), store))
            window = mounted
            try await mounted.readCompleted()
            #expect((mounted.controller == nil) == cardInitiallyUnavailable)
            if !cardInitiallyUnavailable { #expect(mounted.controller?.location == .card) }
            try await mounted.renderedCard()
            #expect(mounted.labels().contains("1 unread ·"))
            let key = readers.refreshKey(for: fixture.ownerId)
            adapter = nil
            try mounted.press("pane-context.card-messages")
            try await mounted.readCompleted()
            mounted.layout()
            #expect(readers.refreshKey(for: fixture.ownerId) == key, "Unavailable service does not change facts")
            #expect(mounted.controller == nil, "Messages must retain its own nil completion")
            #expect(mounted.labels().contains("Not available right now"))
            let panel = try #require(mounted.find("pane-context.popover-panel") as? NSView)
            #expect(panel.bounds.width == 380)
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
