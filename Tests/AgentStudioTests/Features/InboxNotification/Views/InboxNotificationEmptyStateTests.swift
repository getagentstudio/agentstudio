import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudioInboxNotification

@MainActor
@Suite("Inbox empty-state paint", .serialized)
struct InboxNotificationEmptyStateTests {
    @Test("The Inbox empty state retains its original centered semantic text pixels")
    func emptyStateMatchesOriginalPaint() throws {
        let actual = try render(InboxNotificationEmptyState())
        let reference = try render(
            VStack {
                Text("No notifications yet").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity))
        let actualBytes = try #require(actual.bitmapData)
        let referenceBytes = try #require(reference.bitmapData)
        #expect(actual.pixelsWide == reference.pixelsWide)
        #expect(actual.pixelsHigh == reference.pixelsHigh)
        #expect(actual.bytesPerRow == reference.bytesPerRow)
        #expect(
            Data(bytes: actualBytes, count: actual.bytesPerRow * actual.pixelsHigh)
                == Data(bytes: referenceBytes, count: reference.bytesPerRow * reference.pixelsHigh))
        if let directory = ProcessInfo.processInfo.environment["AGENTSTUDIO_EMPTY_STATE_FRAME_DIRECTORY"] {
            let output = URL(filePath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(actual.representation(using: .png, properties: [:]))
                .write(to: output.appending(path: "inbox-empty-current-360.png"))
            try #require(reference.representation(using: .png, properties: [:]))
                .write(to: output.appending(path: "inbox-empty-original-reference-360.png"))
        }
    }

    private func render<Content: View>(_ content: Content) throws -> NSBitmapImageRep {
        let captures = ProcessInfo.processInfo.environment["AGENTSTUDIO_EMPTY_STATE_FRAME_DIRECTORY"] != nil
        let origin: NSPoint
        if captures {
            let screen = try #require(NSScreen.screens.first { $0.backingScaleFactor == 2 })
            origin = .init(x: screen.frame.minX + 20, y: screen.frame.minY + 20)
        } else {
            origin = .init(x: -10_000, y: -10_000)
        }
        let root = content.frame(width: 360, height: 420)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = .init(x: 0, y: 0, width: 360, height: 420)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(origin)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}
