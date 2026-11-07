import AgentStudioInfrastructure
import SwiftUI

/// Decorative shortcut text supplied by the owning command or local action descriptor.
package struct SidebarShortcutHint: View {
    package enum Style: Equatable {
        case keycap
        case accentGlyph
        case toolbarStamp
        /// Plain secondary text, no outline or fill, for a hint that should
        /// read as quietly as the text around it.
        case secondaryText
    }

    private let displayText: ShortcutDisplayText
    private let style: Style

    package init(_ displayText: ShortcutDisplayText, style: Style = .keycap) {
        self.displayText = displayText
        self.style = style
    }

    package var body: some View {
        Text(displayText.value)
            .lineLimit(1)
            .font(font)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, AppStyles.Shell.Sidebar.KeyboardHint.horizontalPadding)
            .frame(
                minWidth: AppStyles.Shell.Sidebar.KeyboardHint.minimumWidth,
                minHeight: AppStyles.Shell.Sidebar.KeyboardHint.height
            )
            .fixedSize()
            .background(
                RoundedRectangle(cornerRadius: AppStyles.Shell.Sidebar.KeyboardHint.cornerRadius)
                    .fill(backgroundColor)
            )
            .overlay {
                if style == .keycap {
                    RoundedRectangle(cornerRadius: AppStyles.Shell.Sidebar.KeyboardHint.cornerRadius)
                        .strokeBorder(
                            AppStyles.General.Stroke.controlGroupColor,
                            lineWidth: AppStyles.Shell.Sidebar.KeyboardHint.keycapBorderWidth
                        )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var font: Font {
        switch style {
        case .toolbarStamp:
            .system(
                size: AppStyles.Shell.Sidebar.KeyboardHint.stampFontSize,
                weight: AppStyles.Shell.Sidebar.KeyboardHint.stampFontWeight, design: .monospaced)
        case .secondaryText:
            .system(size: AppStyles.General.Typography.textXs)
        case .keycap, .accentGlyph:
            .system(size: AppStyles.Shell.Sidebar.KeyboardHint.fontSize, weight: .medium, design: .monospaced)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .secondaryText:
            Color.secondary
        case .accentGlyph:
            Color.accentColor
        case .toolbarStamp:
            AppStyles.Shell.Sidebar.KeyboardHint.stampForegroundColor
        case .keycap:
            Color.primary
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .accentGlyph:
            Color.clear
        case .toolbarStamp:
            AppStyles.Shell.Sidebar.KeyboardHint.stampBackgroundColor
        case .secondaryText:
            Color.clear
        case .keycap:
            Color(nsColor: .controlBackgroundColor)
        }
    }
}

/// Keeps a trailing action's layout slot stable while a shortcut stamp owns
/// its visual and interaction position.
package struct SidebarTrailingActionVisibility: Equatable {
    package let opacity: Double
    package let allowsHitTesting: Bool
    package let accessibilityHidden: Bool

    package init(shortcutDisplay: ShortcutDisplayText?) {
        let showsTrailingAction = shortcutDisplay == nil
        opacity = showsTrailingAction ? 1 : 0
        allowsHitTesting = showsTrailingAction
        accessibilityHidden = !showsTrailingAction
    }
}

extension View {
    package func sidebarShortcutHint(
        _ displayText: ShortcutDisplayText?,
        style: SidebarShortcutHint.Style = .keycap,
        alignment: Alignment = .center,
        offset: CGSize = .zero
    ) -> some View {
        overlay(alignment: alignment) {
            if let displayText {
                SidebarShortcutHint(displayText, style: style)
                    .offset(offset)
            }
        }
    }
}
