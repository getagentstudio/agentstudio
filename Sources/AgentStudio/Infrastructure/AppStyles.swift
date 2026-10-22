// Native design-system source of truth. Keep its convention-based correlation with
// BridgeWeb/src/app/bridge-app.css aligned through
// docs/architecture/bridge/bridgeweb_design_token_architecture.md.

import SwiftUI

package enum AppStyles {
    package enum General {
        package enum Accent {
            // Exact-class token: must be sRGB and value-identical to BridgeWeb --primary.
            // Owner-chosen product primary (2026-08-16): #409CFF.
            // NSColor(hex:) constructs in Generic RGB and shifts the rendered color — do not use it here.
            package static let primaryHex = "#409CFF"
            package static let primaryNSColor = NSColor(
                srgbRed: 0x40 / 255.0, green: 0x9C / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
            package static let primaryColor = Color(.sRGB, red: 0x40 / 255.0, green: 0x9C / 255.0, blue: 0xFF / 255.0)
            package static let selectedControlForeground = Color(
                .sRGB, red: 0x89 / 255.0, green: 0xB4 / 255.0, blue: 0xFA / 255.0)
        }

        package enum Icon {
            package static let compact: CGFloat = 12
            package static let toolbar: CGFloat = 16
            package static let paneAction: CGFloat = 22
            package static let paneSplit: CGFloat = 14
        }

        package enum Padding {
            package static let icon: CGFloat = 6
            package static let paneControl: CGFloat = 8
        }

        package enum Button {
            package static let compact: CGFloat = Icon.compact + (Padding.icon * 2)
            package static let toolbar: CGFloat = Icon.toolbar + (Padding.icon * 2)
            package static let paneAction: CGFloat = Icon.paneAction + (Padding.paneControl * 2)
            package static let paneSplit: CGFloat = Icon.paneSplit + (Padding.paneControl * 2)
        }

        package enum Fill {
            package static let subtle: CGFloat = 0.04
            package static let muted: CGFloat = 0.06
            package static let hover: CGFloat = 0.08
            package static let pressed: CGFloat = 0.10
            package static let active: CGFloat = 0.12
            package static let selected: CGFloat = 0.15
        }

        package enum CornerRadius {
            package static let bar: CGFloat = 6
            package static let button: CGFloat = 4
            package static let panel: CGFloat = 8
            package static let pill: CGFloat = 14
        }

        package enum Spacing {
            package static let tight: CGFloat = 4
            package static let standard: CGFloat = 6
            package static let loose: CGFloat = 8
        }

        package enum Typography {
            // Smallest readable label for dense chrome affordances.
            package static let textXxs: CGFloat = 9
            package static let textXs: CGFloat = 11
            package static let textSm: CGFloat = 12
            package static let textBase: CGFloat = 13
            package static let textLg: CGFloat = 14
            package static let textXl: CGFloat = 16
            package static let text2xl: CGFloat = 24
            package static let text5xl: CGFloat = 48
        }

        package enum Foreground {
            package static let dim: CGFloat = 0.5
            package static let muted: CGFloat = 0.6
            package static let secondary: CGFloat = 0.7
        }

        package enum Stroke {
            package static let controlGroupColor = Color(
                .sRGB, red: 0x43 / 255.0, green: 0x4B / 255.0, blue: 0x57 / 255.0)
            package static let subtle: CGFloat = 0.10
            package static let muted: CGFloat = 0.15
            package static let hover: CGFloat = 0.20
            package static let visible: CGFloat = 0.25
        }

        package enum Animation {
            package static let fast: Double = 0.12
            package static let standard: Double = 0.20
        }

        package enum Layout {
            package static let paneGap: CGFloat = 1
            package static let dropTargetMarkerWidth: CGFloat = 8
            package static let dropTargetPreviewMinimumWidth: CGFloat = 34
            package static let dropTargetPreviewMaxFraction: CGFloat = 0.22
        }
    }

    package enum Shell {
        package enum Sidebar {
            package static let paneInfoColumnMinimumWidth: CGFloat = 200
            package static let paneInfoTwoColumnWidth: CGFloat =
                paneInfoColumnMinimumWidth * 2 + AppStyles.General.Spacing.loose
            package static let paneLineRotationSpeed = 0.35
            package static let paneLinePulseMinimumOpacity = 0.6
            package static let paneLinePulseMaximumOpacity = 1.0
            package static let paneLinePulsePeriod = 1.6
            package static let pendingFactsSymbolEffectSpeed = 0.35
            package static let statusUnavailableForegroundOpacity: CGFloat = 0.7
            package static let minimumWidth: CGFloat = 200
            package static let shadowOpacity: CGFloat = 0
            package static let shadowRadius: CGFloat = 0
            package static let shadowOffsetX: CGFloat = 0
            package static let shadowOffsetY: CGFloat = 0
            package static let rowContentSpacing: CGFloat = 4
            package static let drawerRailLineWidth: CGFloat = 1
            package static let drawerRailIconGap: CGFloat = 1
            package static let drawerRailOpacity: Double = 0.8
            package static let rowVerticalInset: CGFloat = 6
            package static let listRowLeadingInset: CGFloat = Header.contentPadding
            package static let groupIconSize: CGFloat = 14
            package static let groupIconTitleSpacing: CGFloat = AppStyles.General.Spacing.tight
            package static let rowLeadingIconColumnWidth: CGFloat = groupIconSize
            package static let drawerChildLeadingInset: CGFloat = rowLeadingIconColumnWidth
            package static let groupIconColumnWidth: CGFloat = rowLeadingIconColumnWidth
            package static let rowIdentityIconSize: CGFloat = 11
            package static let sectionHeaderChevronColumnWidth: CGFloat = AppStyles.General.Typography.textBase
            package static let sectionHeaderChevronLabelSpacing: CGFloat = groupIconTitleSpacing
            package static let groupOrganizationFontSize: CGFloat = AppStyles.General.Typography.textSm
            package static let groupTitleSpacing: CGFloat = AppStyles.General.Spacing.tight
            package static let groupOrganizationMaxWidth: CGFloat = 120
            package static let worktreeIconSize: CGFloat = rowIdentityIconSize
            package static let branchIconSize: CGFloat = 10
            package static let branchFontSize: CGFloat = AppStyles.General.Typography.textSm
            package static let rowHorizontalInset: CGFloat = AppStyles.General.Spacing.tight / 2
            package static let rowCornerRadius: CGFloat = AppStyles.General.CornerRadius.bar
            package static let groupRowVerticalPadding: CGFloat = 2
            package static let nativeItemSpacing: CGFloat = 8
            package static let nativeGroupSpacing: CGFloat = 12
            package static let nativeRowVerticalInset: CGFloat = nativeItemSpacing / 2
            package static let nativePrimaryTextLineHeight: CGFloat = 17
            package static let nativeMetadataTextLineHeight: CGFloat = 15
            package static let nativeGroupTitleLineHeight: CGFloat = 18
            package static let nativeInlineControlLineHeight: CGFloat = AppStyles.General.Button.compact
            package static let nativeLoadingCaptionLineHeight: CGFloat = 14
            package static let loadingSectionCapsuleVerticalPadding: CGFloat = 4
            package static let nativeLoadingSectionContentHeight: CGFloat =
                nativeLoadingCaptionLineHeight + loadingSectionCapsuleVerticalPadding * 2
            package static let nativeGroupHeaderTopPadding: CGFloat =
                nativeGroupSpacing - nativeRowVerticalInset - groupRowVerticalPadding
            package static let nativeGroupHeaderBottomPadding: CGFloat =
                nativeItemSpacing - groupRowVerticalPadding - nativeRowVerticalInset
            package static let nativeFirstSubgroupTopPadding: CGFloat =
                nativeItemSpacing - groupRowVerticalPadding - nativeGroupHeaderBottomPadding + General.Spacing.tight
            package static let nativeSubsequentSubgroupTopPadding: CGFloat =
                nativeGroupSpacing - nativeRowVerticalInset + General.Spacing.tight
            package static let nativeSectionHeaderBottomPadding: CGFloat = 0
            package static let nativeSubgroupBottomPadding: CGFloat =
                nativeItemSpacing - nativeRowVerticalInset
            package static let countBadgeHorizontalPadding: CGFloat = 6
            package static let countBadgeVerticalPadding: CGFloat = 2
            package static let countBadgeBackgroundOpacity: CGFloat = 0.15
            package static let notificationRowUnreadDotSize: CGFloat = 6
            package static let notificationRowTitleSize: CGFloat = AppStyles.General.Typography.textBase
            package static let notificationRowSourceSize: CGFloat = AppStyles.General.Typography.textSm
            package static let notificationRowDetailSize: CGFloat = AppStyles.General.Typography.textSm
            package static let notificationRowTimestampSize: CGFloat = AppStyles.General.Typography.textSm
            package static let chipRowSpacing: CGFloat = 4
            package static let chipContentSpacing: CGFloat = 2
            package static let syncClusterSpacing: CGFloat = 1
            package static let chipHorizontalPadding: CGFloat = 4
            package static let chipIconOnlyHorizontalPadding: CGFloat = 3
            package static let chipVerticalPadding: CGFloat = 2
            package static let chipFontSize: CGFloat = AppStyles.General.Typography.textXs
            package static let chipIconSize: CGFloat = 8
            package static let chipLineHeight: CGFloat = chipFontSize + (chipVerticalPadding * 2)
            package static let syncChipIconSize: CGFloat = 7
            package static let chipBackgroundOpacity: CGFloat = AppStyles.General.Fill.hover
            package static let chipBorderOpacity: CGFloat = AppStyles.General.Fill.muted
            package static let chipForegroundOpacity: CGFloat = 0.82
            package static let chipMuteOverlayOpacity: CGFloat = 0.16
            package static let rowSelectedOpacity: CGFloat = AppStyles.General.Fill.selected
            package static let rowHoverOpacity: CGFloat = AppStyles.General.Fill.pressed
            package static let badgeOffset: CGFloat = 4
            package static let badgeHitboxSize: CGFloat = AppStyles.General.Button.compact

            package enum KeyboardHint {
                package static let fontSize: CGFloat = AppStyles.General.Typography.textXs
                package static let stampFontSize: CGFloat = 12
                package static let stampFontWeight: Font.Weight = .bold
                package static let minimumWidth: CGFloat = AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth
                package static let height: CGFloat = AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
                package static let horizontalPadding: CGFloat = AppStyles.Shell.Sidebar.rowHorizontalInset
                package static let cornerRadius: CGFloat = 4
                package static let keycapBorderWidth: CGFloat = 0.5
                package static let stampForegroundColor = AppStyles.Shell.Chrome.ToolbarButton.baseFillColor
                package static let stampBackgroundColor = AppStyles.General.Accent.primaryColor
                package static let controlTrailingInset: CGFloat = 2
                package static let toggleVerticalOffset: CGFloat =
                    height / 2 + AppStyles.General.Spacing.tight
                package static let rowTrailingInset: CGFloat = 2
            }

            package enum SearchField {
                package static let contentSpacing: CGFloat = AppStyles.General.Spacing.standard
                package static let iconSize: CGFloat = AppStyles.General.Typography.textXs
                package static let textSize: CGFloat = AppStyles.General.Typography.textSm
                package static let horizontalPadding: CGFloat = AppStyles.General.Spacing.loose
                package static let verticalPadding: CGFloat = AppStyles.General.Spacing.tight
                package static let outerHorizontalPadding: CGFloat = 8
                package static let outerVerticalPadding: CGFloat = 6
                package static let cornerRadius: CGFloat = AppStyles.General.CornerRadius.bar
                package static let backgroundOpacity: CGFloat = AppStyles.General.Fill.subtle
                package static let borderOpacity: CGFloat = 0
                package static let borderWidth: CGFloat = 0
                package static let clearTransitionDuration: Double = 0.10
            }

            package enum Header {
                package static let contentPadding: CGFloat = 8
            }

            package enum EmptyState {
                package static let contentSpacing: CGFloat = 8
                package static let iconOpacity: CGFloat = 0.5
                package static let transitionDuration: Double = AppStyles.General.Animation.fast
            }

            package enum ToolbarControl {
                package static let cornerRadius = AppStyles.General.CornerRadius.button
                package static let foregroundOpacity = AppStyles.General.Foreground.secondary
                package static let disabledOpacity = AppStyles.General.Foreground.dim
                package static let hoverFillOpacity = AppStyles.General.Fill.hover
                package static let pressedFillOpacity = AppStyles.General.Fill.pressed
                package static let activeFillOpacity = AppStyles.General.Fill.active
                package static let segmentedControlSpacing: CGFloat = 1
                package static let segmentedControlPadding: CGFloat = 2
                package static let groupingContentSpacing = AppStyles.General.Spacing.tight
                package static let groupingHorizontalPadding = AppStyles.General.Spacing.standard
                package static let groupingLabelMinimumWidth: CGFloat = 32
                package static let groupingChevronSize: CGFloat = 8
                package static let labelFadeOutDuration: Double = 0.04
                package static let selectionResizeDelay: Double = 0.02
                package static let selectionResizeDuration = AppStyles.General.Animation.fast  // 120 ms
                package static let labelFadeInDuration: Double = 0.04
                // Fade in during the final 40 ms so text and geometry finish together.
                package static let labelFadeInDelay =
                    selectionResizeDelay + selectionResizeDuration - labelFadeInDuration
                package static let dividerHeight: CGFloat = 16
                package static let popoverRowCornerRadius = AppStyles.General.CornerRadius.button
                package static let popoverRowHorizontalPadding = AppStyles.General.Spacing.standard
                package static let popoverRowVerticalPadding = AppStyles.General.Spacing.tight
                package static let popoverMinimumWidth: CGFloat = 116
            }

            package static let groupChildRowLeadingInset: CGFloat =
                listRowLeadingInset
                + sectionHeaderChevronColumnWidth
                + sectionHeaderChevronLabelSpacing
            package static let nativeGroupChildRowLeadingInset: CGFloat =
                groupChildRowLeadingInset - rowHorizontalInset

            package static let statusRowLeadingIndent: CGFloat =
                rowLeadingIconColumnWidth + groupIconTitleSpacing

            package static let chipInfoColor = Color(red: 0.47, green: 0.69, blue: 0.96)
            package static let recencyMediumBlue = Color(red: 0.55, green: 0.68, blue: 0.84)
            package static let recencyMutedBlue = Color(red: 0.56, green: 0.64, blue: 0.75)
            package static let recencyFaintBlue = Color(red: 0.57, green: 0.61, blue: 0.66)
            package static let chipSuccessColor = Color(red: 0.42, green: 0.84, blue: 0.50)
            package static let chipWarningColor = Color(red: 0.93, green: 0.71, blue: 0.34)
            package static let chipDangerColor = Color(red: 0.93, green: 0.41, blue: 0.41)
            // Anchor rule (SIDEBAR-VISUAL-CONTRACT.md): By Repo's palette is the reference; other
            // surfaces synchronize to it. By Repo's second-line text (branch/placement lines
            // rendered through SidebarMetadataLine) uses SidebarMetadataProminence.secondary,
            // whose color is the system Color.secondary with no opacity modifier. Reference that
            // same system token directly here rather than a custom accent-derived value, so the
            // tab-group header icon matches the exact shade By Repo's own text lines already use.
            // (SharedComponents cannot be imported from Infrastructure, so this points at the
            // shared underlying system color rather than at SidebarMetadataProminence itself.)
            package static let tabGroupIconColor = Color.secondary
            package static let accentPaletteHexes: [String] = [
                "#F5C451",
                "#58C4FF",
                "#A78BFA",
                "#4ADE80",
                "#FB923C",
                "#F472B6",
            ]
            package static func paletteColor(at index: Int) -> Color {
                let hex =
                    accentPaletteHexes.indices.contains(index)
                    ? accentPaletteHexes[index]
                    : accentPaletteHexes.first ?? ""
                return Color(nsColor: NSColor(hex: hex) ?? AppStyles.General.Accent.primaryNSColor)
            }

            /// The automatic checkout palette's first color (`accentPaletteHexes[0]`, a yellow/gold
            /// accent). `RepoPresentationGrouping.checkoutColorHex` resolves every singleton-worktree
            /// repo to this same entry, which is what By Repo's favorite-star icon renders for the
            /// common case. Anchor rule (SIDEBAR-VISUAL-CONTRACT.md): other surfaces reference this
            /// same token rather than duplicating the hex literal.
            package static var checkoutDefaultAccentColor: Color {
                paletteColor(at: 0)
            }
        }

        package enum TabBar {
            package static let height: CGFloat = 40
            package static let tabPillHeight: CGFloat = 32
            package static let tabPillSpacing: CGFloat = 2
            /// Aligns the full-height tab-strip host so the pill centerline matches
            /// the native toolbar controls. The value is pixel-measured in the
            /// unified-compact toolbar after the custom item resolves to 40 points.
            package static let stripCenterlineOffset: CGFloat = 1
            package static let titlebarBackground = NSColor(
                srgbRed: 25.0 / 255.0, green: 27.0 / 255.0, blue: 31.0 / 255.0, alpha: 1.0
            )
        }

        package enum Chrome {
            package static let circledControlSpacing: CGFloat = 12
            package static let plainToolbarIconSpacing: CGFloat = 0
            package static let dividerHeight: CGFloat = 18
            package static let dividerHorizontalPadding: CGFloat = 0

            package enum PlainToolbarIcon {
                package static let buttonSize: CGFloat = 24
                package static let iconSize: CGFloat = AppStyles.Shell.Chrome.ToolbarButton.iconSize
            }

            package enum ToolbarButton {
                package static let size: CGFloat = 28
                package static let iconSize: CGFloat = 12
                package static let baseFillColor = Color(
                    nsColor: NSColor(hex: "#141416") ?? NSColor(white: 0.08, alpha: 1))
                package static let hoverFillColor = Color(
                    nsColor: NSColor(hex: "#242428") ?? NSColor(white: 0.14, alpha: 1))
                package static let pressedFillColor = hoverFillColor
                package static let iconForegroundNSColor = NSColor(hex: "#dddddd") ?? NSColor(white: 0.87, alpha: 1)
                package static let iconForegroundColor = Color(nsColor: iconForegroundNSColor)
                package static let hoverIconForegroundColor = Color.white
                package static let selectedFillOpacity: CGFloat = AppStyles.General.Fill.selected
                package static let baseStrokeOpacity: CGFloat = AppStyles.General.Stroke.muted
                package static let hoverStrokeColor = Color(
                    nsColor: NSColor(hex: "#dddddd") ?? NSColor(white: 0.87, alpha: 1))
                package static let hoverStrokeOpacity: CGFloat = 0.28
                package static let pressedStrokeColor = hoverStrokeColor
                package static let pressedStrokeOpacity: CGFloat = hoverStrokeOpacity
                package static let selectedStrokeOpacity: CGFloat = 0.30
                package static let badgeOffsetX: CGFloat = 6
                package static let badgeOffsetY: CGFloat = -5
            }
        }

        package enum Titlebar {
            package static let iconSize: CGFloat = 14
            package static let buttonSize: CGFloat = 28
            package static let buttonSpacing: CGFloat = 4
        }

        package enum PaneChrome {
            package static let inactivePaneDimmingOpacity: CGFloat = 0.30
            package static let inactivePaneDimmingDepth: CGFloat = 120
            package static let paneSplitIconSize: CGFloat = AppStyles.General.Icon.paneSplit
            package static let paneSplitButtonSize: CGFloat = AppStyles.General.Button.paneSplit
            package static let paneEdgeButtonHeight: CGFloat = paneSplitButtonSize + 12
            package static let maskFadeWidth: CGFloat = 14
            package static let collapsedBarWidth: CGFloat = 40
            package static let background = Color(nsColor: NSColor(white: 0.09, alpha: 1.0))
        }

        package enum DrawerToolbar {
            /// Slightly raised opaque surface for bottom-pane chrome above the app titlebar.
            package static let background = Color(
                nsColor: NSColor(
                    srgbRed: 29.0 / 255.0, green: 31.0 / 255.0, blue: 35.0 / 255.0, alpha: 1.0
                ))
            package static let trailingClusterSpacing: CGFloat = AppStyles.General.Spacing.standard
            package static let agentLineMaxWidth: CGFloat = 360
            package static let labeledActionTrailingPadding: CGFloat = AppStyles.General.Spacing.standard
            package static let dividerHeight: CGFloat = 16
            package static let dividerHorizontalPadding = AppStyles.General.Spacing.standard
            package static let statusClusterSpacing: CGFloat = AppStyles.General.Spacing.standard
            package static let statusValueSpacing: CGFloat = AppStyles.General.Spacing.tight
            package static let statusIconSize: CGFloat = AppStyles.General.Typography.textSm
            package static let statusFontSize: CGFloat = AppStyles.General.Typography.textXs
        }

        package enum ManagementLayer {
            package static let modeDimmingOpacity: CGFloat = 0.30
            package static let controlFillOpacity: CGFloat = 0.95
            package static let controlHoverDelta: CGFloat = -0.20
            package static let actionSize: CGFloat = 28
            package static let actionIconSize: CGFloat = 13
            package static let collapsedBarOrdinalForegroundOpacity: CGFloat = 0.92
            package static let dragHandleWidth: CGFloat = 60
            package static let dragHandleHeight: CGFloat = 100
            package static let dragHandleCornerRadius: CGFloat = 20

            package static func backgroundOpacity(isHovered: Bool) -> CGFloat {
                isHovered ? controlFillOpacity + controlHoverDelta : controlFillOpacity
            }

            package static func iconOpacity(isHovered: Bool) -> CGFloat {
                isHovered ? 1.0 : AppStyles.General.Foreground.muted
            }
        }
    }

    package enum WorkspaceFocus {
        package enum Terminal {
            package static let startupOverlayPadding: CGFloat = 28
            package static let startupOverlaySpacing: CGFloat = 16
            package static let errorOverlayCornerRadius: CGFloat = 12
            package static let errorOverlayContentPadding: CGFloat = 32
            package static let errorOverlayContentSpacing: CGFloat = 24
            package static let errorOverlaySectionSpacing: CGFloat = 16
            package static let errorOverlayActionTopPadding: CGFloat = 8
            package static let searchOverlayHorizontalInset: CGFloat = 12
            package static let searchOverlayMaximumWidth: CGFloat = 720
            package static let searchOverlayContentInset: CGFloat = 10
            package static let searchOverlayResultSpacing: CGFloat = 8
            package static let searchOverlayControlSpacing: CGFloat = 6
            package static let searchOverlayButtonSize: CGFloat = AppStyles.General.Button.compact
            package static let searchOverlayIconSize: CGFloat = AppStyles.General.Icon.compact
            package static let searchOverlayMinimumFieldWidth: CGFloat = 120
        }

        package enum Webview {
            package static let navigationBarHorizontalPadding: CGFloat = 8
            package static let navigationBarHeight: CGFloat = 36
            package static let navigationControlsSpacing: CGFloat = 8
            package static let navigationFieldHorizontalPadding: CGFloat = 8
            package static let navigationFieldVerticalPadding: CGFloat = 4
            package static let navigationFieldCornerRadius: CGFloat = 6
        }

        package enum Bridge {}

        package enum CodeViewer {}
    }

    package enum CommandBar {
        package enum Panel {
            package static let cornerRadius: CGFloat = 12
            package static let horizontalPadding: CGFloat = 12
            package static let nestedDividerOpacity: Double = 0.3
            package static let rootDividerOpacity: Double = 0.15
        }

        package enum Rows {
            package static let iconSpacing: CGFloat = 10
            package static let iconSize: CGFloat = 16
            package static let worktreeOpenIndicatorSize: CGFloat = 6
            package static let rowHeight: CGFloat = 36
            package static let rowHeightWithSecondaryLine: CGFloat = 52
            package static let secondaryLineSpacing: CGFloat = 3
            package static let secondaryLineIconSize: CGFloat = 12
            package static let secondaryLineOpacity: Double = 0.58
            package static let selectedSecondaryLineOpacity: Double = 0.72
            package static let shortcutSpacing: CGFloat = 4
            package static let rowTitleOpacity: Double = 0.92
            package static let selectedRowTitleOpacity: Double = 0.95
            package static let dimmedRowTitleOpacity: Double = 0.40
            package static let fuzzyUnmatchedTitleOpacity: Double = 0.65
            package static let trailingMetadataOpacity: Double = 0.68
            package static let dimmedTrailingMetadataOpacity: Double = 0.40
            package static let scopePillFontSize: CGFloat = AppStyles.General.Typography.textXs
            package static let scopePillTextOpacity: Double = 0.70
            package static let scopePillDismissOpacity: Double = 0.45
            package static let statusContextOpacity: Double = 0.50
            package static let trailingMetadataSpacing: CGFloat = 12
            package static let trailingMetadataMaxWidth: CGFloat = 260
            package static let chevronOpacity: Double = 0.48
            package static let selectedRowCornerRadius: CGFloat = 6
            package static let horizontalPadding: CGFloat = 12
            package static let selectedRowHorizontalInset: CGFloat = 4
        }

        package enum Footer {
            package static let primaryOpacity: Double = 0.40
            package static let secondaryOpacity: Double = 0.25
            package static let separatorOpacity: Double = 0.15
            package static let rowHeight: CGFloat = 16
            package static let separatorHorizontalPadding: CGFloat = 6
            package static let rowSpacing: CGFloat = 6
            package static let bottomRowSpacing: CGFloat = 14
            package static let hintSpacing: CGFloat = 4
            package static let topPadding: CGFloat = 6
            package static let bottomPadding: CGFloat = 8
            package static let horizontalPadding: CGFloat = 12
        }
    }

    package enum Components {
        package enum PopoverPanel {
            package static let contentPadding: CGFloat = 12
            package static let sectionSpacing: CGFloat = 8
        }

        package enum SidebarOrganizationPanel {
            package static let columnWidth: CGFloat = 160
            package static let columnSpacing: CGFloat = 16
        }

        package enum SectionSubheading {
            package static let fontSize: CGFloat = AppStyles.General.Typography.textBase
            package static let foregroundOpacity: Double = 0.80
            package static let horizontalPadding: CGFloat = 12
            package static let topPadding: CGFloat = AppStyles.General.Spacing.loose + AppStyles.General.Spacing.tight
            package static let bottomPadding: CGFloat = AppStyles.General.Spacing.tight
        }

        package enum PaneNote {
            package static let minimumWidth: CGFloat = 380
            package static let minimumHeight: CGFloat = 220
            package static let paneSizeRatio: CGFloat = 0.60
        }

        package enum EditorChooser {
            package static let menuWidth: CGFloat = 220
            package static let outerPadding: CGFloat = AppStyles.General.Spacing.standard
            package static let headerBottomPadding: CGFloat = AppStyles.General.Spacing.tight
            package static let headerContentSpacing: CGFloat = AppStyles.General.Spacing.tight
            package static let shortcutHintHorizontalPadding: CGFloat = 6
            package static let shortcutHintVerticalPadding: CGFloat = 2
            package static let rowSpacing: CGFloat = 2
            package static let rowContentSpacing: CGFloat = AppStyles.General.Spacing.standard
            package static let rowHorizontalPadding: CGFloat = AppStyles.General.Spacing.standard
            package static let rowVerticalPadding: CGFloat = AppStyles.General.Spacing.tight
            package static let rowCornerRadius: CGFloat = AppStyles.General.CornerRadius.panel
            package static let appIconSize: CGFloat = 14
            package static let badgeSize: CGFloat = 16
            package static let badgeCornerRadius: CGFloat = 5
            package static let bookmarkHitSize: CGFloat = 24
            package static let badgeFontSize: CGFloat = AppStyles.General.Typography.textXs
            package static let badgeFillOpacity: CGFloat = AppStyles.General.Fill.hover
            package static let fallbackIconFontSize: CGFloat = AppStyles.General.Typography.textSm
            package static let selectedRowFillOpacity: CGFloat = AppStyles.General.Fill.selected

            package static let chooserButtonContentSpacing: CGFloat = AppStyles.General.Spacing.standard
            package static let chooserButtonHorizontalPadding: CGFloat = AppStyles.General.Spacing.standard
            package static let chooserChevronFontSize: CGFloat = AppStyles.General.Typography.textXxs
        }

        package enum PaneInbox {
            package static let popoverWidth: CGFloat = 320
            package static let popoverHeight: CGFloat = 400
            package static let headerPadding: CGFloat = 12
            package static let headerControlSpacing: CGFloat = AppStyles.General.Spacing.standard
            package static let headerSeparatorHeight: CGFloat = AppStyles.General.Button.compact
            package static let filterButtonHorizontalPadding: CGFloat = AppStyles.General.Spacing.loose
            package static let filterButtonVerticalPadding: CGFloat = AppStyles.General.Spacing.tight
            package static let filterButtonCornerRadius: CGFloat = AppStyles.General.CornerRadius.button
            package static let filterButtonFontSize: CGFloat = AppStyles.General.Typography.textXs
            package static let rowCornerRadius: CGFloat = AppStyles.General.CornerRadius.panel
            package static let unreadBadgeFontSize: CGFloat = AppStyles.General.Typography.textXxs
            package static let unreadBadgeHorizontalPadding: CGFloat = 4
            package static let unreadBadgeVerticalPadding: CGFloat = 1
            package static let unreadBadgeOffset: CGFloat = 4
        }

        package enum NotificationBadge {
            package static let fontSize: CGFloat = AppStyles.Components.PaneInbox.unreadBadgeFontSize
            package static let horizontalPadding: CGFloat = AppStyles.Components.PaneInbox.unreadBadgeHorizontalPadding
            package static let verticalPadding: CGFloat = AppStyles.Components.PaneInbox.unreadBadgeVerticalPadding
            package static let offset: CGFloat = AppStyles.Components.PaneInbox.unreadBadgeOffset
        }
    }

    package enum Welcome {
        package static let pageHorizontalPadding: CGFloat = 56
        package static let pageVerticalPadding: CGFloat = 48
        package static let headerMaxWidth: CGFloat = 720

        package static let titleFontSize: CGFloat = 30
        package static let bodyFontSize: CGFloat = AppStyles.General.Typography.textXl
        package static let titleBodyGap: CGFloat = 8

        package static let recentListCornerRadius: CGFloat = 12
        package static let recentRowMinHeight: CGFloat = 56
        package static let recentRowSpacing: CGFloat = 0
        package static let recentListSeparatorOpacity: CGFloat =
            AppStyles.CommandBar.Panel.nestedDividerOpacity

        package static let previewWidth: CGFloat = 500
        package static let previewCornerRadius: CGFloat = 16

        package static let cardFillOpacity: CGFloat = AppStyles.General.Fill.muted
        package static let cardStrokeOpacity: CGFloat = AppStyles.General.Fill.active
        package static let cardHoverOpacity: CGFloat = AppStyles.Shell.Sidebar.rowHoverOpacity
        package static let interactiveHoverOpacity: CGFloat = AppStyles.General.Fill.hover

        // Spacing between an h2 section header and its content below.
        // Slightly tighter than launcherSectionGap (which separates top-level
        // sections) but looser than launcherRowGap (row-to-row inside a
        // section). Used by Recent and Shortcuts section headers.
        package static let sectionHeaderToContentSpacing: CGFloat = AppStyles.General.Spacing.loose + 4

        // MARK: - Typographic scale (semantic)
        //
        // Rules:
        //   - h1 appears exactly once per screen (page title).
        //   - h2 appears only when there are ≥2 sections to label.
        //   - h3 is for item/row titles.
        //   - body is page copy; bodySm is row subtitle.
        //   - caption is metadata (chips, footnotes).
        //   - key is keyboard-shortcut glyphs, monospaced and accent-colored.

        package enum Typography {
            package static let h1: Font = .system(size: titleFontSize, weight: .semibold)
            package static let h2: Font = .system(size: AppStyles.General.Typography.textLg + 1, weight: .semibold)
            package static let h3: Font = .system(size: AppStyles.General.Typography.textBase, weight: .medium)
            package static let body: Font = .system(size: AppStyles.General.Typography.textXl)
            package static let bodySm: Font = .system(size: AppStyles.General.Typography.textSm)
            package static let caption: Font = .system(size: AppStyles.General.Typography.textXs)
            package static let key: Font = .system(
                size: AppStyles.General.Typography.textBase,
                weight: .semibold,
                design: .monospaced
            )
        }

        package enum TextColor {
            package static let h2Opacity: CGFloat = 0.62
            package static let h3Opacity: CGFloat = 0.88
        }

        // Launcher composition (new — supersedes hero/scope geometry)
        // Welcome 2 is a top-aligned page, not a centered splash. Comfortable
        // top padding puts the header below the toolbar without floating.
        //
        // The shortcuts block mirrors Welcome 1: cmd-P chrome on the left
        // (the "real artifact" illustration), ⌘ shortcut rows on the right
        // (the "action column"). ContentMaxWidth accommodates both side-by-side:
        //   previewWidth (500) + columnsGap (40) + shortcuts column (≥320)
        package static let launcherContentMaxWidth: CGFloat = 900
        package static let launcherPageTopPadding: CGFloat = 72
        package static let launcherRowGap: CGFloat = 20
        package static let launcherSectionGap: CGFloat = 36
        package static let launcherShortcutsColumnsGap: CGFloat = 40
        package static let launcherDividerOpacity: CGFloat =
            AppStyles.CommandBar.Panel.nestedDividerOpacity
        package static let launcherShortcutKeyColumnWidth: CGFloat = 32
        package static let launcherShortcutKeyTitleGap: CGFloat = 12
        package static let launcherPreviewSubtitleOpacity: CGFloat = 0.50

        // Embedded cmd-P preview — mirrors the real modal with mock data
        // (five worktrees matching WelcomeSidebarIllustration). Height must
        // fit 3 group headers (~23pt) + 5 result rows (36pt) + internal padding
        // with a small margin for breathing room.
        package static let previewResultsHeight: CGFloat = 264
        package static let launcherPreviewCalloutGap: CGFloat = 12

        // Scopes callout (clickable pills below the preview)
        package static let scopesCalloutItemGap: CGFloat = 6
        package static let scopesCalloutHorizontalPadding: CGFloat = 10
        package static let scopesCalloutVerticalPadding: CGFloat = 8
        package static let scopesCalloutCornerRadius: CGFloat = 10

        // Scope pill (inside the callout) — accent-tinted background when
        // selected so the user sees which scope is driving the preview.
        package static let scopesCalloutPillHorizontalPadding: CGFloat = 10
        package static let scopesCalloutPillVerticalPadding: CGFloat = 6
        package static let scopesCalloutPillCornerRadius: CGFloat = 6
        package static let scopesCalloutPillContentSpacing: CGFloat = 6
        package static let scopesCalloutPillSelectedFillOpacity: CGFloat = 0.15

        // Crossfade when the selected scope flips the preview's mock data.
        // Short (100ms) — reads as a near-instant swap with just enough
        // softening to avoid a jarring flash.
        package static let launcherPreviewScopeCrossfadeDuration: Double = 0.1

        // Shortcut rows in the right column get the same faint-outlined card
        // chrome as the preview + scopes callout, so they read as clickable.
        package static let launcherShortcutRowCornerRadius: CGFloat = 10
        package static let launcherShortcutRowHorizontalPadding: CGFloat = 16
        package static let launcherShortcutRowVerticalPadding: CGFloat = 12

        // Folder-intake layout — shared by .noFolders, .scanning, .scanEmpty.
        // The illustration + logo + title + body stay fixed across all three
        // states; only the bottom action region swaps. Keeping the scene
        // continuous avoids the jarring layout rupture users saw on
        // transition between "no folders" → "scanning" → "launcher".
        package static let intakeColumnSpacing: CGFloat = 56
        package static let intakeRightColumnSpacing: CGFloat = 20
        package static let intakeLogoSize: CGFloat = 96
        package static let intakeActionTopPadding: CGFloat = 8
        package static let intakeActionRowSpacing: CGFloat = 10
        package static let intakeScanningSpinnerGap: CGFloat = 10
        package static let intakeScanningTitleOpacity: CGFloat = 0.88
    }

}
