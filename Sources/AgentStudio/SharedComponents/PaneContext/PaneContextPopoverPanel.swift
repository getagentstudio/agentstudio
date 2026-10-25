import AgentStudioInfrastructure
import SwiftUI

/// The content grows to its cap; only the rows scroll and the footer stays reachable.
package struct PaneContextPopoverPanel<Content: View, Footer: View>: View {
    private let content: Content
    private let footer: Footer
    @State private var rowsHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    package init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.footer = footer()
    }
    package var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.Components.PopoverPanel.sectionSpacing) {
            ScrollView {
                rows.onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    rowsHeight = $0
                }
            }
            .frame(height: visibleRowsHeight)
            footer.onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                footerHeight = $0
            }
        }
        .padding(AppStyles.Components.PopoverPanel.contentPadding)
        .frame(width: AppStyles.Components.PaneContext.popoverWidth)
        .frame(maxHeight: AppStyles.Components.PaneContext.popoverMaximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            AccessibilityLabelBridge(identifier: "pane-context.popover-panel", label: "", role: .group)
        }
    }
    private var visibleRowsHeight: CGFloat {
        min(
            rowsHeight,
            max(
                0,
                AppStyles.Components.PaneContext.popoverMaximumHeight
                    - 2 * AppStyles.Components.PopoverPanel.contentPadding
                    - AppStyles.Components.PopoverPanel.sectionSpacing - footerHeight))
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: AppStyles.Components.PopoverPanel.sectionSpacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

package struct PaneContextDatedText: View {
    private let text: AttributedString
    private let identifier: String?
    package init(body: String, explanation: String? = nil, age: AgeTextModel, identifier: String? = nil) {
        self.identifier = identifier
        var text = AttributedString(body)
        if let explanation {
            var explanationText = AttributedString("\n" + explanation)
            explanationText.foregroundColor = .secondary
            text.append(explanationText)
        }
        var ageText = AttributedString(" " + age.text)
        ageText.foregroundColor = .secondary
        text.append(ageText)
        self.text = text
    }
    package var body: some View {
        Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).background {
            if let identifier {
                AccessibilityLabelBridge(identifier: identifier, label: String(text.characters), role: .staticText)
            }
        }
    }
}

struct PaneContextRowGlyph: View {
    let icon: PaneContextControlModel.Icon
    let style: SidebarChip.Style
    let octiconLoader: OcticonLoader
    var body: some View {
        switch icon {
        case .system(let symbol): Image(systemName: symbol).foregroundStyle(style.foreground)
        case .octicon(let symbol):
            OcticonImage(name: symbol, size: AppStyles.General.Icon.compact, loader: octiconLoader)
                .foregroundStyle(style.foreground)
        }
    }
}

package struct PaneContextPopoverNote: View {
    private let text: String
    package init(_ text: String) { self.text = text }
    package var body: some View {
        Text(text).foregroundStyle(.secondary).background {
            AccessibilityLabelBridge(identifier: "pane-context.feedback", label: text, role: .staticText)
        }
    }
}
