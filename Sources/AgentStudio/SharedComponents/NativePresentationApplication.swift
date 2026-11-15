import AppKit
import SwiftUI

/// Acknowledges a supplied value after its native view update has reached layout.
package struct NativePresentationApplication<Value: Equatable>: NSViewRepresentable {
    let value: Value
    let onApplied: @MainActor (Value) -> Void
    let onRetired: @MainActor (Value) -> Void

    package init(
        value: Value, onApplied: @escaping @MainActor (Value) -> Void,
        onRetired: @escaping @MainActor (Value) -> Void
    ) {
        self.value = value
        self.onApplied = onApplied
        self.onRetired = onRetired
    }

    package func makeNSView(context _: Context) -> NativePresentationApplicationView<Value> {
        let view = NativePresentationApplicationView<Value>()
        view.prepare(value, onApplied: onApplied, onRetired: onRetired)
        return view
    }

    package func updateNSView(_ view: NativePresentationApplicationView<Value>, context _: Context) {
        view.prepare(value, onApplied: onApplied, onRetired: onRetired)
    }

    package static func dismantleNSView(_ view: NativePresentationApplicationView<Value>, coordinator _: ()) {
        view.retire()
    }
}

@MainActor
package final class NativePresentationApplicationView<Value: Equatable>: NSView {
    private enum Attachment { case measuring, mounted, retired }
    private var attachment = Attachment.measuring
    private var pendingValue: Value?
    private var appliedValue: Value?
    private var onApplied: (@MainActor (Value) -> Void)?
    private var onRetired: (@MainActor (Value) -> Void)?

    func prepare(
        _ value: Value, onApplied: @escaping @MainActor (Value) -> Void,
        onRetired: @escaping @MainActor (Value) -> Void
    ) {
        guard value != appliedValue else { return }
        pendingValue = value
        self.onApplied = onApplied
        self.onRetired = onRetired
        needsLayout = true
    }

    func retire() {
        if case .mounted = attachment, let value = pendingValue ?? appliedValue { onRetired?(value) }
        attachment = .retired
        pendingValue = nil
        onApplied = nil
        onRetired = nil
    }

    package override func layout() {
        super.layout()
        guard case .mounted = attachment, window != nil else { return }
        guard let value = pendingValue else { return }
        pendingValue = nil
        appliedValue = value
        onApplied?(value)
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            attachment = .mounted
            needsLayout = true
        }
    }

    package override func isAccessibilityElement() -> Bool { false }
    package override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
