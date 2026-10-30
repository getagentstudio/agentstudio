import AgentStudioInfrastructure
import SwiftUI

/// Compact shared label with optional icon and selection; hosts explicitly choose popover paint.
package struct SidebarChip: View {
    package enum Paint: Sendable {
        case sidebar, popover

        fileprivate var textHorizontalPadding: CGFloat {
            switch self {
            case .sidebar: AppStyles.Shell.Sidebar.chipHorizontalPadding
            case .popover: AppStyles.General.Spacing.standard
            }
        }
    }
    package enum Icon: Equatable {
        case octicon(String)
        case system(String)
    }

    package enum Style {
        case neutral
        case info
        case success
        case warning
        case danger
        case accent(Color)

        package var foreground: Color {
            switch self {
            case .neutral: return .secondary
            case .info: return AppStyles.Shell.Sidebar.chipInfoColor
            case .success: return AppStyles.Shell.Sidebar.chipSuccessColor
            case .warning: return AppStyles.Shell.Sidebar.chipWarningColor
            case .danger: return AppStyles.Shell.Sidebar.chipDangerColor
            case .accent(let color): return color
            }
        }
    }

    let icon: Icon?
    let octiconLoader: OcticonLoader
    let text: String?
    let style: Style
    let isSelected: Bool
    let paint: Paint

    package init(
        icon: Icon? = nil,
        octiconLoader: OcticonLoader,
        text: String?,
        style: Style, isSelected: Bool = false, paint: Paint = .sidebar
    ) {
        self.icon = icon
        self.octiconLoader = octiconLoader
        self.text = text
        self.style = style
        self.isSelected = isSelected
        self.paint = paint
    }

    package var body: some View {
        switch paint {
        case .sidebar:
            content
                .background(
                    Capsule()
                        .fill(
                            isSelected
                                ? AppStyles.General.Accent.primaryColor.opacity(AppStyles.General.Fill.selected)
                                : Color.white.opacity(AppStyles.Shell.Sidebar.chipBackgroundOpacity)
                        )
                        .overlay(Capsule().fill(Color.black.opacity(AppStyles.Shell.Sidebar.chipMuteOverlayOpacity)))
                )
                .foregroundStyle(
                    isSelected
                        ? AppStyles.General.Accent.selectedControlForeground
                        : style.foreground.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity)
                )
                .overlay(
                    Capsule().stroke(
                        isSelected
                            ? AppStyles.General.Accent.primaryColor
                            : Color.white.opacity(AppStyles.Shell.Sidebar.chipBorderOpacity), lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: true)
        case .popover:
            popoverChip
        }
    }

    private var popoverChip: some View {
        let chipShape = Capsule(style: .circular)
        return
            content
            .background {
                chipShape.fill(AppStyles.General.ControlSurface.fill)
                    .overlay {
                        chipShape.strokeBorder(AppStyles.General.ControlSurface.separator, lineWidth: 1)
                    }
            }
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: true, vertical: true)
            .opacity(isSelected ? 1 : AppStyles.Components.PaneContext.excludedFilterOpacity)
    }

    private var content: some View {
        HStack(spacing: AppStyles.Shell.Sidebar.chipContentSpacing) {
            Group {
                switch icon {
                case .octicon(let assetName)?:
                    OcticonImage(
                        name: assetName,
                        size: AppStyles.Shell.Sidebar.chipIconSize,
                        loader: octiconLoader
                    )
                case .system(let symbol)?:
                    Image(systemName: symbol)
                        .font(.system(size: AppStyles.Shell.Sidebar.chipIconSize, weight: .medium))
                case nil: EmptyView()
                }
            }
            .foregroundStyle(style.foreground.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity))
            if let text {
                Text(text)
                    .font(.system(size: AppStyles.Shell.Sidebar.chipFontSize, weight: .medium).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .padding(
            .horizontal,
            text == nil
                ? AppStyles.Shell.Sidebar.chipIconOnlyHorizontalPadding : paint.textHorizontalPadding
        )
        .frame(height: AppStyles.Shell.Sidebar.chipLineHeight)
    }
}
