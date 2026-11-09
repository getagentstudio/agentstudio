import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

/// The system-symbol initializer needs no octicon loader. It must still draw
/// the symbol it names, exactly as the presentation initializer draws that
/// symbol, and carry its label, help and action to the accessible button.
@MainActor
@Suite(.serialized)
struct ToolbarActionButtonSystemSymbolTests {
    private static let tooltip = ControlTooltipRenderValue(text: "Close this browser tab", shortcutDisplayText: nil)

    private static func systemSymbolButton(_ symbol: String, action: @escaping @MainActor () -> Void = {})
        -> ToolbarActionButton
    {
        ToolbarActionButton(
            systemSymbol: symbol, label: "Close Tab", identifier: "probe.close", tooltip: tooltip, isEnabled: true,
            action: action)
    }

    @Test("draws the named symbol as the presentation initializer draws it, with no loader")
    func systemSymbolButtonDrawsItsSymbol() throws {
        // Arrange: the same symbol through the loader-taking initializer.
        let reference = ToolbarActionButton(
            presentation: .init(
                icon: .system("xmark"), label: "Close Tab", identifier: "probe.close", tooltip: Self.tooltip,
                isEnabled: true),
            octiconLoader: OcticonLoader(resourceBundle: .main), action: {})

        // Act
        let closePixels = try Self.renderedPixels(Self.systemSymbolButton("xmark"))
        let referencePixels = try Self.renderedPixels(reference)
        let plusPixels = try Self.renderedPixels(Self.systemSymbolButton("plus"))
        let emptyPixels = try Self.renderedPixels(Color.clear)

        // Assert: a glyph is drawn, it is the named one, and it matches the established path.
        #expect(closePixels != emptyPixels, "the button must draw a glyph, not a blank")
        #expect(closePixels != plusPixels, "the button must draw the symbol it names")
        #expect(closePixels == referencePixels)
    }

    @Test("its accessible button carries the label, help and action")
    func systemSymbolButtonCarriesAccessibility() throws {
        // Arrange
        var presses = 0
        try Self.withMounted(Self.systemSymbolButton("xmark") { presses += 1 }) { host in
            let button = try #require(Self.pressBridge(in: host), "the button exposes its accessible element")

            // Act
            let pressed = button.accessibilityPerformPress()

            // Assert
            #expect(button.accessibilityIdentifier() == "probe.close")
            #expect(button.accessibilityLabel() == "Close Tab")
            #expect(button.accessibilityHelp() == "Close this browser tab")
            #expect(pressed)
            #expect(presses == 1)
        }
    }

    private static func withMounted<Content: View>(_ content: Content, body: (NSView) throws -> Void) throws {
        let host = NSHostingView(
            rootView: content.frame(width: 60, height: 40).background(Color.black)
                .environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        try body(host)
    }

    private static func renderedPixels<Content: View>(_ content: Content) throws -> Data {
        var pixels = Data()
        try withMounted(content) { host in
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let bytes = try #require(bitmap.bitmapData)
            pixels = Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        return pixels
    }

    private static func pressBridge(in view: NSView) -> AccessibilityPressBridgeView? {
        if let bridge = view as? AccessibilityPressBridgeView { return bridge }
        return view.subviews.lazy.compactMap { pressBridge(in: $0) }.first
    }
}
