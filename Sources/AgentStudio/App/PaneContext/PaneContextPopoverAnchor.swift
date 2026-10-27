import AppKit
import SwiftUI

/// Reads the actual anchor window only when an opening chooses its width; it observes no screen changes.
struct PaneContextPopoverAnchor: NSViewRepresentable {
    @MainActor final class Reference {
        weak var mountedView: NSView?
        var screenVisibleWidth: CGFloat {
            (mountedView?.window?.screen ?? NSScreen.main)?.visibleFrame.width ?? .infinity
        }
    }

    let reference: Reference

    func makeNSView(context: Context) -> AnchorView { AnchorView(reference: reference) }
    func updateNSView(_ view: AnchorView, context: Context) {}

    @MainActor final class AnchorView: NSView {
        private let reference: Reference
        init(reference: Reference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { reference.mountedView = self }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}
