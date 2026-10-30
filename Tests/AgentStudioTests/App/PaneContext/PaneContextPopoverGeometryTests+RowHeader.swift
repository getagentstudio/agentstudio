import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextPopoverGeometryTests {
    @Test("A read-only Messages popover retains its title without a zero count")
    func readOnlyMessagesTitleOmitsZeroCount() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            for importance in [MessageImportance.done, .info] {
                let id = AgentMessageId.generateUUIDv7()
                try #require(
                    await service.send(
                        .init(
                            paneId: fixture.ownerId, messageId: id, sender: .pane(fixture.ownerId),
                            sourceOccurredAt: nil,
                            importance: importance, body: "A retained read notice", why: nil, actions: [],
                            shape: .notice)) == .created(id))
                #expect(await service.markRead(messageId: id, paneId: fixture.ownerId) == .done)
            }
            await fixture.composition.presentationLane.publishPending()
            #expect(fixture.presentationAtom.value(for: fixture.ownerId)?.includingDrawers.kinds.unread == 0)
            let adapter = PaneContextUIAdapter(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(
                paneId: fixture.ownerId,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                wallNow: fixture.now)
            window = mounted
            mounted.native.window.appearance = NSAppearance(named: .darkAqua)
            try await mounted.open()
            try await mounted.rendered()
            mounted.native.popoverWindow?.appearance = NSAppearance(named: .darkAqua)
            mounted.native.layout()
            try assertMessagesTitle(mounted.native, count: 0)
            #expect(mounted.value?.shape?.messages.groups.map(\.kind) == [.done, .info])
            #expect(mounted.value?.shape?.messages.messageRows.allSatisfy(\.isDimmed) == true)
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    func assertNoticeRowHeads(_ mounted: PaneContextNativePopoverWindow, keys: [PaneContextMessageKey]) throws {
        for key in keys {
            let scope = "\(key.paneId.uuid).\(key.messageId.uuid)"
            let body = try #require(mounted.find("pane-context.message-text." + scope) as? any NSAccessibilityProtocol)
            let dismiss = try #require(mounted.find("pane-context.dismiss." + scope) as? any NSAccessibilityProtocol)
            let bodyFrame = body.accessibilityFrame()
            let dismissFrame = dismiss.accessibilityFrame()
            #expect(bodyFrame.width > 0 && dismissFrame.width > 0)
            #expect(dismissFrame.minX >= bodyFrame.maxX, "S8 Dismiss must be to the right of its notice text")
            #expect(
                dismissFrame.maxY >= bodyFrame.minY && bodyFrame.maxY >= dismissFrame.minY,
                "S8 notice text and Dismiss must share the row head")
            if key == keys.first {
                let file = try #require(
                    mounted.find("pane-context.open-file." + scope + ".0") as? any NSAccessibilityProtocol)
                #expect(file.accessibilityLabel() == "Open file")
                #expect(bodyFrame.minY >= file.accessibilityFrame().maxY, "Targeted actions must stay below the body")
            }
        }
    }

    func assertMessagesTitle(_ mounted: PaneContextNativePopoverWindow, count: Int) throws {
        let header = try #require(mounted.find("pane-context.messages-header") as? NSView)
        let expected = "Messages" + (count > 0 ? " \(count)" : "")
        #expect(header.accessibilityLabel() == expected)
        let host = try #require(mounted.popoverWindow?.contentView)
        let headerRect = host.convert(header.bounds, from: header)
        let literal = NSHostingView(rootView: literalMessagesTitle(count: count).fixedSize())
        // D67 adds trailing Filter chrome. Compare the entire literal title/count ink region,
        // retaining the original font/weight/colour oracle independently of that new menu.
        let rect = CGRect(
            x: headerRect.minX, y: headerRect.minY, width: literal.fittingSize.width, height: headerRect.height)
        let actual = try PaneContextToolbarRenderingTests().pixels(in: host, rect: rect)
        let reference = try literalMessagesTitlePixels(count: count, like: host, rect: rect)
        #expect(
            actual == reference, "The title must paint title-case Messages at 13pt semibold with its adjacent count")
    }

    private func literalMessagesTitlePixels(count: Int, like actual: NSView, rect: CGRect) throws -> Data {
        let positionY = actual.isFlipped ? rect.midY : actual.bounds.height - rect.midY
        let host = NSHostingView(
            rootView:
                literalMessagesTitle(count: count)
                .fixedSize()
                .frame(width: rect.width, height: rect.height, alignment: .leading)
                .position(x: rect.midX, y: positionY)
                .frame(width: actual.bounds.width, height: actual.bounds.height)
                .environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: actual.bounds.size)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = actual.effectiveAppearance
        window.backgroundColor = .black
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let crop = CGRect(
            x: rect.minX, y: actual.isFlipped == host.isFlipped ? rect.minY : actual.bounds.height - rect.maxY,
            width: rect.width, height: rect.height)
        return try PaneContextToolbarRenderingTests().pixels(in: host, rect: crop)
    }

    private func literalMessagesTitle(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("Messages").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
            if count > 0 { Text(String(count)).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
    }
}
