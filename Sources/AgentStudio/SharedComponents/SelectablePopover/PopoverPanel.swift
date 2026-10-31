import AgentStudioInfrastructure
import SwiftUI

/// One inset rule for simple popovers and for content between pinned header/footer slots.
package struct PopoverPanel<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header?
    private let footer: Footer?
    private let width: CGFloat?
    private let maximumHeight: CGFloat?
    private let contentSpacing: CGFloat
    private let separatesFooter: Bool
    private let identifier: String?
    private let onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)?
    @State private var rowsHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var rowsAreScrolled = false

    private init(
        content: Content, header: Header?, footer: Footer?, width: CGFloat?, maximumHeight: CGFloat?,
        contentSpacing: CGFloat, separatesFooter: Bool, identifier: String?,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)?
    ) {
        self.content = content
        self.header = header
        self.footer = footer
        self.width = width
        self.maximumHeight = maximumHeight
        self.contentSpacing = contentSpacing
        self.separatesFooter = separatesFooter
        self.identifier = identifier
        self.onHeightWrite = onHeightWrite
    }

    package init(
        width: CGFloat, maximumHeight: CGFloat,
        contentSpacing: CGFloat = AppStyles.Components.PopoverPanel.sectionSpacing,
        separatesFooter: Bool = true, identifier: String? = nil,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil,
        @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.init(
            content: content(), header: header(), footer: footer(), width: width, maximumHeight: maximumHeight,
            contentSpacing: contentSpacing, separatesFooter: separatesFooter, identifier: identifier,
            onHeightWrite: onHeightWrite)
    }

    package var body: some View {
        if let maximumHeight {
            pinnedContent(maximumHeight: maximumHeight)
        } else {
            VStack(alignment: .leading, spacing: AppStyles.Components.PopoverPanel.sectionSpacing) { content }
                .padding(AppStyles.Components.PopoverPanel.contentPadding)
        }
    }

    private func pinnedContent(maximumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                VStack(spacing: 0) {
                    header.frame(maxWidth: .infinity, alignment: .leading)
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
            ScrollView {
                VStack(alignment: .leading, spacing: contentSpacing) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppStyles.Components.PopoverPanel.contentPadding)
                    // The header already supplies the shared vertical inset.
                    .padding(.top, header == nil ? AppStyles.Components.PopoverPanel.contentPadding : 0)
                    .padding(.bottom, AppStyles.Components.PopoverPanel.contentPadding)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        rowsHeight = $0
                        onHeightWrite?(.init(region: .rows, height: $0))
                    }
            }
            .frame(height: min(rowsHeight, max(0, maximumHeight - headerHeight - footerHeight)))
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentOffset.y > 0
            } action: { _, scrolled in
                rowsAreScrolled = scrolled
            }
            if let footer {
                VStack(spacing: 0) {
                    if separatesFooter { Divider() }
                    footer.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppStyles.Components.PopoverPanel.contentPadding)
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    footerHeight = $0
                    onHeightWrite?(.init(region: .footer, height: $0))
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if let identifier { AccessibilityLabelBridge(identifier: identifier, label: "", role: .group) }
        }
    }
}

extension PopoverPanel where Footer == EmptyView {
    package init(
        width: CGFloat, maximumHeight: CGFloat,
        contentSpacing: CGFloat = AppStyles.Components.PopoverPanel.sectionSpacing,
        identifier: String? = nil,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            content: content(), header: header(), footer: nil, width: width, maximumHeight: maximumHeight,
            contentSpacing: contentSpacing, separatesFooter: false, identifier: identifier, onHeightWrite: onHeightWrite
        )
    }
}

extension PopoverPanel where Header == EmptyView, Footer == EmptyView {
    package init(@ViewBuilder content: () -> Content) {
        self.init(
            content: content(), header: nil, footer: nil, width: nil, maximumHeight: nil,
            contentSpacing: AppStyles.Components.PopoverPanel.sectionSpacing, separatesFooter: false,
            identifier: nil, onHeightWrite: nil)
    }
}

