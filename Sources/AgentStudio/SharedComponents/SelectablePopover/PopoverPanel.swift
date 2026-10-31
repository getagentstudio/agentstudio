import AgentStudioInfrastructure
import SwiftUI

/// Shared scrolling shell; each appearance keeps the height of its first prepared layout.
package struct PopoverPanel<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header?
    private let footer: Footer?
    private let width: CGFloat?
    private let height: PopoverPanelHeight
    private let contentSpacing: CGFloat
    private let centersContent: Bool
    private struct RegionGeometry: Equatable {
        let height: CGFloat
        let opening: UInt64
        let openingContentIsReady: Bool
    }
    private let openingContentIsReady: Bool
    private let separatesFooter: Bool
    private let identifier: String?
    private let onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)?
    @State private var rowsGeometry: RegionGeometry?
    @State private var headerGeometry: RegionGeometry?
    @State private var footerGeometry: RegionGeometry?
    @State private var rowsAreScrolled = false
    @State private var openingHeight: CGFloat?
    @State private var openingSequence: UInt64 = 0
    @State private var isMounted = false

    private var rowsHeight: CGFloat { rowsGeometry?.height ?? 0 }
    private var headerHeight: CGFloat { headerGeometry?.height ?? 0 }
    private var footerHeight: CGFloat { footerGeometry?.height ?? 0 }

    private init(
        content: Content, header: Header?, footer: Footer?, width: CGFloat?, height: PopoverPanelHeight,
        contentSpacing: CGFloat, separatesFooter: Bool, identifier: String?,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)?,
        openingContentIsReady: Bool = true, centersContent: Bool = false
    ) {
        self.content = content
        self.header = header
        self.footer = footer
        self.width = width
        self.height = height
        self.contentSpacing = contentSpacing
        self.centersContent = centersContent
        self.openingContentIsReady = openingContentIsReady
        self.separatesFooter = separatesFooter
        self.identifier = identifier
        self.onHeightWrite = onHeightWrite
    }

    package init(
        width: CGFloat, height: PopoverPanelHeight,
        contentSpacing: CGFloat = AppStyles.Components.PopoverPanel.sectionSpacing,
        separatesFooter: Bool = true, identifier: String? = nil,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil,
        openingContentIsReady: Bool = true, centersContent: Bool = false,
        @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.init(
            content: content(), header: header(), footer: footer(), width: width, height: height,
            contentSpacing: contentSpacing, separatesFooter: separatesFooter, identifier: identifier,
            onHeightWrite: onHeightWrite,
            openingContentIsReady: openingContentIsReady, centersContent: centersContent)
    }

    package var body: some View {
        pinnedContent(maximumHeight: height.maximumHeight ?? .infinity)
            .background(AppStyles.General.PopoverSurface.material)
            .background(AppStyles.General.PopoverSurface.content)
            .onAppear {
                openingSequence &+= 1
                isMounted = true
                openingHeight = nil
            }
            .onDisappear {
                isMounted = false
                openingHeight = nil
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
                .onGeometryChange(for: RegionGeometry.self) {
                    .init(height: $0.size.height, opening: openingSequence, openingContentIsReady: true)
                } action: { capture in
                    guard capture.opening == openingSequence else { return }
                    let previous = headerGeometry?.height
                    headerGeometry = capture
                    captureOpeningHeight(maximumHeight: maximumHeight)
                    if previous != capture.height { onHeightWrite?(.init(region: .header, height: capture.height)) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: contentSpacing) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppStyles.Components.PopoverPanel.contentPadding)
                    .padding(.top, topContentInset)
                    .padding(.bottom, bottomContentInset)
                    .frame(minHeight: centersContent ? visibleRowsHeight(maximumHeight: maximumHeight) : nil)
                    .onGeometryChange(for: RegionGeometry.self) {
                        .init(
                            height: $0.size.height, opening: openingSequence,
                            openingContentIsReady: openingContentIsReady)
                    } action: { capture in
                        guard capture.opening == openingSequence else { return }
                        let previous = rowsGeometry?.height
                        rowsGeometry = capture
                        captureOpeningHeight(maximumHeight: maximumHeight)
                        if previous != capture.height { onHeightWrite?(.init(region: .rows, height: capture.height)) }
                    }
                    .background { PopoverScrollConfiguration().frame(width: 0, height: 0) }
            }
            .frame(height: visibleRowsHeight(maximumHeight: maximumHeight))
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
                .onGeometryChange(for: RegionGeometry.self) {
                    .init(height: $0.size.height, opening: openingSequence, openingContentIsReady: true)
                } action: { capture in
                    guard capture.opening == openingSequence else { return }
                    let previous = footerGeometry?.height
                    footerGeometry = capture
                    captureOpeningHeight(maximumHeight: maximumHeight)
                    if previous != capture.height { onHeightWrite?(.init(region: .footer, height: capture.height)) }
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: maximumHeight)
        .frame(height: openingHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if let identifier { AccessibilityLabelBridge(identifier: identifier, label: "", role: .group) }
        }
    }

    // Centered content shares the existing inset on both sides of the viewport's midpoint.
    private var topContentInset: CGFloat {
        let inset = AppStyles.Components.PopoverPanel.contentPadding
        if header == nil { return inset }
        return centersContent ? inset / 2 : 0
    }

    private var bottomContentInset: CGFloat {
        let inset = AppStyles.Components.PopoverPanel.contentPadding
        return centersContent && header != nil ? inset / 2 : inset
    }

    private func visibleRowsHeight(maximumHeight: CGFloat) -> CGFloat {
        if let openingHeight { return max(0, openingHeight - headerHeight - footerHeight) }
        return min(rowsHeight, max(0, maximumHeight - headerHeight - footerHeight))
    }

    private func captureOpeningHeight(maximumHeight: CGFloat) {
        guard isMounted, openingHeight == nil, let rowsGeometry,
            rowsGeometry.opening == openingSequence, rowsGeometry.openingContentIsReady, rowsHeight > 0,
            header.map({ _ in headerGeometry?.opening == openingSequence && headerHeight > 0 }) ?? true,
            footer.map({ _ in footerGeometry?.opening == openingSequence && footerHeight > 0 }) ?? true
        else { return }
        switch height {
        case .fixed(let height): openingHeight = height
        case .contentSized: openingHeight = min(maximumHeight, headerHeight + rowsHeight + footerHeight)
        }
    }
}

