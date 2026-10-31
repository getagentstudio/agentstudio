import AgentStudioInfrastructure
import AppKit
import CoreText

/// Width measurement stays in the off-main projector; the view receives only its panel width.
package struct ArrangementTableMetrics: Equatable, Sendable {
    package let panelWidth: CGFloat
    package static let minimum = Self(panelWidth: AppStyles.Components.ArrangementPanel.minimumWidth)

    static func measuring(_ panes: [PaneVisibilityInfo]) -> Self {
        let titleFont = NSFont.systemFont(
            ofSize: AppStyles.Components.ArrangementPanel.titleFontSize, weight: .regular)
        let detailFont = NSFont.systemFont(ofSize: AppStyles.Components.ArrangementPanel.detailFontSize)
        let fixedWidth =
            2 * AppStyles.Components.PopoverPanel.contentPadding
            + 2 * AppStyles.Components.ArrangementPanel.rowHorizontalPadding
            + AppStyles.Components.ArrangementPanel.statusDotSize
            + AppStyles.Components.ArrangementPanel.kindGlyphFrameSize
            + AppStyles.Components.ArrangementPanel.actionsWidth
            + 3 * AppStyles.Components.ArrangementPanel.columnSpacing
        var desired = AppStyles.Components.ArrangementPanel.minimumWidth
        for pane in panes {
            let titleWidth =
                width(pane.title, font: titleFont) + width(pane.branchName, font: detailFont)
                + AppStyles.General.Spacing.standard
            let detailWidth: CGFloat
            switch pane.detailLine {
            case .agentLine(let line): detailWidth = width(line.accessibilityText, font: detailFont)
            case .note(let text): detailWidth = width(text, font: detailFont)
            case nil: detailWidth = 0
            }
            let chipsWidth = pane.messageChips.reduce(CGFloat.zero) { result, chip in
                result + width(String(chip.model.count), font: detailFont)
                    + AppStyles.Shell.Sidebar.branchIconSize + 2 * AppStyles.General.Spacing.tight
            }
            let providerWidth =
                width(pane.providerName, font: detailFont)
                + width(statusText(pane.agentStatus), font: detailFont) + chipsWidth + AppStyles.General.Spacing.loose
            desired = max(desired, max(titleWidth, max(detailWidth, providerWidth)) + fixedWidth)
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
