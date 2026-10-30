import AgentStudioInfrastructure
import AppKit
import CoreText

/// Text is measured by the off-main projector; the view receives only column widths.
package struct ArrangementTableMetrics: Equatable, Sendable {
    package let paneWidth: CGFloat
    package let worktreeWidth: CGFloat

    package static let minimum = Self(
        paneWidth: AppStyles.Components.ArrangementPanel.paneColumnWidth,
        worktreeWidth: AppStyles.Components.ArrangementPanel.worktreeColumnWidth)

    package var panelWidth: CGFloat { paneWidth + worktreeWidth + Self.fixedWidth }

    private static var fixedWidth: CGFloat {
        AppStyles.Components.ArrangementPanel.glyphTileSize
            + AppStyles.Components.ArrangementPanel.statusColumnWidth
            + AppStyles.Components.ArrangementPanel.actionsWidth
            + 4 * AppStyles.Components.ArrangementPanel.columnSpacing
            + 2 * AppStyles.Components.PopoverPanel.contentPadding
    }

    static func measuring(_ panes: [PaneVisibilityInfo]) -> Self {
        let titleFont = NSFont.systemFont(
            ofSize: AppStyles.Components.ArrangementPanel.titleFontSize, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: AppStyles.Components.ArrangementPanel.detailFontSize)
        var paneWidth = minimum.paneWidth
        var worktreeWidth = minimum.worktreeWidth
        for pane in panes {
            paneWidth = max(paneWidth, width(pane.title, font: titleFont))
            paneWidth = max(paneWidth, width(pane.paneNote ?? pane.agentLine, font: detailFont))
            worktreeWidth = max(worktreeWidth, width(pane.worktreeName, font: titleFont))
            worktreeWidth = max(worktreeWidth, width(pane.branchName ?? pane.cwdPath, font: detailFont))
        }
        let availableGrowth = AppStyles.Components.ArrangementPanel.maximumWidth - minimum.panelWidth
        let paneGrowth = paneWidth - minimum.paneWidth
        let worktreeGrowth = worktreeWidth - minimum.worktreeWidth
        let desiredGrowth = paneGrowth + worktreeGrowth
        let scale = desiredGrowth > 0 ? min(1, availableGrowth / desiredGrowth) : 1
        return Self(
            paneWidth: minimum.paneWidth + paneGrowth * scale,
            worktreeWidth: minimum.worktreeWidth + worktreeGrowth * scale)
    }

    private static func width(_ text: String?, font: NSFont) -> CGFloat {
        guard let text else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
