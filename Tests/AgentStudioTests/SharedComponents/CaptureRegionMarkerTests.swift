import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite("Passive capture region marker", .serialized)
struct CaptureRegionMarkerTests {
    @Test("marker adds no pixels or layout and cannot take input or accessibility actions")
    func captureMarkerPreservesPixelsLayoutAndInput() throws {
        let markerId = UUIDv7.generate().uuidString
        let plain = mount(marked: false, markerId: markerId)
        let marked = mount(marked: true, markerId: markerId)
        defer {
            for fixture in [plain, marked] {
                fixture.host.rootView = AnyView(EmptyView())
                fixture.window.contentView = nil
                fixture.window.close()
            }
        }

        #expect(plain.host.fittingSize == marked.host.fittingSize)
        #expect(plain.host.bounds == marked.host.bounds)
        let plainBitmap = try bitmap(plain.host)
        let markedBitmap = try bitmap(marked.host)
        let ink = try #require(plainBitmap.colorAt(x: 10, y: 10))
        #expect(ink.redComponent > 0.95 && ink.greenComponent < 0.05)
        #expect(plainBitmap.pixelsWide == markedBitmap.pixelsWide)
        #expect(plainBitmap.pixelsHigh == markedBitmap.pixelsHigh)
        #expect(plainBitmap.bytesPerRow == markedBitmap.bytesPerRow)
        let count = plainBitmap.bytesPerRow * plainBitmap.pixelsHigh
        #expect(
            Data(bytes: try #require(plainBitmap.bitmapData), count: count)
                == Data(bytes: try #require(markedBitmap.bitmapData), count: count))
        let marker = try #require(findMarker(marked.host))
        #expect(marker.regionKind == "fixture" && marker.regionID == markerId)
        #expect(marker.bounds.size == NSSize(width: 140, height: 50))
        #expect(!marker.isHidden && !marker.acceptsFirstResponder)
        #expect(marker.hitTest(CGPoint(x: 10, y: 10)) == nil)
        #expect(!marker.isAccessibilityElement())
        #expect(marker.accessibilityActionNames().isEmpty)
    }

    private func mount(marked: Bool, markerId: String) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let content = HStack(spacing: 0) {
            Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1).frame(width: 40)
            Text("Capture ink").foregroundStyle(.white).frame(maxWidth: .infinity)
        }.frame(width: 140, height: 50)
        let host = NSHostingView(
            rootView: AnyView(
                content.background {
                    if marked { CaptureRegionMarker(kind: "fixture", id: markerId) }
                }.background(Color.black)))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 140, height: 50), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return (host, window)
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func findMarker(_ view: NSView) -> CaptureRegionMarkerView? {
        if let marker = view as? CaptureRegionMarkerView { return marker }
        for child in view.subviews { if let found = findMarker(child) { return found } }
        return nil
    }
}
