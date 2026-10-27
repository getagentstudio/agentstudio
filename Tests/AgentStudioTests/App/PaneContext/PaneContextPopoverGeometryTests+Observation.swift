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
        var window: PaneContextNativePopoverWindow?
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
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = PaneContextNativePopoverWindow(
                paneId: fixture.ownerId, readers: readers, location: .pane, wallNow: fixture.now,
                messageEntryKind: .info, observesRelativeTimeApplications: observes)
            window = mounted
            try mounted.press("pane-context.messages.info")
            try await mounted.readCompleted()
            if observes { try await mounted.rendered() }
            mounted.layout()
            #expect(mounted.find("pane-context.popover-panel") != nil)
            #expect(mounted.labels().contains("An observable native message Now"))
            let receiptCount = mounted.roots.reduce(0) { $0 + applicationViewCount(in: $1) }
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
        let own = root is NativePresentationApplicationView<PaneRelativeTimeRefresh.Application> ? 1 : 0
        return own + root.subviews.reduce(0) { $0 + applicationViewCount(in: $1) }
    }
}
