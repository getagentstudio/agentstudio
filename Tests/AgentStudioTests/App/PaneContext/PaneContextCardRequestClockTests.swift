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
        let clock = NativeCardTestClock()
        let refresh = PaneRelativeTimeRefresh(onEvent: { clock.observeOwner($0) })
        var mounted: PaneContextToolbarTestHost?
        var controller: PaneContextPopoverController?
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let id = AgentMessageId.generateUUIDv7()
            let service = fixture.composition.paneContextService
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: try fixture.sender(binding),
                        sourceOccurredAt: nil, importance: .attention, body: "Approve the clock?", why: nil,
                        actions: [], shape: .ask(reason: .approval, form: .approval, waiting: .nonBlocking)))
                    == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let active = readers.makePopoverController(reader: adapter, person: adapter, location: .card)
            controller = active
            await active.openCard(fixture.ownerId, selection: .ask(source: fixture.ownerId, message: id))
            let context = PaneManagementContext.project(paneId: owner.id, store: store)
            var input = PaneManagementIdentityCapture.input(context: context, store: store, readers: readers)
            let selected = try #require(active.selectedAsk)
            input.selectedAsk = selected
            input.detailMessages = active.state?.messages
            let origin = clock.now
            if knownActivity {
                input.activityTime = .init(
                    orderingInstant: origin, wallTime: fixture.now.addingTimeInterval(-45), source: .terminal)
            }
            let render = PaneContextToolbarRenderingTests()
            let host = render.mountCard(
                AnyView(
                    CardRequestClockView(
                        context: context, input: input, refresh: refresh, clock: clock, wallNow: fixture.now,
                        readers: readers, controller: active)), width: 640)
            mounted = host
            #expect(try await clock.nextOperation(pane: owner.id, input: knownActivity ? origin : nil) == .started)
            try await clock.entered(pane: owner.id, input: knownActivity ? origin : nil)
            try await clock.registered(
                origin.advanced(by: .seconds(knownActivity ? 15 : 60)), pane: owner.id,
                currentInput: knownActivity ? origin : nil)
            try assertAge("Now", in: host, render: render)
            if knownActivity {
                clock.advance(by: .seconds(15))
                try await clock.registered(origin.advanced(by: .seconds(60)), pane: owner.id, currentInput: origin)
                try assertAge("Now", in: host, render: render)
                #expect(render.accessibilityLabels(in: host.host).contains("ACTIVE 1 min ago"))
            }
            let steps: [(elapsed: Int, deadline: Int, words: String)] = [
                (60, knownActivity ? 75 : 120, "1 min ago"),
                (3600, knownActivity ? 7155 : 7200, "1 hr ago"),
                (86_400, knownActivity ? 172_755 : 172_800, "1 day ago"),
            ]
            var elapsed = knownActivity ? 15 : 0
            for step in steps {
                clock.advance(by: .seconds(step.elapsed - elapsed))
                elapsed = step.elapsed
                try await clock.registered(
                    origin.advanced(by: .seconds(step.deadline)), pane: owner.id,
                    currentInput: knownActivity ? origin : nil)
                try assertAge(step.words, in: host, render: render)
                #expect(active.selectedAsk?.detail.sentAt == fixture.now)
            }
            #expect(refresh.hide() == .cancelled(requested: true))
            try #require(try await clock.nextHideResult() == .cancelled(requested: true))
            try await clock.cancelledWorker(pane: owner.id, input: knownActivity ? origin : nil)
            #expect(clock.pendingSleepCount == 0)
            host.window.close()
            active.close()
            try await clock.finish()
            try await fixture.close()
        } catch {
            refresh.hide()
            mounted?.window.close()
            controller?.close()
            try? await clock.retire()
            try? await clock.facts.finish()
            try? await fixture.close()
            throw error
        }
    }

    private func assertAge(
        _ words: String, in host: PaneContextToolbarTestHost, render: PaneContextToolbarRenderingTests
    ) throws {
        host.host.layoutSubtreeIfNeeded()
        host.host.displayIfNeeded()
        #expect(render.accessibilityLabels(in: host.host).contains("Approve the clock? " + words))
        let reference = render.mountCard(AnyView(Text(words).foregroundStyle(.secondary).fixedSize()), width: nil)
        defer { reference.window.close() }
        let expected = try render.ink(in: reference.host, minimumBrightness: 60)
        #expect(expected.mask.contains(true))
        #expect(render.containsTextInk(expected, in: try render.ink(in: host.host, minimumBrightness: 60)))
    }
}

private struct CardRequestClockView: View {
    let context: PaneManagementContext
    let input: PaneManagementIdentityCapture.LineInput
    let refresh: PaneRelativeTimeRefresh
    let clock: NativeCardTestClock
    let wallNow: Date
    let readers: PaneContextUIReaders
    let controller: PaneContextPopoverController

    var body: some View {
        ManagementPaneIdentityStrip(
            context: context, octiconLoader: makeTestOcticonLoader(), lines: refresh.cardModel?.information.lines ?? [],
            activityText: refresh.cardModel?.activityText, cardModel: refresh.cardModel, readers: readers,
            actions: PaneContextPopoverHostActions.messages(
                controller: controller, readers: readers, onGoToPane: { _ in })
        )
        .frame(height: 600, alignment: .topLeading)
        .onAppear { refresh.startOrReplace(input, clock: clock, wallNow: wallNow) }
    }
}
