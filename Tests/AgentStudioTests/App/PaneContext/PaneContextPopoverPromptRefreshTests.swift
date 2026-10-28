import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Open Messages prompt invalidation", .serialized)
struct PaneContextPopoverPromptRefreshTests {
    @Test("G18 a continuously open real host observes second prompts, omissions, drawers and the last prompt closing")
    func promptOnlyChangesReachTheOpenHost() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let host = try await PromptRefreshHost.make(atoms: atoms)
            do {
                try await host.window.open()
                try await host.window.rendered()
                let before = try #require(host.status.value(for: host.fixture.ownerId))
                let display = host.fixture.presentationAtom.value(for: host.fixture.ownerId)?.revision
                #expect(host.prompts.map(\.summary) == ["First prompt", "Second prompt"])
                try await host.submit(.elicitation(id: "b", summary: "Changed second prompt"))
                try await host.applyPublicationAndRender()
                #expect(host.status.value(for: host.fixture.ownerId)?.compactPrompt == before.compactPrompt)
                #expect(host.fixture.presentationAtom.value(for: host.fixture.ownerId)?.revision == display)
                #expect(host.prompts.map(\.summary) == ["First prompt", "Changed second prompt"])
                #expect(host.window.native.labels().contains("Needs you · question: Changed second prompt Now"))

                for index in 2..<16 { try await host.submit(.elicitation(id: "\(index)", summary: "Prompt \(index)")) }
                try await host.applyPublicationAndRender()
                let listed = host.prompts
                try await host.submit(.elicitation(id: "omitted", summary: "An omitted prompt"))
                try await host.applyPublicationAndRender()
                #expect(host.prompts == listed)
                #expect(host.window.value?.shape?.messages.groups.first?.omittedPromptCount == 1)
                #expect(host.window.native.labels().contains("+1 more not shown"))
                #expect(host.fixture.presentationAtom.value(for: host.fixture.ownerId)?.revision == display)

                try await host.submit(.elicitation(id: "drawer", summary: "Drawer prompt"), pane: host.fixture.drawerId)
                try await host.applyPublicationAndRender()
                #expect(host.prompts.last?.sourcePaneId == host.fixture.drawerId.uuid)
                #expect(host.prompts.last?.summary == "Drawer prompt")
                #expect(host.window.native.labels().contains("Needs you · question: Drawer prompt Now"))
                let member = try await host.addMember()
                try await host.submit(.elicitation(id: "new-member", summary: "New member prompt"), pane: member)
                try await host.applyPublicationAndRender()
                #expect(host.prompts.last?.sourcePaneId == member.uuid)
                #expect(host.window.native.labels().contains("Needs you · question: New member prompt Now"))
                try await host.submit(.elicitationResult(id: "new-member"), pane: member)
                try await host.applyPublicationAndRender()
                #expect(!host.window.native.labels().contains("Needs you · question: New member prompt Now"))

                for id in ["a", "b", "omitted"] + (2..<16).map(String.init) {
                    try await host.submit(.elicitationResult(id: id))
                }
                try await host.applyPublicationAndRender()
                #expect(host.prompts.map(\.summary) == ["Drawer prompt"])
                try await host.submit(.elicitationResult(id: "drawer"), pane: host.fixture.drawerId)
                try await host.applyPublicationAndRender()
                #expect(host.prompts.isEmpty)
                #expect(host.window.value?.shape?.messages.groups.isEmpty == true)
                #expect(!host.window.native.labels().contains("Needs you · question: Drawer prompt Now"))
                #expect(host.window.native.find("pane-context.dismiss-all-notices") == nil)
                try await host.close()
            } catch {
                try? await host.close()
                throw error
            }
        }
    }
}

@MainActor
final class PromptRefreshHost {
    let fixture: CompositionFactoryFixture
    let store: WorkspaceStore
    let status: SessionStatusAtom
    let window: PaneContextPreparedNativeHost
    let cardMode: Bool

    var prompts: [ProviderPromptRowModel] {
        window.handle?.atom.latestAcceptedValue?.shape.map(PaneContextPopoverShapingTests.prompts) ?? []
    }

    private init(
        fixture: CompositionFactoryFixture, store: WorkspaceStore, status: SessionStatusAtom,
        window: PaneContextPreparedNativeHost, cardMode: Bool
    ) {
        self.fixture = fixture
        self.store = store
        self.status = status
        self.window = window
        self.cardMode = cardMode
    }

