import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio

/// Owns the test window and native inspection; production demand and work belong to its supplied host.
@MainActor
final class PaneContextNativePopoverWindow {
    let window: NSWindow
    let scrolling: PaneContextNativeScrollRecorder
    let presentationDecisions: PaneContextPresentationDecisionRecorder
    private var retired = false
    private var windowRetirementObserver: NSObjectProtocol?

    init(
        preparedRoot: AnyView, viewportWidth: CGFloat = 280, isCard: Bool = false, viewportHeight: CGFloat? = nil,
        scrolling: PaneContextNativeScrollRecorder = .init(),
        presentationDecisions: PaneContextPresentationDecisionRecorder = .init()
    ) {
        _ = NSApplication.shared
        self.scrolling = scrolling
        self.presentationDecisions = presentationDecisions
        let host = NSHostingView(rootView: preparedRoot)
        host.frame = CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight ?? (isCard ? 900 : 80))
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        layout()
        windowRetirementObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retireView(closeWindow: false) }
        }
    }

    isolated deinit {
        if let windowRetirementObserver { NotificationCenter.default.removeObserver(windowRetirementObserver) }
    }

    @discardableResult func press(_ identifier: String) throws -> UUID {
        let press = try presentationDecisions.beginPress()
        defer { presentationDecisions.pressReturned(press) }
        let button = try #require(
            find(identifier) as? any NSAccessibilityProtocol, "Missing native control: \(identifier)")
        try #require(button.accessibilityPerformPress(), "Native press refused: \(identifier)")
        return press
    }

    func layout() {
        for window in NSApp.windows where window.isVisible {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    func close() async throws {
        retireView()
        if let windowRetirementObserver { NotificationCenter.default.removeObserver(windowRetirementObserver) }
        windowRetirementObserver = nil
        try await scrolling.finish()
        try await presentationDecisions.finish()
    }

    func retireView() { retireView(closeWindow: true) }

    private func retireView(closeWindow: Bool) {
        guard !retired else { return }
        retired = true
        scrolling.retire()
        presentationDecisions.retire()
        window.contentView = nil
        if closeWindow { window.close() }
    }
}
