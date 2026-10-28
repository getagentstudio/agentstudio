import AgentStudioInfrastructure
import SwiftUI

package struct PaneContextActionButton: View {
    package enum Role {
        case utility(OcticonLoader)
        case rowDismiss(OcticonLoader)
        case alternative
        case commit
    }

    private let control: PaneContextControlModel
    private let role: Role
    private let scope: String?
    private let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    package init(
        _ control: PaneContextControlModel, role: Role, scope: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.control = control
        self.role = role
        self.scope = scope
        self.action = action
    }

    package var body: some View {
        switch role {
        case .utility(let loader):
            ToolbarActionButton(
                presentation: toolbarPresentation(content: .icon(label: control.label)),
                octiconLoader: loader, action: action)
        case .rowDismiss(let loader):
            ToolbarActionButton(
                presentation: toolbarPresentation(content: .icon()), octiconLoader: loader, action: action)
        case .alternative:
            formButton(style: .alternative)
        case .commit:
            formButton(style: .commit)
        }
    }

    private func toolbarPresentation(content: ToolbarActionButtonPresentation.Content)
        -> ToolbarActionButtonPresentation
    {
        let icon: ToolbarActionButtonPresentation.Icon =
            switch control.icon {
            case .system(let symbol): .system(symbol)
            case .octicon(let symbol): .octicon(symbol)
            }
        return .init(
            icon: icon, label: control.label, identifier: control.identifier(in: scope),
            tooltip: control.tooltip, isEnabled: true, content: content, selection: .normal)
    }

    private func formButton(style: PopoverFormButtonStyle.Role) -> some View {
        Button(control.label, action: action)
            .buttonStyle(PopoverFormButtonStyle(role: style, isHighlighted: isHovered))
            .controlHelp(control.tooltip)
            .onHover { isHovered = $0 }
            .accessibilityHidden(true)
            .background {
                AccessibilityPressBridge(
                    identifier: control.identifier(in: scope), label: control.label,
                    isEnabled: isEnabled, help: control.tooltip.text, action: action)
            }
    }
}
