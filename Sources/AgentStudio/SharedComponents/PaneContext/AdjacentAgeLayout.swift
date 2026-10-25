import SwiftUI

/// Gives the suffix its intrinsic width and clamps only the preceding text.
package struct AdjacentAgeLayout: Layout {
    let maximumTextWidth: CGFloat
    package init(maximumTextWidth: CGFloat) { self.maximumTextWidth = maximumTextWidth }

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let age = subviews[1].sizeThatFits(.unspecified)
        let text = fittedText(in: subviews, availableWidth: (proposal.width ?? .infinity) - age.width)
        return CGSize(width: text.width + age.width, height: max(text.height, age.height))
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let age = subviews[1].sizeThatFits(.unspecified)
        let text = fittedText(in: subviews, availableWidth: bounds.width - age.width)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: text.width, height: text.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + text.width, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }

    private func fittedText(in subviews: Subviews, availableWidth: CGFloat) -> CGSize {
        let width = min(maximumTextWidth, max(0, availableWidth))
        let fitted = subviews[0].sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
        return CGSize(width: min(width, fitted.width), height: fitted.height)
    }
}
