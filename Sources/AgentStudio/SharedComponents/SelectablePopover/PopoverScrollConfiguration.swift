import AppKit
import SwiftUI

/// Configures only the enclosing shared panel's scroll view; no global scrollbar preference changes.
struct PopoverScrollConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView(frame: .zero) }
    func updateNSView(_ view: ConfigurationView, context: Context) { view.configure() }

    final class ConfigurationView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configure()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            guard let scrollView = enclosingScrollView else { return }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
            if scrollView.drawsBackground { scrollView.drawsBackground = false }
        }
    }
}
