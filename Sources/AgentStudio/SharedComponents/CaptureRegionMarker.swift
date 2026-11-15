import AppKit
import SwiftUI

/// A passive native region whose identity is interpreted by its capture owner.
package struct CaptureRegionMarker: NSViewRepresentable {
    let kind: String
    let id: String

    package init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }

    package func makeNSView(context _: Context) -> CaptureRegionMarkerView {
        CaptureRegionMarkerView(kind: kind, id: id)
    }

    package func updateNSView(_ view: CaptureRegionMarkerView, context _: Context) {
        view.regionKind = kind
        view.regionID = id
    }
}

@MainActor
package final class CaptureRegionMarkerView: NSView {
    package var regionKind: String
    package var regionID: String

    package init(kind: String, id: String) {
        regionKind = kind
        regionID = id
        super.init(frame: .zero)
    }

    required init?(coder _: NSCoder) { nil }

    package override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    package override var acceptsFirstResponder: Bool { false }
    package override func hitTest(_: NSPoint) -> NSView? { nil }
    package override func isAccessibilityElement() -> Bool { false }
    package override func accessibilityActionNames() -> [NSAccessibility.Action] { [] }
}
