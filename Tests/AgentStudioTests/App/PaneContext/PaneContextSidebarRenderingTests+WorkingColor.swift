import AppKit
import Foundation
import SwiftUI
import Testing

extension PaneContextSidebarRenderingTests {
    func assertWorkingColor(in host: NSView, rect: CGRect, associated: Bool) throws {
        let reference = workingTextReference(like: host)
        defer { reference.window.close() }
        let name = "sidebar-working-" + (associated ? "associated" : "unassociated")
        let actual = Array(try sampledWorkingPixels(in: host, rect: rect, name: name + "-calibrated"))
        let expected = Array(
            try sampledWorkingPixels(in: reference.host, rect: reference.host.bounds, name: name + "-text-reference"))
        let opaque = stride(from: 0, to: expected.count, by: 4).filter { expected[$0 + 3] == 255 }
        let first = try #require(opaque.first, "The independent literal blue text must paint opaque glyph pixels")
        let token = Array(expected[first..<first + 4])
        try #require(
            opaque.allSatisfy { Array(expected[$0..<$0 + 4]) == token },
            "Opaque glyph pixels must paint one literal blue through this native text context")
        #expect(
            stride(from: 0, to: actual.count, by: 4).contains { Array(actual[$0..<$0 + 4]) == token },
            "Working text must paint the exact literal semantic blue rendered through the same native context")
    }

    private func workingTextReference(like actual: NSView) -> (host: NSView, window: NSWindow) {
        let host = NSHostingView(
            rootView: Text("Working").font(.system(size: 12))
                .foregroundStyle(Color(.sRGB, red: 0x40 / 255.0, green: 0x9C / 255.0, blue: 1))
                .fixedSize().environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = actual.window?.appearance
        window.backgroundColor = .black
        window.contentView = host
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return (host, window)
    }

    private func sampledWorkingPixels(in host: NSView, rect: CGRect, name: String) throws -> Data {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        let pixels = try PaneContextToolbarRenderingTests().pixels(in: host, rect: rect)
        let bytes = Array(pixels)
        var counts: [String: Int] = [:]
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let color = bytes[index..<index + 4].map { String(format: "%02X", $0) }.joined()
            counts[color, default: 0] += 1
        }
        let palette = counts.sorted { $0.value > $1.value }.prefix(20)
            .map { "\($0.key):\($0.value)" }.joined(separator: ", ")
        let description =
            "\(name) rect=\(rect) bitmap=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) "
            + "space=\(bitmap.colorSpace) appearance=\(host.effectiveAppearance.name.rawValue) "
            + "sRGB_RGBA_palette=[\(palette)]"
        print(description)
        Attachment.record(description, named: name + ".txt")
        if let png = bitmap.representation(using: .png, properties: [:]) {
            Attachment.record(Array(png), named: name + ".png")
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            do {
                try png.write(to: root.appending(path: "tmp/handback/" + name + ".png"))
            } catch {
                Attachment.record("Optional local PNG persistence failed: \(error)", named: name + "-persistence.txt")
            }
        }
        return pixels
    }
}
