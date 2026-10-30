import AgentStudioInfrastructure
import SwiftUI

/// Alternatives and committing actions share geometry and system-semantic surface roles.
package struct PopoverFormButtonStyle: ButtonStyle {
    package enum Role { case alternative, commit }
    private let role: Role
    private let isHighlighted: Bool
    private let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    package init(role: Role, isHighlighted: Bool = false, isSelected: Bool = false) {
        self.role = role
        self.isHighlighted = isHighlighted
        self.isSelected = isSelected
    }

    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppStyles.General.Typography.textSm, weight: role == .commit ? .medium : .regular))
            .foregroundStyle(
                role == .commit || isSelected || configuration.isPressed
                    ? AppStyles.General.ControlSurface.selectionForeground : Color.primary
            )
            .padding(.horizontal, AppStyles.Components.PaneContext.formActionHorizontalPadding)
            .padding(.vertical, AppStyles.Components.PaneContext.formActionVerticalPadding)
            .frame(minHeight: AppStyles.General.Button.compact)
            .background {
                RoundedRectangle(cornerRadius: AppStyles.Components.PaneContext.formControlCornerRadius)
                    .fill(fill(isPressed: configuration.isPressed))
                    .overlay {
                        if role == .alternative {
                            RoundedRectangle(cornerRadius: AppStyles.Components.PaneContext.formControlCornerRadius)
                                .strokeBorder(
                                    isSelected
                                        ? AppStyles.General.ControlSurface.accent
                                        : AppStyles.General.ControlSurface.separator)
                        }
                    }
            }
            .opacity(isEnabled ? 1 : AppStyles.General.Foreground.dim)
            .contentShape(Rectangle())
    }

    private func fill(isPressed: Bool) -> Color {
        if role == .commit { return AppStyles.General.ControlSurface.accent }
        if isPressed { return AppStyles.General.ControlSurface.pressed }
        if isSelected { return AppStyles.General.ControlSurface.selection }
        return isHighlighted ? AppStyles.General.ControlSurface.hover : AppStyles.General.ControlSurface.fill
    }
}
