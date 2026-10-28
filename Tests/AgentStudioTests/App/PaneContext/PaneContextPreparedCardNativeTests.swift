import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Prepared native card composition", .serialized)
struct PaneContextPreparedCardNativeTests {
    @Test("S4 the real card and its Show messages control expose distinct prepared consumers and actual native content")
    func cardAndNestedMessagesUseTheirActualProducers() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Prepared card owner")
            defer { store.removePane(pane.id) }
            let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: pane.id))
            let service = fixture.composition.paneContextService
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let ingestion = fixture.composition.ingestion
            let adapter = PaneContextUIAdapter(
                service: service,
                readLiveSession: { pane in
                    guard let result = try? await ingestion.readSessionStatus(paneId: pane.uuid),
                        case .live(let value) = result
                    else { return nil }
                    return value
                })
            let status = SessionStatusAtom()
            let sources = PaneContextTestSourceOwners(
                sessionStatus: status, presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let bindings = sources.bindings(clock: clock, wallNow: { time.now }, observe: bridge.observe)
            var native: PaneContextNativePopoverWindow?
            let sink = CardConsumerRecorder()
            do {
                let seed = try await createCardMessages(fixture)
                let ask = seed.ask
                let readers = PaneContextUIReaders(
                    sessionStatus: status, presentation: fixture.presentationAtom,
                    pane: sources.pane, popoverBindings: bindings)
                let root = PaneContextPreparedManagementOverlay(
                    context: .project(paneId: pane.id, store: store),
                    octiconLoader: makeTestOcticonLoader(), readers: readers, bindings: bindings, onGoToPane: { _ in },
                    onRenderingTaskStarted: { sink.tasks.append($0) }, onConsumerStarted: { sink.started($0) },
                    onApplication: { sink.observe($0) })
                let window = PaneContextNativePopoverWindow(
                    preparedRoot: AnyView(root), viewportWidth: 640, isCard: true)
                native = window
                try #require(sink.tasks.count == 1, "Mounted card did not announce its actual rendering producer")
                await sink.tasks[0].value
                let card = try #require(sink.card)
                try verifyProducer(card, bridge: bridge)
                forceNativeHostUpdate(window.window)
                let value = try #require(card.atom.value)
                try #require(
                    sink.applied[value.publication.id] != nil, "The exact card value did not reach native application")
                #expect(value.selectedAsk?.key == .init(paneId: fixture.ownerId, messageId: ask))
                #expect(value.liveSession?.sessionRef.value == seed.sessionReference)
                let scope = "\(fixture.ownerId.uuid).\(ask.uuid)"
                #expect(window.find("pane-context.submit." + scope) != nil)
                #expect(window.labels().contains { $0.contains("A real card question") })
                try window.press("pane-context.card-messages")
                try #require(sink.tasks.count == 2, "Show messages did not announce its own rendering producer")
                await sink.tasks[1].value
                let messages = try #require(sink.messages)
                try verifyProducer(messages, bridge: bridge)
                forceNativeHostUpdate(try #require(window.popoverWindow))
                let shown = try #require(messages.atom.value)
                try #require(
                    sink.applied[shown.publication.id] != nil,
                    "The exact Messages value did not reach native application")
                #expect(card.key != messages.key)
                #expect(card.atom !== messages.atom)
                #expect(
                    shown.shape?.messages.messageRows.map(\.body) == ["A real card question", "A real Messages notice"])
                #expect(window.labels().contains { $0.contains("A real Messages notice") })
                try await window.close()
                native = nil
                await bindings.stop()
                for task in sink.tasks {
                    task.cancel()
                    await task.value
                }
                #expect(clock.pendingSleepCount == 0)
                bridge.facts.receive(.ended)
                try await bridge.facts.finish()
                try await fixture.close()
            } catch {
                try? await native?.close()
                await bindings.stop()
                for task in sink.tasks {
                    task.cancel()
                    await task.value
                }
                bridge.facts.receive(.ended)
                try? await bridge.facts.finish()
                try? await fixture.close()
                throw error
            }
        }
    }

    private func createCardMessages(_ fixture: CompositionFactoryFixture) async throws
        -> (ask: AgentMessageId, sessionReference: String)
    {
        let service = fixture.composition.paneContextService
        let binding = try await fixture.bind(paneId: fixture.ownerId)
        let ask = AgentMessageId.generateUUIDv7()
        let notice = AgentMessageId.generateUUIDv7()
        try #require(
            await service.send(
                .init(
                    paneId: fixture.ownerId, messageId: ask,
                    sender: try fixture.sender(binding), sourceOccurredAt: nil, importance: .attention,
                    body: "A real card question", why: nil, actions: [],
                    shape: .ask(reason: .question, form: .freeText(placeholder: "Reply"), waiting: .nonBlocking)))
                == .created(ask))
        try #require(
            await service.send(
                .init(
                    paneId: fixture.ownerId, messageId: notice,
                    sender: .pane(fixture.ownerId), sourceOccurredAt: nil, importance: .info,
                    body: "A real Messages notice", why: nil, actions: [], shape: .notice)) == .created(notice))
        await fixture.composition.presentationLane.publishPending()
        return (ask, binding.providerConversationId)
    }

    private func verifyProducer(_ handle: PaneContextPopoverConsumerHandle, bridge: PopoverOwnerFactBridge) throws {
        try #require(
            bridge.didFinish(.execution(handle.key, handle.opening.initialExecution.id)),
            "The rendering producer ended without its exact owner terminal fact")
    }
    private func forceNativeHostUpdate(_ window: NSWindow) {
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    private final class CardConsumerRecorder {
        var tasks: [Task<Void, Never>] = []
        var card: PaneContextPopoverConsumerHandle?
        var messages: PaneContextPopoverConsumerHandle?
        var applied: [UUID: PaneContextPopoverApplication] = [:]
        func started(_ handle: PaneContextPopoverConsumerHandle) {
            if handle.key.surface == .managementCard { card = handle } else { messages = handle }
        }
        func observe(_ event: PaneContextPopoverApplicationEvent) {
            if case .applied(let value) = event { applied[value.publication.id] = value }
        }
    }
}
