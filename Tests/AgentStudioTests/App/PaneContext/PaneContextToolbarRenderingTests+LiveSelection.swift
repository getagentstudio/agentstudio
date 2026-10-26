import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextToolbarRenderingTests {
    @Test("G22 a real unread notice clears to the stored line, then the real line clear removes the item in one host")
    func realPublicationChangesToolbarSelection() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Toolbar source")
            let paneId = PaneId(existingUUID: pane.id)
            let fixture = try await CompositionFactoryFixture.make(ownerId: paneId)
            let service = fixture.composition.paneContextService
            do {
                let readers = PaneContextUIReaders(
                    sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                    pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { .init(reader: service, person: service) }
                )
                var emptyPixels: Data?
                try await withMountedToolbar(pane: paneId, readers: readers, width: 1000) { empty in
                    emptyPixels = try pixels(in: empty.host)
                }
                let writer = AgentMessageSender.pane(paneId)
                guard
                    case .claimed(let epoch) = await service.claimEpoch(
                        .init(paneId: paneId, writer: writer, stream: .line, claimId: UUIDv7.generate()))
                else { throw LiveToolbarFailure.lineEpochUnavailable }
                try #require(
                    await service.setLine(
                        .init(
                            paneId: paneId, writer: writer, line: .init(summary: "Stored line after notices", refs: []),
                            writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
                let messageId = AgentMessageId.generateUUIDv7()
                try #require(
                    await service.send(
                        .init(
                            paneId: paneId, messageId: messageId, sender: writer, sourceOccurredAt: nil,
                            importance: .info, body: "A real informational notice", why: nil, actions: [],
                            shape: .notice)) == .created(messageId))
                await fixture.composition.presentationLane.publishPending()
                #expect(await service.readDisplay(paneId: paneId)?.own.kinds.info == 1)
                try await withMountedToolbar(pane: paneId, readers: readers, width: 1000) { mounted in
                    let identity = ObjectIdentifier(mounted.host)
                    let clock = try #require(mounted.clock)
                    #expect(buttonFrames(in: mounted.host)["pane-context.messages.info"] != nil)
                    #expect(!accessibilityLabels(in: mounted.host).contains("[2 min ago]"))

                    try #require(await service.markRead(messageId: messageId, paneId: paneId) == .done)
                    await fixture.composition.presentationLane.publishPending()
                    try #require(try await clock.nextOperation(pane: pane.id, input: nil) == .started)
                    try await clock.entered(pane: pane.id, input: nil)
                    let registration = try await clock.facts.expectNext(
                        in: 0, where: { _ in true }, "line deadline registration or owner end")
                    guard case .registered = registration else { throw LiveToolbarFailure.unexpectedFact(registration) }
                    try await clock.applied(pane: pane.id, input: nil)
                    mounted.host.layoutSubtreeIfNeeded()
                    mounted.host.displayIfNeeded()
                    #expect(buttonFrames(in: mounted.host)["pane-context.messages.info"] == nil)
                    try expectFullAge("[2 min ago]", in: mounted, width: 1000)

                    try #require(
                        await service.setLine(
                            .init(
                                paneId: paneId, writer: writer, line: nil,
                                writeNumber: .init(epoch: epoch, counter: 2))) == .applied)
                    await fixture.composition.presentationLane.publishPending()
                    try #require(
                        try await clock.nextOperation(pane: pane.id, input: nil) == .replaced(cancelRequested: true))
                    try await consumeLineClear(clock, pane: pane.id)
                    try await clock.applied(pane: pane.id, input: nil)
                    mounted.host.layoutSubtreeIfNeeded()
                    mounted.host.displayIfNeeded()
                    #expect(ObjectIdentifier(mounted.host) == identity)
                    #expect(try pixels(in: mounted.host) == (try #require(emptyPixels)))
                    #expect(clock.pendingSleepCount == 0)
                    #expect(await service.readDisplay(paneId: paneId)?.agentLine == nil)
                }
                try await fixture.close()
            } catch {
                try? await fixture.close()
                throw error
            }
        }
    }

    private func consumeLineClear(_ clock: NativeCardTestClock, pane: UUID) async throws {
        var ownerFacts: Set<String> = []
        while ownerFacts.count < 3 {
            let fact = try await clock.facts.expectNext(
                in: 1, where: { _ in true }, "replacement entered and both workers ended")
            let key: String
            switch fact {
            case .entered(pane, nil): key = "entered"
            case .workerEnded(pane, nil, cancelled: true): key = "cancelled"
            case .workerEnded(pane, nil, cancelled: false): key = "completed"
            default: throw LiveToolbarFailure.unexpectedFact(fact)
            }
            try #require(ownerFacts.insert(key).inserted, "Each worker outcome must arrive exactly once")
        }
        var clockFacts: Set<String> = []
        while clockFacts.count < 3 {
            let fact = try await clock.facts.expectNext(
                in: 0, where: { _ in true }, "cancelled sleep and both worker ends")
            let key: String
            switch fact {
            case .ended(_, _, cancelled: true): key = "sleepCancelled"
            case .workerEnded(pane, nil, cancelled: true): key = "cancelled"
            case .workerEnded(pane, nil, cancelled: false): key = "completed"
            default: throw LiveToolbarFailure.unexpectedFact(fact)
            }
            try #require(clockFacts.insert(key).inserted)
        }
    }
}

private enum LiveToolbarFailure: Error {
    case lineEpochUnavailable
    case unexpectedFact(NativeCardClockFact)
}
