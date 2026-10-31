import AgentStudioInfrastructure
import SwiftUI

/// Text-only alternatives and committing actions share geometry, not selection paint.
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
            .foregroundStyle(role == .commit ? AppStyles.General.Accent.committingControlForeground : Color.primary)
            .padding(.horizontal, AppStyles.Components.PaneContext.formActionHorizontalPadding)
            .padding(.vertical, AppStyles.Components.PaneContext.formActionVerticalPadding)
            .frame(minHeight: AppStyles.General.Button.compact)
            .background {
                RoundedRectangle(cornerRadius: AppStyles.Components.PaneContext.formControlCornerRadius)
                    .fill(fill(isPressed: configuration.isPressed))
                    .overlay {
                        if role == .alternative {
                            RoundedRectangle(cornerRadius: AppStyles.Components.PaneContext.formControlCornerRadius)
                                .stroke(
                                    isSelected
                                        ? AppStyles.General.Accent.primaryColor
                                        : Color.white.opacity(AppStyles.Components.PaneContext.formActionStrokeOpacity))
                        }
                    }
            }
            .opacity(isEnabled ? 1 : AppStyles.General.Foreground.dim)
            .contentShape(Rectangle())
    }

    private func fill(isPressed: Bool) -> Color {
        if role == .commit { return AppStyles.General.Accent.primaryColor }
        if isPressed { return Color.white.opacity(AppStyles.General.Fill.pressed) }
        if isSelected { return AppStyles.General.Accent.primaryColor.opacity(AppStyles.General.Fill.selected) }
        return isHighlighted ? Color.white.opacity(AppStyles.General.Fill.hover) : .clear
    }
}
