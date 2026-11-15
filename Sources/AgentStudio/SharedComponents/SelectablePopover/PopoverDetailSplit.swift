import AgentStudioInfrastructure
import SwiftUI

/// One popover window keeps its primary column and adds a shared scrollable reading pane.
package struct PopoverDetailSplit<Main: View, Detail: View, Close: View>: View {
    private let isPresented: Bool
    private let title: String
    private let width: CGFloat
    private let maximumHeight: CGFloat
    private let identifier: String
    private let onExit: @MainActor () -> Void
    private let main: Main
    private let detail: Detail
    private let close: Close
    @State private var mainHeight: CGFloat = 0
    @FocusState private var readingPaneIsFocused: Bool

    package init(
        isPresented: Bool, title: String, width: CGFloat, maximumHeight: CGFloat, identifier: String,
        onExit: @escaping @MainActor () -> Void,
        @ViewBuilder main: () -> Main,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder close: () -> Close
    ) {
        self.isPresented = isPresented
        self.title = title
        self.width = width
        self.maximumHeight = maximumHeight
        self.identifier = identifier
        self.onExit = onExit
        self.main = main()
        self.detail = detail()
        self.close = close()
    }

    private var header: some View {
        HStack(spacing: AppStyles.General.Spacing.standard) {
            Text(title).font(.system(size: AppStyles.General.Typography.textBase, weight: .semibold))
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                .background {
                    AccessibilityLabelBridge(identifier: identifier + ".title", label: title, role: .staticText)
                }
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            close
        }
    }

    package var body: some View {
        HStack(alignment: .top, spacing: 0) {
            main.onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                mainHeight = $0
            }
            if isPresented, mainHeight > 0 {
                PopoverPanel(
                    width: width, height: .contentSized(maximumHeight: min(maximumHeight, mainHeight)),
                    identifier: identifier
                ) {
                    header
                } content: {
                    detail
                }
                .frame(height: mainHeight, alignment: .top)
                .overlay(alignment: .leading) { Divider() }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .background(AppStyles.General.PopoverSurface.material)
        .background(AppStyles.General.PopoverSurface.content)
        .focusable(isPresented)
        .focused($readingPaneIsFocused)
        .focusEffectDisabled()
        .onChange(of: isPresented) { _, isPresented in readingPaneIsFocused = isPresented }
        .onExitCommand(perform: onExit)
        .background { AccessibilityLabelBridge(identifier: identifier + ".split", label: title, role: .group) }
    }
}