extension PopoverPanel where Footer == EmptyView {
    package init(
        width: CGFloat, height: PopoverPanelHeight,
        contentSpacing: CGFloat = AppStyles.Components.PopoverPanel.sectionSpacing,
        identifier: String? = nil,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            content: content(), header: header(), footer: nil, width: width, height: height,
            contentSpacing: contentSpacing, separatesFooter: false, identifier: identifier, onHeightWrite: onHeightWrite
        )
    }
}

extension PopoverPanel where Header == EmptyView, Footer == EmptyView {
    package init(
        height: PopoverPanelHeight = .contentSized(maximumHeight: nil),
        openingContentIsReady: Bool = true, @ViewBuilder content: () -> Content
    ) {
        self.init(
            content: content(), header: nil, footer: nil, width: nil, height: height,
            contentSpacing: AppStyles.Components.PopoverPanel.sectionSpacing, separatesFooter: false,
            identifier: nil, onHeightWrite: nil, openingContentIsReady: openingContentIsReady)
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

    package var backgroundColor: Color {
        if isPressed { return Color.white.opacity(AppStyles.General.Fill.pressed) }
        if isSelected { return Color.white.opacity(AppStyles.General.Fill.active) }
        if isHighlighted { return Color.white.opacity(AppStyles.General.Fill.hover) }
        return Color.white.opacity(AppStyles.General.Fill.subtle)
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
                    .fill(isUnavailable ? Color.clear : visualStyle.backgroundColor)
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

extension PopoverPanel where Header == EmptyView {
    package init(
        width: CGFloat, height: PopoverPanelHeight, identifier: String? = nil,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.init(
            content: content(), header: nil, footer: footer(), width: width, height: height,
            contentSpacing: AppStyles.Components.PopoverPanel.sectionSpacing, separatesFooter: true,
            identifier: identifier, onHeightWrite: nil)
    }
}
