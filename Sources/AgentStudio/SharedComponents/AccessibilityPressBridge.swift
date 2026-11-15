import AppKit
import SwiftUI

package struct AccessibilityPressBridge: NSViewRepresentable {
    let identifier: String
    let label: String
    let value: String?
    let isEnabled: Bool
    let isSelected: Bool
    let help: String?
    let action: @MainActor () -> Void

    package init(
        identifier: String,
        label: String,
        value: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        help: String? = nil,
        action: @MainActor @escaping () -> Void
    ) {
        self.identifier = identifier
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.help = help
        self.action = action
    }

    package func makeNSView(context _: Context) -> AccessibilityPressBridgeView {
        let view = AccessibilityPressBridgeView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.label = label
        view.value = value
        view.isEnabled = isEnabled
        view.isSelected = isSelected
        view.help = help
        view.action = action
        return view
    }

    package func updateNSView(_ nsView: AccessibilityPressBridgeView, context _: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(identifier)
        nsView.label = label
        nsView.value = value
        nsView.isEnabled = isEnabled
        nsView.isSelected = isSelected
        nsView.help = help
        nsView.action = action
    }
}

@MainActor
package final class AccessibilityPressBridgeView: NSView {
    var label = ""
    var value: String?
    var isEnabled = true
    var isSelected = false
    var help: String?
    var action: @MainActor () -> Void = {}

    package override func isAccessibilityElement() -> Bool {
        true
    }

    package override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    package override func accessibilityIdentifier() -> String {
        identifier?.rawValue ?? ""
    }

    package override func isAccessibilitySelected() -> Bool { isSelected }

    package override func isAccessibilityEnabled() -> Bool {
        isEnabled
    }

    package override func accessibilityLabel() -> String? {
        label
    }

    package override func accessibilityValue() -> Any? {
        value
    }

    package override func accessibilityHelp() -> String? {
        help ?? super.accessibilityHelp()
    }

    package override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }
}
