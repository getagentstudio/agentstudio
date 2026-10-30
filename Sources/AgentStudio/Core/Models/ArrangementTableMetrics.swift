import AgentStudioInfrastructure
import AppKit
import CoreText

/// Width measurement stays in the off-main projector; the view receives only its panel width.
package struct ArrangementTableMetrics: Equatable, Sendable {
    package let panelWidth: CGFloat
    package static let minimum = Self(panelWidth: AppStyles.Components.ArrangementPanel.minimumWidth)

    static func measuring(_ panes: [PaneVisibilityInfo]) -> Self {
        let titleFont = NSFont.systemFont(
            ofSize: AppStyles.Components.ArrangementPanel.titleFontSize, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: AppStyles.Components.ArrangementPanel.detailFontSize)
        let fixedWidth =
            2 * AppStyles.Components.PopoverPanel.contentPadding
            + AppStyles.Components.ArrangementPanel.statusDotSize
            + AppStyles.Components.ArrangementPanel.glyphTileSize
            + AppStyles.Components.ArrangementPanel.actionsWidth
            + 3 * AppStyles.Components.ArrangementPanel.columnSpacing
        var desired = AppStyles.Components.ArrangementPanel.minimumWidth
        for pane in panes {
            let trailing =
                pane.isMinimized
                ? LocalActionSpec.arrangementPaneHidden.actionSpec.label : pane.agentLine?.ageText
            let titleWidth =
                width(pane.title, font: titleFont) + width(trailing, font: detailFont)
                + AppStyles.General.Spacing.loose
            let detailWidth = width(pane.paneNote ?? pane.agentLine?.summary, font: detailFont)
            let cwdWidth = width(pane.cwdPath, font: detailFont)
            let providerWidth =
                width(pane.providerName, font: detailFont)
                + width(statusText(pane.agentStatus), font: detailFont) + AppStyles.General.Spacing.loose
            desired = max(desired, max(max(titleWidth, detailWidth), max(cwdWidth, providerWidth)) + fixedWidth)
        }
        return Self(panelWidth: min(desired, AppStyles.Components.ArrangementPanel.maximumWidth))
    }

    static func statusText(_ status: ArrangementPaneStatus) -> String {
        switch status {
        case .agent(let line): line.label
        case .unavailable: LocalActionSpec.arrangementValueUnavailable.actionSpec.label
        }
    }

    private static func width(_ text: String?, font: NSFont) -> CGFloat {
        guard let text else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
