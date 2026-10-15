import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit

@MainActor
extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test
    func nativeWebContentCanNavigateMinimalDocument() async throws {
        let page = WebPage(configuration: WebPageTestHarness.makeConfiguration())
        let frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WebView(page))
        host.sizingOptions = []
        host.frame = frame
        window.contentView = host
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer {
            page.stopLoading()
            window.orderOut(nil)
            window.contentView = nil
        }

        // No Bridge bootstrap, worker, custom scheme, or Git provider is present.
        let finished = try await awaitBridgeWebKitMilestone("minimal hosted HTML native navigation finished") {
            for try await event in page.load(
                html: "<html><head><title>TQ113 native baseline</title></head><body>loaded</body></html>")
            {
                if event == .finished { return event }
            }
            throw WebPageDocumentWaitProtocolFailure(detail: "minimal HTML navigation ended without finished")
        }
        #expect(finished == .finished)
        let title = await WebPageEventWaits.waitForTitle(page, equals: "TQ113 native baseline")
        #expect(title == "TQ113 native baseline")
    }
}
