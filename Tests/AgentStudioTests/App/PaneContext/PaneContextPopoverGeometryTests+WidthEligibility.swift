import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextPopoverGeometryTests {
    @Test(
        "F14 opening width follows shown multiline bodies, excluding retained dismissed notices",
        arguments: [false, true], [false, true])
    func openingWidthTracksOnlyShownMultilineBodies(dismissed: Bool, drawerSource: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        let source = drawerSource ? fixture.drawerId : fixture.ownerId
        let multilineId = AgentMessageId.generateUUIDv7()
        let shortId = AgentMessageId.generateUUIDv7()
        let multilineBody = "First complete line\nSecond complete line"
        var mounted: PaneContextPreparedNativeHost?
        do {
            for (id, body) in [(multilineId, multilineBody), (shortId, "Short unread notice")] {
                try #require(
                    await service.send(
                        .init(
                            paneId: source, messageId: id, sender: .pane(source), sourceOccurredAt: nil,
                            importance: .info, body: body, why: nil, actions: [], shape: .notice)) == .created(id))
            }
            if dismissed {
                try #require(await service.dismiss(messageId: multilineId, paneId: source) == .done)
            }
            guard case .detail(let retained) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else { throw WidthEligibilityFailure.missingDetail }
            let rawRows = retained.messages + retained.drawerMessages.flatMap(\.messages)
            let retainedMultiline = try #require(rawRows.first { $0.id == multilineId })
            #expect(rawRows.count == 2)
            #expect(retainedMultiline.body == multilineBody)
            #expect(retainedMultiline.shape == .notice(dismissed ? .dismissed : .unread))
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let host = owners.makeNativeHost(
                paneId: fixture.ownerId, entry: .kind(.init(kind: .info, count: dismissed ? 1 : 2)),
                location: .sidebar, wallNow: fixture.now)
            mounted = host
            try await host.open()
            try await host.rendered()
            let rows = try #require(host.value?.shape?.messages.messageRows)
            #expect(rows.map(\.id).contains(shortId.uuid))
            #expect(rows.map(\.id).contains(multilineId.uuid) == !dismissed)
            #expect(rows.count == (dismissed ? 1 : 2))
            _ = try host.appliedMessage(
                .init(sourcePaneId: source.uuid, messageId: shortId.uuid),
                expectedLabel: "Short unread notice Now", age: "Now", isRead: false)
            let expectedWidth: CGFloat = dismissed ? 480 : 560
            #expect(host.value?.content.width == Double(expectedWidth))
            let panel = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            #expect(panel.bounds.width == expectedWidth)
            #expect(host.native.labels().contains(multilineBody + " Now") == !dismissed)
            try await host.close()
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }
}

private enum WidthEligibilityFailure: Error { case missingDetail }
