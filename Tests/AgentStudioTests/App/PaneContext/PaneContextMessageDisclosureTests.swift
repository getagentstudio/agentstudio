import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Message disclosure behavior", .serialized)
struct PaneContextMessageDisclosureTests {
    private static let fullBody = (1...33).map { "Compiler note \($0)" }.joined(separator: "\n")

    @Test("D62 six painted lines disclose exactly the remaining lines while AX retains the complete body")
    func exactHiddenCountKeepsTheFullAccessibilityLeaf() async throws {
        try await withDisclosure(body: Self.fullBody) { _, host, row, _ in
            let label = try host.appliedMessage(row, expectedLabel: Self.fullBody + " Now", age: "Now", isRead: false)
            #expect(label.native.label == Self.fullBody + " Now")
            let more = try control(host, row: row, expanded: false)
            #expect(more.accessibilityLabel() == "Show 27 more lines")
            let originalHeight = try textHeight(host, row: row)
            try #require(more.accessibilityPerformPress())
            try await host.bodyLayoutsPrepared()
            #expect(try control(host, row: row, expanded: true).accessibilityLabel() == "Show less")
            #expect(try textHeight(host, row: row) > originalHeight)
            #expect(
                (host.native.find(textIdentifier(row)) as? any NSAccessibilityProtocol)?.accessibilityLabel()
                    == Self.fullBody + " Now")
        }
    }

    @Test("D62 wrapped visual lines, not only newline characters, determine the exact hidden count")
    func wrappedLinesHaveAnIndependentMonospacedCount() async throws {
        let body = String(repeating: "W", count: 700) + "\nEnd"
        try await withDisclosure(body: body) { _, host, row, _ in
            let leaf = try #require(host.native.find(textIdentifier(row)) as? NSView)
            let glyphAdvance = ("W" as NSString).size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            ]).width
            let columns = Int(floor(leaf.bounds.width / glyphAdvance))
            try #require(columns > 0)
            // Independent fixed-width arithmetic; neither the production counter nor its TextKit algorithm supplies the oracle.
            let expectedLines = Int(ceil(700.0 / Double(columns))) + 1
            try #require(expectedLines > 6)
            #expect(
                try control(host, row: row, expanded: false).accessibilityLabel()
                    == "Show \(expectedLines - 6) more lines")
            #expect((leaf as any NSAccessibilityProtocol).accessibilityLabel() == body + " Now")
        }
    }

    @Test("D62 a same-row refresh and minute update preserve expansion; the next opening starts collapsed")
    func expansionBelongsToTheRowOpening() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var active: PaneContextPreparedNativeHost?
        do {
            let row = try await seed(fixture, body: Self.fullBody)
            let first = makeHost(fixture)
            active = first
            try await first.open()
            try await first.rendered()
            try await first.bodyLayoutsPrepared()
            try #require(try control(first, row: row, expanded: false).accessibilityPerformPress())
            try await first.bodyLayoutsPrepared()
            try await first.refresh()
            try await first.rendered()
            #expect(try control(first, row: row, expanded: true).accessibilityLabel() == "Show less")
            try await first.advance(by: .seconds(60), registeredAt: first.clock.now.advanced(by: .seconds(60)))
            _ = try first.appliedMessage(
                row, expectedLabel: Self.fullBody + " 1 min ago", age: "1 min ago", isRead: false)
            #expect(try control(first, row: row, expanded: true).accessibilityLabel() == "Show less")
            try await first.close()
            active = nil
            let second = makeHost(fixture)
            active = second
            try await second.open()
            try await second.rendered()
            try await second.bodyLayoutsPrepared()
            #expect(try control(second, row: row, expanded: false).accessibilityLabel() == "Show 27 more lines")
            #expect(second.native.find(controlIdentifier(row, expanded: true)) == nil)
            try await second.close()
            active = nil
            try await fixture.close()
        } catch {
            try? await active?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("D62 expanding and collapsing bound every region's writes through actual native retirement")
    func disclosureHeightWritesStayBounded() async throws {
        try await withDisclosure(body: Self.fullBody) { _, host, row, writes in
            var previous = writes().count
            for expanded in [false, true] {
                try #require(try control(host, row: row, expanded: expanded).accessibilityPerformPress())
                try await host.bodyLayoutsPrepared()
                let added = Array(writes().dropFirst(previous))
                #expect(!added.isEmpty, "The real row height must change on the user toggle")
                for region in [PaneContextPopoverHeightWrite.Region.header, .rows, .footer] {
                    #expect(
                        added.filter { $0.region == region }.count <= 2,
                        "Each region may settle at most twice for one disclosure action")
                }
                #expect(added.count <= 6)
                previous = writes().count
            }
        }
    }

    private func withDisclosure(
        body: String,
        operation:
            @MainActor (
                CompositionFactoryFixture, PaneContextPreparedNativeHost, MessageRowModel.Key,
                @MainActor () -> [PaneContextPopoverHeightWrite]
            ) async throws -> Void
    ) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var active: PaneContextPreparedNativeHost?
        var writes: [PaneContextPopoverHeightWrite] = []
        do {
            let row = try await seed(fixture, body: body)
            let host = makeHost(fixture) { writes.append($0) }
            active = host
            try await host.open()
            try await host.rendered()
            try await host.bodyLayoutsPrepared()
            try await operation(fixture, host, row, { writes })
            let beforeClose = writes.count
            try await host.close()
            active = nil
            #expect(writes.count - beforeClose <= 3, "Retirement cannot start a layout feedback loop")
            try await fixture.close()
        } catch {
            try? await active?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func seed(_ fixture: CompositionFactoryFixture, body: String) async throws -> MessageRowModel.Key {
        let id = AgentMessageId.generateUUIDv7()
        try #require(
            await fixture.composition.paneContextService.send(
                .init(
                    paneId: fixture.ownerId, messageId: id, sender: .pane(fixture.ownerId), sourceOccurredAt: nil,
                    importance: .failure, body: body, why: nil, actions: [], shape: .notice)) == .created(id))
        await fixture.composition.presentationLane.publishPending()
        return .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid)
    }

    private func makeHost(
        _ fixture: CompositionFactoryFixture,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil
    ) -> PaneContextPreparedNativeHost {
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: .init(), presentation: fixture.presentationAtom,
            pane: { _ in nil }, serviceProvider: { adapter })
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        return .init(
            paneId: fixture.ownerId, sourceOwners: owners,
            entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil),
            clock: clock, wallNow: { time.now }, bridge: bridge, onPanelHeightWrite: onHeightWrite)
    }

    private func controlIdentifier(_ row: MessageRowModel.Key, expanded: Bool) -> String {
        (expanded ? "pane-context.show-fewer-lines." : "pane-context.show-more-lines.") + textIdentifier(row)
    }
    private func textIdentifier(_ row: MessageRowModel.Key) -> String {
        "pane-context.message-text." + row.controlScope
    }
    private func control(_ host: PaneContextPreparedNativeHost, row: MessageRowModel.Key, expanded: Bool) throws
        -> any NSAccessibilityProtocol
    {
        try #require(
            host.native.find(controlIdentifier(row, expanded: expanded)) as? any NSAccessibilityProtocol,
            "Missing real disclosure control for expanded=\(expanded)")
    }
    private func textHeight(_ host: PaneContextPreparedNativeHost, row: MessageRowModel.Key) throws -> CGFloat {
        try #require(host.native.find(textIdentifier(row)) as? NSView).bounds.height
    }
}
