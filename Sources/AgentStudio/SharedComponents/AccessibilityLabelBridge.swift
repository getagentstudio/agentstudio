import AppKit
import SwiftUI

package struct AccessibilityLabelBridge: NSViewRepresentable {
    let identifier: String
    let label: String
    var role: NSAccessibility.Role = .group
    var help: String?
    var value: String?
    var selected: Bool?
    var exposesAccessibility = true
    var application: AccessibilityLabelApplication?

    package init(
        identifier: String,
        label: String,
        role: NSAccessibility.Role = .group,
        help: String? = nil,
        value: String? = nil,
        selected: Bool? = nil,
        exposesAccessibility: Bool = true,
        application: AccessibilityLabelApplication? = nil
    ) {
        self.identifier = identifier
        self.label = label
        self.role = role
        self.help = help
        self.value = value
        self.selected = selected
        self.exposesAccessibility = exposesAccessibility
        self.application = application
    }

    package func makeNSView(context _: Context) -> AccessibilityLabelBridgeView {
        let view = AccessibilityLabelBridgeView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.role = role
        view.help = help
        view.value = value
        view.selected = selected
        view.exposesAccessibility = exposesAccessibility
        view.applyLabel(label, application: application)
        return view
    }

    package func updateNSView(_ nsView: AccessibilityLabelBridgeView, context _: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(identifier)
        nsView.role = role
        nsView.help = help
        nsView.value = value
        nsView.selected = selected
        nsView.exposesAccessibility = exposesAccessibility
        nsView.applyLabel(label, application: application)
    }
    package static func dismantleNSView(_ view: AccessibilityLabelBridgeView, coordinator _: ()) {
        view.retireLabelApplication()
    }
}

@MainActor
package final class AccessibilityLabelBridgeView: NSView {
    var label = ""
    var role: NSAccessibility.Role = .group
    var help: String?
    var value: String?
    var selected: Bool?
    var exposesAccessibility = true
    private var application: AccessibilityLabelApplication?
    private var hasMounted = false
    private var retired = false

    /// The receipt reads the same native value that accessibilityLabel() returns.
    func applyLabel(_ label: String, application: AccessibilityLabelApplication?) {
        self.label = label
        self.application = application
        publishLabelApplication()
    }

    func retireLabelApplication() {
        guard !retired else { return }
        retired = true
        if hasMounted, let application {
            application.observe(.retired(applicationValue(application)))
        }
        self.application = nil
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            hasMounted = true
            publishLabelApplication()
        }
    }

    private func publishLabelApplication() {
        guard hasMounted, window != nil, !retired, let application else { return }
        defer { application.observe(.updateEnded(application.key)) }
        application.observe(.applied(applicationValue(application)))
    }

    private func applicationValue(_ application: AccessibilityLabelApplication) -> AccessibilityLabelApplication.Value {
        .init(key: application.key, identifier: accessibilityIdentifier(), label: accessibilityLabel() ?? "")
    }

    package override func isAccessibilityElement() -> Bool {
        exposesAccessibility
    }

    package override func accessibilityRole() -> NSAccessibility.Role? {
        role
    }

    package override func accessibilityIdentifier() -> String {
        guard exposesAccessibility else { return "" }
        return identifier?.rawValue ?? ""
    }

    package override func accessibilityLabel() -> String? {
        guard exposesAccessibility else { return nil }
        return label
    }

    package override func accessibilityHelp() -> String? {
        guard exposesAccessibility else { return nil }
        return help ?? super.accessibilityHelp()
    }

    package override func accessibilityValue() -> Any? {
        guard exposesAccessibility else { return nil }
        return value ?? super.accessibilityValue()
    }

    package override func isAccessibilitySelected() -> Bool {
        guard exposesAccessibility else { return false }
        return selected ?? super.isAccessibilitySelected()
    }
}
