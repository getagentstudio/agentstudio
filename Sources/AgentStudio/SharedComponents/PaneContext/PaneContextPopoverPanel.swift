import AgentStudioInfrastructure
import SwiftUI

package enum PaneContextPopoverPanelAnchor: Hashable, Sendable { case top }

package struct PaneContextPopoverHeightWrite: Equatable, Sendable {
    package enum Region: Equatable, Sendable { case header, rows, footer }
    package let region: Region
    package let height: CGFloat
}

/// The content grows to its cap while title and footer remain outside the scrolling rows.
package struct PaneContextPopoverPanel<Header: View, Content: View, Footer: View>: View {
    private let header: Header?
    private let content: Content
    private let footer: Footer
    private let width: CGFloat
    private let contentSpacing: CGFloat
    private let separatesFooter: Bool
    private let onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)?
    @State private var rowsHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var rowsAreScrolled = false

    package init(
        width: CGFloat = AppStyles.Components.PaneContext.popoverWidth,
        contentSpacing: CGFloat = AppStyles.Components.PopoverPanel.sectionSpacing,
        separatesFooter: Bool = false,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil,
        @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.init(
            width: width, contentSpacing: contentSpacing, separatesFooter: separatesFooter,
            onHeightWrite: onHeightWrite,
            header: header(), content: content(), footer: footer())
    }

    private init(
        width: CGFloat, contentSpacing: CGFloat, separatesFooter: Bool,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)?,
        header: Header?, content: Content, footer: Footer
    ) {
        self.header = header
        self.width = width
        self.contentSpacing = contentSpacing
        self.separatesFooter = separatesFooter
        self.onHeightWrite = onHeightWrite
        self.content = content
        self.footer = footer
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: separatesFooter ? 0 : AppStyles.Components.PopoverPanel.sectionSpacing) {
            if let header {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppStyles.Components.PopoverPanel.contentPadding)
                    Divider().opacity(rowsAreScrolled ? 1 : 0)
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    headerHeight = $0
                    onHeightWrite?(.init(region: .header, height: $0))
                }
            }
            scrollableRows
            footerContent.onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                footerHeight = $0
                onHeightWrite?(.init(region: .footer, height: $0))
            }
        }
        .frame(width: width)
        .frame(maxHeight: AppStyles.Components.PaneContext.popoverMaximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            AccessibilityLabelBridge(identifier: "pane-context.popover-panel", label: "", role: .group)
        }
    }

    @ViewBuilder private var scrollableRows: some View {
        if header != nil {
            rowsScrollView.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > 0
            } action: { _, scrolled in
                rowsAreScrolled = scrolled
            }
        } else {
            rowsScrollView
        }
    }

    private var rowsScrollView: some View {
        ScrollView {
            rows.onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                rowsHeight = $0
                onHeightWrite?(.init(region: .rows, height: $0))
            }
        }
        .frame(height: visibleRowsHeight)
        .padding(.horizontal, AppStyles.Components.PopoverPanel.contentPadding)
        .padding(.top, AppStyles.Components.PopoverPanel.contentPadding)
        .padding(.bottom, separatesFooter ? AppStyles.Components.PopoverPanel.contentPadding : 0)
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
            max(
                0,
                AppStyles.Components.PaneContext.popoverMaximumHeight - headerHeight - contentInsets - footerSpacing
                    - footerHeight)
        )
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: contentSpacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PaneContextPopoverPanel where Header == EmptyView {
    package init(
        width: CGFloat = AppStyles.Components.PaneContext.popoverWidth,
        contentSpacing: CGFloat = AppStyles.Components.PopoverPanel.sectionSpacing,
        separatesFooter: Bool = false,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.init(
            width: width, contentSpacing: contentSpacing, separatesFooter: separatesFooter,
            onHeightWrite: onHeightWrite,
            header: nil, content: content(), footer: footer())
    }
}

package struct PaneContextDatedText: View {
    private let text: AttributedString
    private let identifier: String?
    private let application: AccessibilityLabelApplication?
    package init(
        body: String, explanation: String? = nil, age: AgeTextModel, identifier: String? = nil,
        application: AccessibilityLabelApplication? = nil
    ) {
        self.identifier = identifier
        self.application = application
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
                AccessibilityLabelBridge(
                    identifier: identifier, label: String(text.characters), role: .staticText, application: application)
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