package struct PopoverOptionLabel<Icon: View>: View {
    private let title: String
    private let icon: Icon

    package init(_ title: String, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.icon = icon()
    }

    package var body: some View {
        HStack(spacing: AppStyles.General.Spacing.standard) {
            icon
                .frame(width: AppStyles.General.Icon.compact, height: AppStyles.General.Icon.compact)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

package struct PopoverOptionVisualStyle: Equatable {
    package let isSelected: Bool
    package let isHighlighted: Bool
    package let isPressed: Bool

    package init(isSelected: Bool, isHighlighted: Bool, isPressed: Bool) {
        self.isSelected = isSelected
        self.isHighlighted = isHighlighted
        self.isPressed = isPressed
    }

    package var backgroundOpacity: CGFloat {
        if isPressed { return AppStyles.General.Fill.pressed }
        if isSelected { return AppStyles.General.Fill.active }
        if isHighlighted { return AppStyles.General.Fill.hover }
        return AppStyles.General.Fill.subtle
    }

    package var foregroundIsPrimary: Bool {
        isSelected || isHighlighted || isPressed
    }
}

/// Also applies to compound controls such as an arrangement chip with a rename button.
package struct PopoverOptionSurface: ViewModifier {
    private let visualStyle: PopoverOptionVisualStyle
    private let isUnavailable: Bool

    package init(
        isSelected: Bool,
        isHighlighted: Bool,
        isPressed: Bool = false,
        isUnavailable: Bool = false
    ) {
        visualStyle = PopoverOptionVisualStyle(
            isSelected: isSelected, isHighlighted: isHighlighted, isPressed: isPressed
        )
        self.isUnavailable = isUnavailable
    }

    package func body(content: Content) -> some View {
        content
            .font(
                .system(
                    size: AppStyles.General.Typography.textXs, weight: visualStyle.isSelected ? .semibold : .regular)
            )
            .foregroundStyle(isUnavailable ? .tertiary : visualStyle.foregroundIsPrimary ? .primary : .secondary)
            .padding(.horizontal, AppStyles.General.Spacing.loose)
            .padding(.vertical, AppStyles.General.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.bar)
                    .fill(Color.white.opacity(isUnavailable ? 0 : visualStyle.backgroundOpacity))
            )
            .contentShape(Rectangle())
    }
}

package struct PopoverOptionButtonStyle: ButtonStyle {
    private let isSelected: Bool
    private let isHighlighted: Bool

    package init(isSelected: Bool, isHighlighted: Bool) {
        self.isSelected = isSelected
        self.isHighlighted = isHighlighted
    }

    package func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(
            PopoverOptionSurface(
                isSelected: isSelected,
                isHighlighted: isHighlighted,
                isPressed: configuration.isPressed
            )
        )
    }
}

/// Keeps one painted surface around multiple independently actionable buttons.
package struct PopoverCompoundOptionSurface: ViewModifier {
    private let isSelected: Bool
    private let isHighlighted: Bool
    @State private var isPressed = false

    package init(isSelected: Bool, isHighlighted: Bool) {
        self.isSelected = isSelected
        self.isHighlighted = isHighlighted
    }

    package func body(content: Content) -> some View {
        content
            .buttonStyle(PopoverPressReportingButtonStyle())
            .modifier(
                PopoverOptionSurface(
                    isSelected: isSelected, isHighlighted: isHighlighted, isPressed: isPressed
                )
            )
            .onPreferenceChange(PopoverPressedPreferenceKey.self) { isPressed = $0 }
    }
}

private struct PopoverPressReportingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.preference(key: PopoverPressedPreferenceKey.self, value: configuration.isPressed)
    }
}

private struct PopoverPressedPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        let nextPressed = nextValue()
        value = value || nextPressed
    }
}
