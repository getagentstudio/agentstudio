import AgentStudioInfrastructure
import SwiftUI

package struct PaneContextActionButton: View {
    private let control: PaneContextControlModel
    private let scope: String?
    private let isSelected: Bool
    private let action: @MainActor () -> Void
    @State private var isHovered = false
    package init(
        _ control: PaneContextControlModel, scope: String? = nil, isSelected: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        self.control = control
        self.scope = scope
        self.isSelected = isSelected
        self.action = action
    }
    package var body: some View {
        Button(control.label, action: action)
            .buttonStyle(PopoverOptionButtonStyle(isSelected: isSelected, isHighlighted: isHovered))
            .controlHelp(control.tooltip)
            .onHover { isHovered = $0 }
            .accessibilityHidden(true)
            .background {
                AccessibilityPressBridge(
                    identifier: control.identifier(in: scope), label: control.label,
                    help: control.tooltip.text, action: action)
            }
    }
}
