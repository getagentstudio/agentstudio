import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AppKit
import Testing

@testable import AgentStudio

extension PaneContextPopoverGeometryTests {
    @Test("S1 native application views exist only for a supplied observer", arguments: [false, true])
    func nativeApplicationObservationIsExplicit(observes: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: .pane(fixture.ownerId),
                        sourceOccurredAt: nil, importance: .info, body: "An observable native message",
                        why: nil, actions: [], shape: .notice)) == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(
                paneId: fixture.ownerId, entry: .kind(.init(kind: .info, count: 1)),
                wallNow: fixture.now, observesApplications: observes)
            window = mounted
            try await mounted.open()
            if observes { try await mounted.rendered() }
            mounted.native.layout()
            #expect(mounted.native.find("pane-context.popover-panel") != nil)
            #expect(mounted.native.labels().contains("An observable native message Now"))
            let receiptCount = mounted.native.roots.reduce(0) { $0 + applicationViewCount(in: $1) }
            #expect(
                (receiptCount > 0) == observes,
                "Production without an observer must not mount a needsLayout-writing receipt view")
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func applicationViewCount(in root: NSView) -> Int {
        let own = root is NativePresentationApplicationView<PaneContextPopoverApplication> ? 1 : 0
        return own + root.subviews.reduce(0) { $0 + applicationViewCount(in: $1) }
    }
}
