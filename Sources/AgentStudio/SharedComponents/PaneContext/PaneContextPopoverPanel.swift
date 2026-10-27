import AgentStudioInfrastructure
import SwiftUI

package enum PaneContextPopoverPanelAnchor: Hashable, Sendable { case top }

/// The content grows to its cap; only the rows scroll and the footer stays reachable.
package struct PaneContextPopoverPanel<Content: View, Footer: View>: View {
    private let content: Content
    private let footer: Footer
    private let width: CGFloat
    private let contentSpacing: CGFloat
    private let separatesFooter: Bool
    @State private var rowsHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    package init(
        width: CGFloat = AppStyles.Components.PaneContext.popoverWidth,
        contentSpacing: CGFloat = AppStyles.Components.PopoverPanel.sectionSpacing,
        separatesFooter: Bool = false,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.width = width
        self.contentSpacing = contentSpacing
        self.separatesFooter = separatesFooter
        self.content = content()
        self.footer = footer()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: separatesFooter ? 0 : AppStyles.Components.PopoverPanel.sectionSpacing) {
            ScrollView {
                rows.onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    rowsHeight = $0
                }
            }
            .frame(height: visibleRowsHeight)
            .padding(.horizontal, AppStyles.Components.PopoverPanel.contentPadding)
            .padding(.top, AppStyles.Components.PopoverPanel.contentPadding)
            .padding(.bottom, separatesFooter ? AppStyles.Components.PopoverPanel.contentPadding : 0)
            footerContent.onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                footerHeight = $0
            }
        }
        .frame(width: width)
        .frame(maxHeight: AppStyles.Components.PaneContext.popoverMaximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            AccessibilityLabelBridge(identifier: "pane-context.popover-panel", label: "", role: .group)
        }
    }

    private var footerContent: some View {
        VStack(spacing: 0) {
            if separatesFooter { Divider() }
            footer
                .padding(
                    .horizontal,
                    separatesFooter
                        ? AppStyles.General.Spacing.standard : AppStyles.Components.PopoverPanel.contentPadding
                )
                .padding(.vertical, separatesFooter ? AppStyles.General.Spacing.standard : 0)
                .padding(.bottom, separatesFooter ? 0 : AppStyles.Components.PopoverPanel.contentPadding)
        }
    }

    private var visibleRowsHeight: CGFloat {
        let contentInsets = AppStyles.Components.PopoverPanel.contentPadding * (separatesFooter ? 2 : 1)
        let footerSpacing = separatesFooter ? 0 : AppStyles.Components.PopoverPanel.sectionSpacing
        return min(
            rowsHeight,
            max(0, AppStyles.Components.PaneContext.popoverMaximumHeight - contentInsets - footerSpacing - footerHeight)
        )
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: contentSpacing) { content }
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

package struct PaneContextPopoverNote: View {
    private let text: String
    package init(_ text: String) { self.text = text }
    package var body: some View {
        Text(text).foregroundStyle(.secondary).background {
            AccessibilityLabelBridge(identifier: "pane-context.feedback", label: text, role: .staticText)
        }
    }
}
