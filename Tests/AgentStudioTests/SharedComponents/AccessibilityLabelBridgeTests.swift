import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite(.serialized)
struct AccessibilityLabelBridgeTests {
    @Test("native status label retains its full value across updates and hides both when not exposed")
    func nativeLabelAndValueUpdateTogether() throws {
        let host = NSHostingView(
            rootView: AccessibilityLabelBridge(
                identifier: "status-value", label: "Needs you", role: .staticText,
                help: "Needs you · question", value: "Needs you · question"))
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 30)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let bridge = try #require(findNativeLabel(in: host))
        #expect(bridge.accessibilityLabel() == "Needs you")
        #expect(bridge.accessibilityValue() as? String == "Needs you · question")
        host.rootView = .init(
            identifier: "status-value", label: "Needs you", role: .staticText,
            help: "Needs you · approval", value: "Needs you · approval")
        host.layoutSubtreeIfNeeded()
        #expect(bridge.accessibilityLabel() == "Needs you")
        #expect(bridge.accessibilityValue() as? String == "Needs you · approval")
        host.rootView = .init(
            identifier: "status-value", label: "Needs you", value: "Needs you · approval", exposesAccessibility: false)
        host.layoutSubtreeIfNeeded()
        #expect(bridge.accessibilityLabel() == nil)
        #expect(bridge.accessibilityValue() == nil)
    }
}

@MainActor
private func findNativeLabel(in root: NSView) -> AccessibilityLabelBridgeView? {
    if let label = root as? AccessibilityLabelBridgeView { return label }
    for child in root.subviews {
        if let label = findNativeLabel(in: child) { return label }
    }
    return nil
}
