import AgentStudioInfrastructure
import SwiftUI

package struct PaneContextActionButton: View {
    package enum Role {
        case utility(OcticonLoader)
        case rowDismiss(OcticonLoader)
        case alternative
        case commit
        case details(OcticonLoader)
    }

    private let control: PaneContextControlModel
    private let role: Role
    private let scope: String?
    private let action: @MainActor () -> Void
    private let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    package init(
        _ control: PaneContextControlModel, role: Role, scope: String? = nil, isSelected: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        self.control = control
        self.role = role
        self.scope = scope
        self.action = action
        self.isSelected = isSelected
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
            formButton(style: .alternative) { Text(control.label) }
        case .commit:
            formButton(style: .commit) { Text(control.label) }
        case .details(let loader):
            formButton(style: .alternative) {
                HStack(spacing: AppStyles.General.Spacing.tight) {
                    Text(control.label)
                    detailsIcon(loader).accessibilityHidden(true)
                }
            }
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
            icon: icon, label: control.accessibilityLabel, identifier: control.identifier(in: scope),
            tooltip: control.tooltip, isEnabled: true, content: content, selection: .normal,
            accessibilityHelp: control.accessibilityHelp)
    }

    @ViewBuilder private func detailsIcon(_ loader: OcticonLoader) -> some View {
        switch control.icon {
        case .system(let symbol): Image(systemName: symbol)
        case .octicon(let symbol):
            OcticonImage(name: symbol, size: AppStyles.General.Icon.compact, loader: loader)
        }
    }

    private func formButton<LabelContent: View>(
        style: PopoverFormButtonStyle.Role, @ViewBuilder label: () -> LabelContent
    ) -> some View {
        Button(action: action, label: label)
            .buttonStyle(PopoverFormButtonStyle(role: style, isHighlighted: isHovered, isSelected: isSelected))
            .controlHelp(control.tooltip)
            .onHover { isHovered = $0 }
            .accessibilityHidden(true)
            .background {
                AccessibilityPressBridge(
                    identifier: control.identifier(in: scope), label: control.accessibilityLabel,
                    isEnabled: isEnabled, isSelected: isSelected, help: control.accessibilityHelp, action: action)
            }
    }
}
