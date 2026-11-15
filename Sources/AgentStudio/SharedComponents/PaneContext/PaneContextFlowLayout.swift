import AgentStudioInfrastructure
import SwiftUI

/// Measures each action at the available text width and wraps whole controls onto the next row.
struct PaneContextFlowLayout: Layout {
    private let spacing = AppStyles.General.Spacing.loose

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, element) in result.elements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + element.origin.x, y: bounds.minY + element.origin.y),
                proposal: ProposedViewSize(element.size))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, elements: [CGRect]) {
        let available = max(0, width ?? .infinity)
        var elements: [CGRect] = []
        var position = CGPoint.zero
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, available), height: nil))
            if position.x > 0, position.x + size.width > available {
                position.x = 0
                position.y += rowHeight + spacing
                rowHeight = 0
            }
            elements.append(CGRect(origin: position, size: size))
            usedWidth = max(usedWidth, position.x + size.width)
            rowHeight = max(rowHeight, size.height)
            position.x += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: position.y + rowHeight), elements)
    }
}
