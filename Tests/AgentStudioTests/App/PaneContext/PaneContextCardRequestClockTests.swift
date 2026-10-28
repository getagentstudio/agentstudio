import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Visible card request clock", .serialized)
struct PaneContextCardRequestClockTests {
    @Test("F01 an open real request advances independently of E6 and cancels on hide", arguments: [false, true])
    func requestAgeHasItsOwnDeadline(knownActivity: Bool) async throws {
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let owner = store.createPane(title: "Request clock")
        defer { store.removePane(owner.id) }
        let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: owner.id))
        var mounted: PaneContextPreparedNativeHost?
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let id = AgentMessageId.generateUUIDv7()
            let service = fixture.composition.paneContextService
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id,
                        sender: try fixture.sender(binding), sourceOccurredAt: nil, importance: .attention,
                        body: "Approve the clock?", why: nil, actions: [],
                        shape: .ask(reason: .approval, form: .approval, waiting: .nonBlocking))) == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            var owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let activity = PaneActivityTime(
                orderingInstant: .now,
                wallTime: fixture.now.addingTimeInterval(-45), source: .terminal)
            owners.activity = { _ in knownActivity ? activity : nil }
            let host = owners.makeNativeCardHost(
                context: .project(paneId: owner.id, store: store), wallNow: fixture.now)
            mounted = host
            try await host.open()
            try await host.renderedCard()
            let render = PaneContextToolbarRenderingTests()
            try assertAge("Now", in: host, render: render)
            let origin = host.clock.now
            fixture.statements.begin()
            if knownActivity {
                try await host.advance(by: .seconds(15), registeredAt: origin.advanced(by: .seconds(15)))
                try await host.renderedCard()
                try assertAge("Now", in: host, render: render)
                #expect(host.native.labels().contains("ACTIVE 1 min ago"))
            }
            let steps: [(elapsed: Int, registered: Int, words: String)] = [
                (60, 60, "1 min ago"),
                (3600, knownActivity ? 75 : 120, "1 hr ago"),
                (86_400, knownActivity ? 7155 : 7200, "1 day ago"),
            ]
            var elapsed = knownActivity ? 15 : 0
            for step in steps {
                try await host.advance(
                    by: .seconds(step.elapsed - elapsed),
                    registeredAt: origin.advanced(by: .seconds(step.registered)))
                elapsed = step.elapsed
                try await host.renderedCard()
                try assertAge(step.words, in: host, render: render)
                #expect(host.cardValue?.selectedAsk?.detail.sentAt == fixture.now)
            }
            #expect(fixture.statements.end().isEmpty, "A card age-only refresh must not read or write SQL")
            try await host.close()
            #expect(await host.bindings.owner.scheduledWakeProducer() == nil)
            mounted = nil
            try await fixture.close()
        } catch {
            _ = fixture.statements.end()
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func assertAge(
        _ words: String, in host: PaneContextPreparedNativeHost, render: PaneContextToolbarRenderingTests
    ) throws {
        let content = try #require(host.native.window.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        #expect(host.native.labels().contains("Approve the clock? " + words))
        let reference = render.mountCard(AnyView(Text(words).foregroundStyle(.secondary).fixedSize()), width: nil)
        defer { reference.window.close() }
        let expected = try render.ink(in: reference.host, minimumBrightness: 60)
        #expect(expected.mask.contains(true))
        #expect(render.containsTextInk(expected, in: try render.ink(in: content, minimumBrightness: 60)))
    }
}
