import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityCopyTests {
    @Test(arguments: ["pane", "session"])
    func nativeCopyButtonWritesTheIdentityWithoutItsDisplayPrefix(field: String) throws {
        let strip = try PaneIdentityCardFixture.strip("session-where")
        let expected = field == "pane" ? strip.context.paneId.uuidString : "01A1631E-ABCD-7443-8AC3-75EEE79D3333"
        let mounted = PaneIdentityCardFixture.mount(strip, width: 520)
        mounted.window.styleMask.insert(.titled)
        mounted.window.setContentSize(mounted.host.fittingSize)
        mounted.window.makeKeyAndOrderFront(nil)
        mounted.host.layoutSubtreeIfNeeded()
        defer {
            mounted.window.contentView = nil
            mounted.window.close()
        }
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { original in
            let saved = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
        defer {
            pasteboard.clearContents()
            if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
        }
        pasteboard.clearContents()
        try #require(
            pasteboard.setString("No identity copied", forType: .string),
            "The native pasteboard service must accept the test sentinel before exercising Copy")
        try #require(pasteboard.string(forType: .string) == "No identity copied")
        let frames = PaneIdentityCardFixture.frames(in: mounted.host)
        let buttonBounds = try #require(frames["\(field).copy"])
        let point = mounted.host.convert(CGPoint(x: buttonBounds.midX, y: buttonBounds.midY), to: nil)

        try click(at: point, in: mounted.window)

        #expect(pasteboard.string(forType: .string) == expected)
    }

    @Test func producersKeepCopyValuesSeparateFromDisplayText() throws {
        let session = try PaneIdentityCardFixture.verifiedSession(reference: "opaque · session-ref")
        let context = try PaneIdentityCardFixture.context().includingVerifiedLiveSession(session)
        let paneRow = try #require(context.identityRows.first { $0.id == "pane" })
        let sessionRow = try #require(context.identityRows.first { $0.id == "session" })

        #expect(paneRow.copyValue == context.paneId.uuidString)
        #expect(sessionRow.copyValue == session.sessionRef.value)
        #expect(sessionRow.text == "codex · opaque · session-ref")
        #expect(
            context.identityRows.filter { !["pane", "session"].contains($0.id) }.allSatisfy { $0.copyValue == nil })
    }

    private func click(at point: CGPoint, in window: NSWindow) throws {
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: Double(index + 1) / 10,
                    windowNumber: window.windowNumber, context: nil, eventNumber: index + 1,
                    clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
        }
    }
}
