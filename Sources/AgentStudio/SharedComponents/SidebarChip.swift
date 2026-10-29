import AgentStudioInfrastructure
import SwiftUI

/// Compact shared label with an optional icon and selected paint for status or toggle controls.
package struct SidebarChip: View {
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

    package init(
        icon: Icon? = nil,
        octiconLoader: OcticonLoader,
        text: String?,
        style: Style, isSelected: Bool = false
    ) {
        self.icon = icon
        self.octiconLoader = octiconLoader
        self.text = text
        self.style = style
        self.isSelected = isSelected
    }

    package var body: some View {
        let chipShape = Capsule(style: .circular)
        HStack(spacing: AppStyles.Shell.Sidebar.chipContentSpacing) {
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
            if let text {
                Text(text)
                    .font(.system(size: AppStyles.Shell.Sidebar.chipFontSize, weight: .medium).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .padding(
            .horizontal,
            text == nil
                ? AppStyles.Shell.Sidebar.chipIconOnlyHorizontalPadding : AppStyles.Shell.Sidebar.chipHorizontalPadding
        )
        .frame(height: AppStyles.Shell.Sidebar.chipLineHeight)
        .background {
            chipShape
                .fill(
                    isSelected
                        ? AppStyles.General.Accent.primaryColor.opacity(AppStyles.General.Fill.selected)
                        : Color.white.opacity(AppStyles.Shell.Sidebar.chipBackgroundOpacity)
                )
                .overlay { chipShape.fill(Color.black.opacity(AppStyles.Shell.Sidebar.chipMuteOverlayOpacity)) }
                .overlay {
                    chipShape.strokeBorder(
                        isSelected
                            ? AppStyles.General.Accent.primaryColor
                            : Color.white.opacity(AppStyles.Shell.Sidebar.chipBorderOpacity), lineWidth: 1)
                }
        }
        .foregroundStyle(
            isSelected
                ? AppStyles.General.Accent.selectedControlForeground
                : style.foreground.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity)
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}
