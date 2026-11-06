import Foundation

/// The Pane Zoom region a drawer prefers to cover.
///
/// This is the owner's saved choice. The region actually used can differ:
/// a hidden Bridge region temporarily falls back to the terminal region
/// without rewriting this value.
package enum DrawerZoomSide: String, CaseIterable, Equatable, Hashable, Sendable {
    case terminal
    case bridge
}

/// Committed drawer presentation choices for one owning layout pane.
///
/// Keyed by the owning pane, never by drawer instance, arrangement, or focus,
/// so a drawer recreated on a surviving owner reuses the same choices. The
/// normal height and the Zoom side are independent: changing one never
/// rewrites the other, and display clamping never rewrites either.
package struct DrawerPresentationPreference: Equatable, Hashable, Sendable {
    package static let defaultNormalHeightRatio: Double = DrawerLayout.heightRatioMax
    /// A pane with no saved choice opens its Zoom drawer on the Bridge side,
    /// so the drawer does not cover the agent conversation in the terminal.
    package static let `default` = Self(
        normalHeightRatio: defaultNormalHeightRatio,
        zoomSide: .bridge
    )

    package let normalHeightRatio: Double
    package let zoomSide: DrawerZoomSide

    /// Callers pass values already admitted by `validatedNormalHeightRatio`;
    /// the stored ratio is clamped again so no path can hold an out-of-range value.
    package init(normalHeightRatio: Double, zoomSide: DrawerZoomSide) {
        self.normalHeightRatio =
            Self.validatedNormalHeightRatio(normalHeightRatio) ?? Self.defaultNormalHeightRatio
        self.zoomSide = zoomSide
    }

    package func replacingNormalHeightRatio(_ ratio: Double) -> Self {
        Self(normalHeightRatio: ratio, zoomSide: zoomSide)
    }

    package func replacingZoomSide(_ side: DrawerZoomSide) -> Self {
        Self(normalHeightRatio: normalHeightRatio, zoomSide: side)
    }

    /// Rejects non-finite ratios and clamps finite ones into the saved
    /// `heightRatioMin...heightRatioMax` range.
    package static func validatedNormalHeightRatio(_ ratio: Double) -> Double? {
        guard ratio.isFinite else { return nil }
        return min(DrawerLayout.heightRatioMax, max(DrawerLayout.heightRatioMin, ratio))
    }
}
