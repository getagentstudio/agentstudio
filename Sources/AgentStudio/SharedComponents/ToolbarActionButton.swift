import AgentStudioInfrastructure
import SwiftUI

/// Data-only control contract. Callers cannot inject a label view or override paint metrics.
package struct ToolbarActionButtonPresentation {
    package enum Icon {
        case system(String)
        case octicon(String)
    }
    package enum Content {
        case icon(label: String? = nil)
        case editorChooser(title: String?)
    }
    package enum Selection {
        case normal
        case selected
        case accent
    }
    package enum IconTone {
        case standard
        case success
        case warning
        case danger
        case repository(String)
    }

    package let icon: Icon
    package let label: String
    package let identifier: String
    package let tooltip: ControlTooltipRenderValue
    package let isEnabled: Bool
    package let content: Content
    package let selection: Selection
    package let iconTone: IconTone

    package init(
        icon: Icon, label: String, identifier: String,
        tooltip: ControlTooltipRenderValue, isEnabled: Bool,
        content: Content = .icon(), selection: Selection = .normal,
        iconTone: IconTone = .standard
    ) {
        self.icon = icon
        self.label = label
        self.identifier = identifier
        self.tooltip = tooltip
        self.isEnabled = isEnabled
        self.content = content
        self.selection = selection
        self.iconTone = iconTone
    }
}

/// The sole drawer-action renderer: fixed glyph scale, hit area, paint, and accessibility.
package struct ToolbarActionButton: View {
    private let presentation: ToolbarActionButtonPresentation
    private let octiconLoader: OcticonLoader
    private let action: @MainActor () -> Void
    @State private var isHovered = false

    package init(
        presentation: ToolbarActionButtonPresentation,
        octiconLoader: OcticonLoader,
        action: @escaping @MainActor () -> Void
    ) {
        self.presentation = presentation
        self.octiconLoader = octiconLoader
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            content
                .frame(height: AppStyles.General.Button.compact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(
            RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.button)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.button)
                        .stroke(stroke, lineWidth: 1)
                )
        )
        .disabled(!presentation.isEnabled)
        .controlHelp(presentation.tooltip)
        .accessibilityHidden(true)
        .background {
            AccessibilityPressBridge(
                identifier: presentation.identifier,
                label: presentation.label,
                isEnabled: presentation.isEnabled,
                help: presentation.tooltip.text,
                action: action
            )
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: AppStyles.General.Animation.fast)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.content {
        case .icon(let label):
            HStack(spacing: AppStyles.General.Spacing.tight) {
                glyph
                    .frame(width: AppStyles.General.Button.compact, height: AppStyles.General.Button.compact)
                if let label {
                    Text(label)
                        .font(.system(size: AppStyles.General.Typography.textXs, weight: .medium))
                        .lineLimit(1)
                        .padding(.trailing, AppStyles.Shell.DrawerToolbar.labeledActionTrailingPadding)
                }
            }
        case .editorChooser(let title):
            HStack(spacing: AppStyles.Components.EditorChooser.chooserButtonContentSpacing) {
                glyph
                if let title {
                    Text(title).lineLimit(1).truncationMode(.tail)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: AppStyles.Components.EditorChooser.chooserChevronFontSize, weight: .semibold))
            }
            .padding(.horizontal, AppStyles.Components.EditorChooser.chooserButtonHorizontalPadding)
        }
    }

    private var glyph: some View {
        Group {
            switch presentation.icon {
            case .system(let symbol):
                Image(systemName: symbol)
                    .font(.system(size: AppStyles.General.Icon.compact, weight: .medium))
            case .octicon(let symbol):
                OcticonImage(name: symbol, size: AppStyles.General.Icon.compact, loader: octiconLoader)
            }
        }
        .foregroundStyle(iconForeground)
    }

    private var foreground: Color {
        switch presentation.selection {
        case .accent: ChromeToolbarControlPalette.foregroundColor(isSelected: true, isHovered: isHovered)
        case .selected: .primary
        case .normal: isHovered ? .primary : .secondary
        }
    }

    private var iconForeground: Color {
        let color: Color
        switch presentation.iconTone {
        case .standard: return foreground
        case .success: color = AppStyles.Shell.Sidebar.chipSuccessColor
        case .warning: color = AppStyles.Shell.Sidebar.chipWarningColor
        case .danger: color = AppStyles.Shell.Sidebar.chipDangerColor
        case .repository(let hex):
            color = Color(nsColor: NSColor(hex: hex) ?? AppStyles.General.Accent.primaryNSColor)
        }
        return color.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity)
    }

    private var fill: Color {
        switch presentation.selection {
        case .accent: return ChromeToolbarControlPalette.fillColor(isSelected: true, isHovered: isHovered)
        case .selected: return Color.white.opacity(AppStyles.General.Fill.active)
        case .normal:
            if case .editorChooser = presentation.content {
                return isHovered ? Color.primary.opacity(AppStyles.General.Fill.hover) : .clear
            }
            return isHovered ? Color.white.opacity(AppStyles.General.Fill.hover) : .clear
        }
    }

    private var stroke: Color {
        guard case .accent = presentation.selection else { return .clear }
        return ChromeToolbarControlPalette.strokeColor(isSelected: true, isHovered: isHovered)
    }
}
