import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

actor PaneContextCardFailureReader: PaneContextDetailReading {
    let service: PaneContextService
    private var failing = false
    private let boundedPage: Bool
    init(_ service: PaneContextService, boundedPage: Bool) {
        self.service = service
        self.boundedPage = boundedPage
    }
    func failExactRead() { failing = true }
    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        if boundedPage { return await service.readDetail(request, maximumDetailBytes: 0) }
        return await service.readDetail(request)
    }
    func readMessage(source: PaneId, message: AgentMessageId) async -> MessageReadResult {
        if failing { return .unavailable(.databaseUnavailable) }
        return await service.readMessage(source: source, message: message)
    }
}

@MainActor
struct PaneContextCardServiceHost {
    let fixture: CompositionFactoryFixture
    let store: WorkspaceStore
    let status: SessionStatusAtom
    let binding: SessionsBindingRecord
    let sender: AgentMessageSender
    let id: AgentMessageId
    let reader: PaneContextCardFailureReader
    let person: PaneContextNativePersonRecorder
    let window: PaneContextNativePopoverWindow

    static func make(
        form: AskForm, blocking: Bool = false, independentPrompt: Bool = false,
        omittedTarget: Bool = false
    ) async throws -> Self {
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let owner = store.createPane(title: "Card lifecycle")
        let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: owner.id))
        do {
            try #require(
                store.paneAtom.addDrawerPane(
                    to: owner.id, content: owner.content, metadata: owner.metadata,
                    childPaneId: fixture.drawerId.uuid, expandsDrawer: false) != nil)
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let sender = try fixture.sender(binding)
            let id = AgentMessageId.generateUUIDv7()
            let waiting: AskWaiting = blocking ? .blocking(deadline: fixture.now.addingTimeInterval(600)) : .nonBlocking
            let service = fixture.composition.paneContextService
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender,
                        sourceOccurredAt: nil, importance: .attention, body: "The card's request",
                        why: "Full explanation",
                        actions: [], shape: .ask(reason: .question, form: form, waiting: waiting))) == .created(id))
            if omittedTarget {
                for _ in 0..<16 {
                    let later = AgentMessageId.generateUUIDv7()
                    try #require(
                        await service.send(
                            .init(
                                paneId: fixture.ownerId, messageId: later, sender: sender,
                                sourceOccurredAt: nil, importance: .attention,
                                body: String(repeating: "x", count: 4096), why: nil,
                                actions: [],
                                shape: .ask(
                                    reason: .question,
                                    form: .freeText(placeholder: String(repeating: "p", count: 8000)),
                                    waiting: .nonBlocking))) == .created(later))
                }
            }
            if independentPrompt {
                let result = try await fixture.composition.ingestion.submitHook(
                    .init(
                        paneId: fixture.drawerId.uuid,
                        providerIdentifier: "codex", providerVersion: "9.9.9", sessionId: "independent-card-prompt",
                        eventName: SessionProviderSignal.permission(toolName: "Bash", questions: nil).name, turnId: nil,
                        signal: .permission(toolName: "Bash", questions: nil), recordId: UUIDv7.generate(),
                        admittedAt: fixture.now, chain: TestMainAgentChain.observation))
                guard case .committed = result else { throw CardServiceHostFailure.hookNotCommitted }
            }
            let status = SessionStatusAtom()
            let mailbox = await fixture.composition.ingestion.statusPublicationMailbox
            status.apply(mailbox.takeBatch())
            await fixture.composition.presentationLane.publishPending()
            let reader = PaneContextCardFailureReader(service, boundedPage: omittedTarget)
            let person = PaneContextNativePersonRecorder(service)
            let adapter = PaneContextUIAdapter(reader: reader, person: person)
            let readers = PaneContextUIReaders(
                sessionStatus: status, presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let window = PaneContextNativePopoverWindow(
                paneId: fixture.ownerId, readers: readers, location: .card,
                wallNow: fixture.now, card: (.project(paneId: owner.id, store: store), store))
            return .init(
                fixture: fixture, store: store, status: status, binding: binding, sender: sender,
                id: id, reader: reader, person: person, window: window)
        } catch {
            try? await fixture.close()
            store.removePane(owner.id)
            throw error
        }
    }

    var scope: String { "\(fixture.ownerId.uuid).\(id.uuid)" }
    func open() async throws {
        try await window.readCompleted()
        #expect(window.controller?.selectedAsk?.key == .init(paneId: fixture.ownerId, messageId: id))
        try await window.renderedCard()
    }
    func expectSettledControlsAbsent() {
        #expect(window.editableFields.isEmpty)
        for prefix in [
            "pane-context.choice.red", "pane-context.choice.blue", "pane-context.submit", "pane-context.dismiss",
        ] {
            #expect(window.find(prefix + "." + scope) == nil)
        }
    }
    func close() async throws {
        try await window.close()
        try await fixture.close()
        store.removePane(fixture.ownerId.uuid)
    }
}
private enum CardServiceHostFailure: Error { case hookNotCommitted }