    static func make(atoms: CoreAtoms, cardMode: Bool = false) async throws -> PromptRefreshHost {
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let owner = store.createPane(title: "Owner")
        let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: owner.id))
        do {
            try #require(
                store.paneAtom.addDrawerPane(
                    to: owner.id, content: owner.content, metadata: owner.metadata,
                    childPaneId: fixture.drawerId.uuid, expandsDrawer: false) != nil)
            let status = SessionStatusAtom()
            let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: status, presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            for signal in [
                SessionProviderSignal.turnStart, .elicitation(id: "a", summary: "First prompt"),
                .elicitation(id: "b", summary: "Second prompt"),
            ] {
                try await submit(signal, pane: fixture.ownerId, fixture: fixture)
            }
            let mailbox = await fixture.composition.ingestion.statusPublicationMailbox
            status.apply(mailbox.takeBatch())
            await fixture.composition.presentationLane.publishPending()
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let window: PaneContextPreparedNativeHost
            // Monotonic time drives admission; wall time is deliberately frozen for this prompt-only subject.
            let now = fixture.now
            if cardMode {
                window = .init(
                    context: .project(paneId: owner.id, store: store), sourceOwners: owners,
                    clock: clock, wallNow: { now }, bridge: bridge)
            } else {
                window = .init(
                    paneId: fixture.ownerId, sourceOwners: owners,
                    entry: .kind(.init(kind: .needsYou, count: 1)), clock: clock,
                    wallNow: { now }, bridge: bridge, location: .sidebar)
            }
            return .init(fixture: fixture, store: store, status: status, window: window, cardMode: cardMode)
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    func submit(_ signal: SessionProviderSignal, pane: PaneId? = nil) async throws {
        try await Self.submit(signal, pane: pane ?? fixture.ownerId, fixture: fixture)
    }

    private static func submit(_ signal: SessionProviderSignal, pane: PaneId, fixture: CompositionFactoryFixture)
        async throws
    {
        let result = try await fixture.composition.ingestion.submitHook(
            .init(
                paneId: pane.uuid,
                providerIdentifier: "codex", providerVersion: "9.9.9", sessionId: "prompt-\(pane.uuid)",
                eventName: signal.name, turnId: "prompt-turn", signal: signal, recordId: UUIDv7.generate(),
                admittedAt: fixture.now, chain: TestMainAgentChain.observation))
        guard case .committed = result else {
            Issue.record("Hook did not commit: \(result)")
            throw PromptRefreshProofFailure.hookNotCommitted
        }
    }

    func applyPublicationAndRender() async throws {
        let handle = try #require(window.handle)
        let mailbox = await fixture.composition.ingestion.statusPublicationMailbox
        let batch = mailbox.takeBatch()
        try #require(!batch.isEmpty, "The real Sessions owner must publish the prompt change")
        status.apply(batch)
        let forwarding = window.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
        try await window.canonicalChangeCompleted(forwarding)
        if cardMode { try await window.renderedCard() } else { try await window.rendered() }
    }

    func addMember() async throws -> PaneId {
        let owner = try #require(store.paneAtom.pane(fixture.ownerId.uuid))
        let handle = try #require(window.handle)
        let added = try #require(
            store.paneAtom.addDrawerPane(
                to: owner.id, content: owner.content,
                metadata: owner.metadata, expandsDrawer: false))
        let addedId = PaneId(existingUUID: added.id)
        let forwarding = window.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
        fixture.directory.install(
            .init(
                workspaceId: fixture.workspaceId, membershipRevision: 2,
                entries: [
                    .init(
                        paneId: fixture.ownerId, placement: .layout, ownedDrawerChildIds: [fixture.drawerId, addedId]),
                    .init(
                        paneId: fixture.drawerId, placement: .drawerChild(parentPaneID: owner.id),
                        ownedDrawerChildIds: []),
                    .init(paneId: addedId, placement: .drawerChild(parentPaneID: owner.id), ownedDrawerChildIds: []),
                ]))
        #expect(store.paneAtom.pane(fixture.ownerId.uuid)?.drawer?.paneIds == [fixture.drawerId.uuid, addedId.uuid])
        await fixture.composition.paneContextService.reconcileMembership()
        try await window.canonicalChangeCompleted(forwarding)
        if cardMode { try await window.renderedCard() } else { try await window.rendered() }
        return addedId
    }

    func close() async throws {
        try await window.close()
        try await fixture.close()
        store.removePane(fixture.ownerId.uuid)
    }
}

private enum PromptRefreshProofFailure: Error { case hookNotCommitted }
