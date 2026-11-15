import AgentStudioInfrastructure
import SwiftUI

/// Shared layout constants for the drawer system.
///
/// Referenced by DrawerPanelOverlay, DrawerPanel, and DrawerIconBar
/// to keep dimensions consistent across the tab-level overlay and
/// pane-level icon bar components.
///
/// **Dependency chain:** DrawerPanelOverlay positions the overlay using
/// `iconBarFrameHeight`, which is derived from icon bar component dimensions.
/// If any icon bar dimension changes, the derived values update automatically.
package enum DrawerLayout {

    // MARK: - Panel

    /// Fraction of tab width used for the drawer panel (0–1).
    package static let panelWidthRatio: CGFloat = 0.8

    /// Corner radius for the drawer panel and its glass effect shape.
    package static let panelCornerRadius: CGFloat = 14

    /// Minimum panel height in points.
    package static let panelMinHeight: CGFloat = 100

    /// Margin from tab bottom edge when computing maximum panel height.
    package static let panelBottomMargin: CGFloat = 60

    /// Minimum user-adjustable height ratio.
    package static let heightRatioMin: Double = 0.2

    /// Maximum user-adjustable height ratio.
    package static let heightRatioMax: Double = 0.95

    /// Padding inside the drawer panel around pane content (left, right, bottom).
    /// Matches `resizeHandleHeight` so the border around content is uniform on all sides.
    package static let panelContentPadding: CGFloat = resizeHandleHeight

    // MARK: - Connector

    /// Height of the S-curve connector between the panel and pane icon bar.
    package static let overlayConnectorHeight: CGFloat = 40

    /// Corner radius for the bottom corners of the connector bar.
    package static let connectorBottomCornerRadius: CGFloat = 6

    // MARK: - Icon Bar

    /// Height of the pane-level connector between pane and icon strip.
    /// Set to 0 since the icon bar is now a standalone rounded bar.
    static let connectorHeight: CGFloat = 0

    /// Width and height of icon bar buttons (derived from AppStyles compact size).
    static let iconButtonSize: CGFloat = AppStyles.General.Button.compact

    /// Corner radius for individual icon bar buttons.
    static let iconButtonCornerRadius: CGFloat = AppStyles.General.CornerRadius.button

    /// Vertical padding around the icon bar button strip.
    static let iconBarVerticalPadding: CGFloat = AppStyles.General.Spacing.tight

    /// Horizontal padding around the icon bar button strip.
    static let iconBarHorizontalPadding: CGFloat = AppStyles.General.Spacing.standard

    /// Corner radius for the icon bar background shape.
    static let iconBarCornerRadius: CGFloat = AppStyles.General.CornerRadius.bar

    // MARK: - Resize Handle

    /// Height of the draggable resize handle touch target at the top of the panel.
    package static let resizeHandleHeight: CGFloat = 8

    /// Width of the resize handle pill indicator.
    package static let resizeHandlePillWidth: CGFloat = 40

    /// Height of the resize handle pill indicator.
    package static let resizeHandlePillHeight: CGFloat = 4

    // MARK: - Pane Zoom Overlay

    /// Fraction of the selected Zoom region's width used by the complete
    /// drawer outline. The remaining 3% is split into two visible gutters.
    package static let zoomOutlineWidthRatio: CGFloat = 0.97

    /// Fraction of the selected Zoom region's height used by the complete
    /// drawer outline, connector included, leaving the upper 5% exposed.
    package static let zoomOutlineHeightRatio: CGFloat = 0.95

    // MARK: - Overlay Positioning

    /// Minimum gap between panel edge and tab edge when clamping horizontal position.
    package static let tabEdgeMargin: CGFloat = 4

    // MARK: - Derived

    /// Height of the icon strip (buttons + vertical padding).
    /// = `iconButtonSize` + 2 × `iconBarVerticalPadding`
    static let iconStripHeight: CGFloat = iconButtonSize + iconBarVerticalPadding * 2

    /// Total DrawerIconBar VStack height (connector + icon strip).
    static let iconBarTotalHeight: CGFloat = connectorHeight + iconStripHeight

    /// Approximate icon bar height for imperative layout calculations
    /// outside SwiftUI (e.g. WorkspaceSurfaceCoordinator drawer content rect).
    /// SwiftUI code should use the measured iconBarFrame preference instead.
    package static let iconBarFrameHeight: CGFloat = iconBarTotalHeight
}
