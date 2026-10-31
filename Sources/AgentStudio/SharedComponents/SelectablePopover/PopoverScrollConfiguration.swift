import AppKit
import SwiftUI

/// Configures only the enclosing shared panel's scroll view; no global scrollbar preference changes.
struct PopoverScrollConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView(frame: .zero) }
    func updateNSView(_ view: ConfigurationView, context: Context) { view.configure() }
    static func dismantleNSView(_ view: ConfigurationView, coordinator: ()) { view.retire() }

    final class ConfigurationView: NSView {
        private weak var configuredScrollView: NSScrollView?
        private var styleObservation: NSKeyValueObservation?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configure()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            guard let scrollView = enclosingScrollView else {
                retire()
                return
            }
            if configuredScrollView !== scrollView {
                retire()
                configuredScrollView = scrollView
                // AppKit reapplies its preferred style when devices or preferences change.
                styleObservation = scrollView.observe(\.scrollerStyle, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.configure() }
                }
            }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
            if scrollView.drawsBackground { scrollView.drawsBackground = false }
        }

        func retire() {
            styleObservation?.invalidate()
            styleObservation = nil
            configuredScrollView = nil
        }
    }
}
