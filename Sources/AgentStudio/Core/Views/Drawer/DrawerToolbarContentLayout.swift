import SwiftUI

/// Leading actions, the context item, the yielding Git readout, and trailing actions.
/// Every fit decision uses this pass's intrinsic sizes; no geometry state crosses passes.
struct DrawerToolbarContentLayout: SwiftUI.Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? sizes.reduce(0) { $0 + $1.width },
            height: proposal.height ?? sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let context = subviews[1].sizeThatFits(.unspecified)
        let git = subviews[2].sizeThatFits(.unspecified)
        let trailing = subviews[3].sizeThatFits(.unspecified)
        let available = max(0, bounds.width - leading.width - trailing.width)
        let showsContext = context.width > 0 && context.width <= available
        let showsGit =
            context.width > 0
            ? showsContext && context.width + git.width <= available
            : git.width <= available
        let gitWidth = showsGit ? git.width : 0
        let contextWidth = showsContext ? max(0, available - gitWidth) : 0
        let trailingX = bounds.maxX - trailing.width
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: leading.width, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + leading.width, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: contextWidth, height: bounds.height))
        subviews[2].place(
            at: CGPoint(x: trailingX - gitWidth, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: gitWidth, height: bounds.height))
        subviews[3].place(
            at: CGPoint(x: trailingX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: trailing.width, height: bounds.height))
    }
}
