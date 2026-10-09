import AgentStudioCore
import AgentStudioInboxNotification
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Scroll Offset Preference Key

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Metrics extracted from onScrollGeometryChange (macOS 15+)
private struct ScrollOverflowMetrics: Equatable {
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
}

/// Applies onScrollGeometryChange on macOS 15+, falls back to GeometryReader on macOS 14.
private struct ScrollOverflowDetector: ViewModifier {
    let adapter: TabBarAdapter

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: ScrollOverflowMetrics.self) { geo in
                    ScrollOverflowMetrics(
                        contentWidth: geo.contentSize.width,
                        viewportWidth: geo.containerSize.width
                    )
                } action: { _, metrics in
                    adapter.contentWidth = metrics.contentWidth
                    adapter.viewportWidth = metrics.viewportWidth
                }
        } else {
            // macOS 14 fallback: measure viewport width on the ScrollView itself
            content
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { adapter.viewportWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in adapter.viewportWidth = w }
                    }
                )
        }
    }
}

/// Custom Ghostty-style tab bar with pill-shaped tabs
struct CustomTabBar: View {
    @Bindable var adapter: TabBarAdapter
    var onSelect: (UUID) -> Void
    var canDispatchCommand: ((AppCommand, UUID) -> Bool)?
    var onCommand: ((AppCommand, UUID) -> Void)?
    var onShowArrangements: ((UUID) -> Void)?
    var onTabFramesChanged: (([UUID: CGRect]) -> Void)?

    @State private var scrollOffset: CGFloat = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var scrollAreaFrame: CGRect = .zero
    @State private var isOverflowLeftHovered = false
    @State private var isOverflowRightHovered = false

    /// Maximum width a tab can grow to.
    private static let tabMaxWidth: CGFloat = 400

    /// Minimum width before overflow/scroll kicks in.
    private static let tabMinWidth: CGFloat = 220

    /// Spacing between tab pills.
    private static let tabSpacing: CGFloat = AppStyles.Shell.TabBar.tabPillSpacing

    /// Computed width for each tab pill based on available space.
    private var computedTabWidth: CGFloat {
        let count = CGFloat(max(1, adapter.tabs.count))
        let totalSpacing = (count - 1) * Self.tabSpacing
        let scrollInset = AppStyles.General.Spacing.loose * 2
        let available = max(0, scrollAreaFrame.width - totalSpacing - scrollInset)
        let perTab = available / count
        return min(Self.tabMaxWidth, max(Self.tabMinWidth, perTab))
    }

    /// Whether the left gradient fade should be visible (scrolled past the start)
    private var showLeftFade: Bool {
        guard adapter.isOverflowing else { return false }
        return hiddenTabExists(direction: .left)
    }

    private var showRightFade: Bool {
        guard adapter.isOverflowing else { return false }
        return hiddenTabExists(direction: .right)
    }

    private func hiddenTabExists(direction: TabBarOverflowScrollDirection) -> Bool {
        TabBarOverflowScrollTargetResolver.targetTabId(
            direction: direction,
            orderedTabIds: adapter.tabs.map(\.id),
            tabFrames: adapter.tabFrames,
            visibleFrame: scrollAreaFrame
        ) != nil
    }

    var body: some View {
        let chromeLayout = TabBarChromeLayoutPlan(isOverflowing: adapter.isOverflowing)

        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 0) {
                // MARK: - Scroll area with gradient overlays
                ZStack(alignment: .center) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppStyles.Shell.TabBar.tabPillSpacing) {
                                // Hidden anchor for scroll offset tracking
                                GeometryReader { innerGeo in
                                    Color.clear.preference(
                                        key: ScrollOffsetKey.self,
                                        value: innerGeo.frame(in: .named("scroll")).minX
                                    )
                                }
                                .frame(width: 0, height: 0)

                                ForEach(Array(adapter.tabs.enumerated()), id: \.element.id) { index, tab in
                                    TabPillView(
                                        tab: tab,
                                        index: index,
                                        isActive: tab.id == adapter.activeTabId,
                                        isDragging: adapter.draggingTabId == tab.id,
                                        dwellProgress: adapter.dwellTabId == tab.id ? adapter.dwellProgress : 0,
                                        tabWidth: computedTabWidth,
                                        showInsertBefore: adapter.dropTargetIndex == index
                                            && adapter.draggingTabId != tab.id,
                                        showInsertAfter: index == adapter.tabs.count - 1
                                            && adapter.dropTargetIndex == adapter.tabs.count,
                                        onSelect: { onSelect(tab.id) },
                                        inlineCloseAction: TabPillView.inlineCommandAction(
                                            command: .closeTab,
                                            canDispatchCommand: {
                                                canDispatchCommand?($0, tab.id) ?? false
                                            },
                                            onCommand: { command in
                                                onCommand?(command, tab.id)
                                            }
                                        ),
                                        canDispatchCommand: { canDispatchCommand?($0, tab.id) ?? false },
                                        onCommand: { command in onCommand?(command, tab.id) },
                                        onShowArrangements: { onShowArrangements?(tab.id) }
                                    )
                                    .id(tab.id)
                                    .background(frameReporter(for: tab.id))
                                }

                                // New tab button lives with the fixed left chrome controls.
                            }
                            .padding(.trailing, AppStyles.General.Spacing.loose)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ContentWidthKey.self,
                                        value: geo.size.width
                                    )
                                }
                            )
                        }
                        .coordinateSpace(name: "scroll")
                        .modifier(ScrollOverflowDetector(adapter: adapter))
                        .onPreferenceChange(ScrollOffsetKey.self) { offset in
                            scrollOffset = offset
                        }
                        .onPreferenceChange(ContentWidthKey.self) { width in
                            // macOS 14 fallback: onScrollGeometryChange sets this on macOS 15+
                            if adapter.viewportWidth == 0 || adapter.contentWidth == 0 {
                                adapter.contentWidth = width
                            }
                        }
                        .onChange(of: adapter.activeTabId) { _, newId in
                            if let newId {
                                withAnimation(.easeInOut(duration: AppStyles.General.Animation.standard)) {
                                    proxy.scrollTo(newId, anchor: .center)
                                }
                            }
                        }
                        .onAppear {
                            scrollProxy = proxy
                        }
                    }
                    .frame(height: AppStyles.Shell.TabBar.tabPillHeight, alignment: .center)

                    // Left gradient fade
                    if showLeftFade {
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [
                                    Color(nsColor: .windowBackgroundColor),
                                    Color(nsColor: .windowBackgroundColor).opacity(0),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 30)
                            Spacer()
                        }
                        .allowsHitTesting(false)
                    }

                    // Right gradient fade
                    if showRightFade {
                        HStack(spacing: 0) {
                            Spacer()
                            LinearGradient(
                                colors: [
                                    Color(nsColor: .windowBackgroundColor).opacity(0),
                                    Color(nsColor: .windowBackgroundColor),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 30)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .center)
                .background(
                    GeometryReader { geo in
                        let frame = geo.frame(in: .named("tabBar"))
                        Color.clear
                            .onAppear { scrollAreaFrame = frame }
                            .onChange(of: frame) { _, newFrame in scrollAreaFrame = newFrame }
                    }
                )

                if chromeLayout.showsTrailingControls {
                    HStack(spacing: 0) {
                        ForEach(Array(chromeLayout.trailingControls.enumerated()), id: \.offset) { _, control in
                            trailingChromeControl(control)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .center)
            .background(Color.clear)
            .coordinateSpace(name: "tabBar")
            .onAppear {
                adapter.availableWidth = geometry.size.width
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                adapter.availableWidth = newWidth
            }
        }
        .onChange(of: adapter.outputPublicationRevision, initial: true) { _, _ in
            adapter.visibleProjectionDidRender()
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func trailingChromeControl(_ control: TabBarChromeControl) -> some View {
        switch control {
        case .overflowLeft:
            Button {
                scrollToAdjacentTab(direction: .left)
            } label: {
                ChromeToolbarButtonLabel(
                    symbolName: "chevron.left",
                    isHovered: isOverflowLeftHovered,
                    buttonSize: AppStyles.Shell.Chrome.PlainToolbarIcon.buttonSize,
                    showsBackground: false
                )
            }
            .buttonStyle(.plain)
            .padding(.trailing, AppStyles.Shell.Chrome.plainToolbarIconSpacing)
            .onHover { isOverflowLeftHovered = $0 }
        case .overflowRight:
            Button {
                scrollToAdjacentTab(direction: .right)
            } label: {
                ChromeToolbarButtonLabel(
                    symbolName: "chevron.right",
                    isHovered: isOverflowRightHovered,
                    buttonSize: AppStyles.Shell.Chrome.PlainToolbarIcon.buttonSize,
                    showsBackground: false
                )
            }
            .buttonStyle(.plain)
            .padding(.trailing, AppStyles.Shell.Chrome.plainToolbarIconSpacing)
            .onHover { isOverflowRightHovered = $0 }
        case .tabStrip:
            EmptyView()
        }
    }

    // MARK: - Scroll Navigation

    private enum ScrollDirection {
        case left, right
    }

    /// Scrolls to the next partially-hidden tab in the given direction.
    /// Uses actual tab frames from the adapter for accurate targeting.
    private func scrollToAdjacentTab(direction: ScrollDirection) {
        guard let proxy = scrollProxy else { return }
        let scrollDirection: TabBarOverflowScrollDirection =
            switch direction {
            case .left: .left
            case .right: .right
            }
        let orderedTabIds = adapter.tabs.map(\.id)
        guard
            let targetId = TabBarOverflowScrollTargetResolver.targetTabId(
                direction: scrollDirection,
                orderedTabIds: orderedTabIds,
                tabFrames: adapter.tabFrames,
                visibleFrame: scrollAreaFrame
            )
        else {
            return
        }

        let anchor: UnitPoint = direction == .left ? .leading : .trailing
        withAnimation(.easeInOut(duration: AppStyles.General.Animation.standard)) {
            proxy.scrollTo(targetId, anchor: anchor)
        }
    }

    // MARK: - Frame Reporter

    private func frameReporter(for tabId: UUID) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    let frame = geo.frame(in: .named("tabBar"))
                    // Update TabBarAdapter directly - more reliable than callback which may have timing issues
                    Task { @MainActor in
                        self.adapter.tabFrames[tabId] = frame
                    }
                    onTabFramesChanged?([tabId: frame])
                }
                .onChange(of: geo.frame(in: .named("tabBar"))) { _, frame in
                    Task { @MainActor in
                        self.adapter.tabFrames[tabId] = frame
                    }
                    onTabFramesChanged?([tabId: frame])
                }
        }
    }
}

struct TabBarArrangementButton: View {
    @Bindable var adapter: TabBarAdapter
    @Bindable var arrangementInlineRenameState: ArrangementInlineRenameState
    let octiconLoader: OcticonLoader
    let commandDispatcher: any AppCommandDispatching
    let onCommand: ((AppCommand, UUID) -> Void)?
    let onPaneAction: ((WorkspaceActionCommand) -> Void)?
    let workspaceWindowId: UUID?

    @State private var presentationState = ArrangementPanelTabPresentationState()
    @State private var isHovered = false
    @State private var popoverToggleGate = PopoverToggleGate()

    private var activeTab: TabBarItem? {
        guard let activeId = adapter.activeTabId else { return nil }
        return adapter.tabs.first { $0.id == activeId }
    }

    private var hiddenMinimizedCount: Int {
        guard !atom(\.managementLayer).isActive else { return 0 }
        return activeTab?.minimizedCount ?? 0
    }

    private var activeArrangementBadgeNumber: Int? {
        activeTab?.activeArrangementBadgeNumber
    }

    private var activeArrangementName: String? {
        activeTab?.activeArrangementName
    }

    private var chipNameMaxWidth: CGFloat {
        TabBarArrangementChip.nameMaxWidth(isManagementLayerActive: atom(\.managementLayer).isActive)
    }

    private var presentationAtom: ArrangementPanelPresentationAtom {
        atom(\.arrangementPanelPresentation)
    }

    var body: some View {
        Button {
            var isPresented = presentationState.isPresented
            popoverToggleGate.toggle(isPresented: &isPresented)
            presentationState.setPresented(isPresented, activeTabId: adapter.activeTabId)
        } label: {
            TabBarArrangementChip(
                index: activeArrangementBadgeNumber,
                name: activeArrangementName,
                isHovered: isHovered,
                isPressed: presentationState.isPresented,
                nameMaxWidth: chipNameMaxWidth,
                octiconLoader: octiconLoader
            )
            .overlay(alignment: .topTrailing) {
                if hiddenMinimizedCount > 0 {
                    Text("\(hiddenMinimizedCount)")
                        .font(.system(size: AppStyles.General.Typography.textXs, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppStyles.General.Spacing.tight)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(AppStyles.General.Fill.hover))
                        )
                        .fixedSize()
                        .offset(x: 10, y: -6)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeOut(duration: AppStyles.General.Animation.fast), value: hiddenMinimizedCount)
            .animation(.easeOut(duration: AppStyles.General.Animation.fast), value: activeArrangementName)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .help(LocalActionSpec.arrangements.actionSpec.helpText)
        .popover(
            isPresented: Binding(
                get: { presentationState.isPresented },
                set: { newValue in
                    if !newValue && presentationState.isPresented {
                        presentationState.setPresented(false, activeTabId: adapter.activeTabId)
                        popoverToggleGate.recordSystemDismissal()
                    } else {
                        presentationState.setPresented(newValue, activeTabId: adapter.activeTabId)
                    }
                }
            ),
            attachmentAnchor: ArrangementPanelPopoverPlacement.tabBar.attachmentAnchor,
            arrowEdge: ArrangementPanelPopoverPlacement.tabBar.arrowEdge
        ) {
            if let tab = activeTab, let onPaneAction {
                ArrangementPanel(
                    tabId: tab.id,
                    workspaceWindowId: workspaceWindowId,
                    octiconLoader: octiconLoader,
                    panes: tab.panes,
                    zoomMode: tab.zoomMode,
                    arrangements: tab.arrangements,
                    inlineRenameState: arrangementInlineRenameState,
                    commandActionResolver: { [commandDispatcher] command, surface, target, targetType in
                        TargetedCommandControlAction.resolve(
                            command: command,
                            surface: surface,
                            target: target,
                            targetType: targetType,
                            dispatcher: commandDispatcher
                        )
                    },
                    onPaneAction: onPaneAction,
                    onDismiss: dismissArrangementPopover
                )
            }
        }
        .onChange(of: arrangementInlineRenameState.editingArrangementId) { _, _ in
            openPopoverIfRenameTargetsActiveTab()
        }
        .onChange(of: adapter.activeTabId) { _, newTabId in
            presentationState.activeTabDidChange(to: newTabId)
            openPopoverIfRenameTargetsActiveTab()
            openPopoverIfRequested()
        }
        .onChange(of: presentationAtom.pendingRequest?.id) { _, _ in
            openPopoverIfRequested()
        }
    }

    private func dismissArrangementPopover() {
        guard presentationState.isPresented else { return }

        presentationState.setPresented(false, activeTabId: adapter.activeTabId)
        popoverToggleGate.recordSystemDismissal()
    }

    private func openPopoverIfRenameTargetsActiveTab() {
        guard
            ArrangementPopoverAutoOpen.shouldOpen(
                editingArrangementId: arrangementInlineRenameState.editingArrangementId,
                activeTabArrangements: activeTab?.arrangements,
                isPresented: presentationState.isPresented
            ),
            let activeTabId = adapter.activeTabId
        else { return }
        presentationState.present(tabId: activeTabId)
    }

    private func openPopoverIfRequested() {
        guard
            let request = presentationAtom.pendingRequest,
            let activeTabId = adapter.activeTabId,
            let workspaceWindowId,
            request.matches(tabId: activeTabId, workspaceWindowId: workspaceWindowId, placement: .tabBar)
        else { return }

        presentationState.present(tabId: request.tabId)
        presentationAtom.consume(request)
    }
}

/// Individual pill-shaped tab
struct TabPillView: View {
    let tab: TabBarItem
    let index: Int
    let isActive: Bool
    let isDragging: Bool
    let dwellProgress: CGFloat
    let tabWidth: CGFloat
    let showInsertBefore: Bool
    let showInsertAfter: Bool
    let onSelect: () -> Void
    let inlineCloseAction: TargetedCommandControlAction?
    let canDispatchCommand: (AppCommand) -> Bool
    let onCommand: (AppCommand) -> Void
    let onShowArrangements: () -> Void
    @State private var isHovering = false

    /// Clear zone in the mask for the close button (button frame + buffer).
    private static let closeButtonClearWidth: CGFloat = 20
    /// Clear zone in the mask for the ⌘N shortcut label.
    private static let shortcutLabelClearWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            // Insert line BEFORE
            if showInsertBefore {
                insertionLine
            }

            // Tab content
            tabContent
                .scaleEffect(isDragging ? 1.05 : 1.0)
                .opacity(isDragging ? 0.6 : 1.0)

            // Insert line AFTER (only for last tab)
            if showInsertAfter {
                insertionLine
            }
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDragging)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: showInsertBefore)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: showInsertAfter)
    }

    static func inlineCommandAction(
        command: AppCommand,
        canDispatchCommand: @escaping (AppCommand) -> Bool,
        onCommand: @escaping (AppCommand) -> Void
    ) -> TargetedCommandControlAction? {
        let commandSpec = command.definition
        guard
            commandSpec.shouldPresent(
                AppCommandPresentationQuery(
                    surface: .inlineControl,
                    subject: .targeted(.tab)
                )
            )
        else {
            return nil
        }

        return TargetedCommandControlAction(
            commandSpec: commandSpec,
            isEnabled: canDispatchCommand(command),
            perform: {
                guard canDispatchCommand(command) else { return }
                onCommand(command)
            }
        )
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(AppStyles.General.Accent.primaryColor)
            .frame(width: 2, height: 24)
            .padding(.horizontal, 2)
    }

    private var tabContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.pill)
                .fill(AppStyles.General.Accent.primaryColor.opacity(0.30 * dwellProgress))

            // Centered title with fade-out mask.
            // Clear zones match the overlay positions so text is fully invisible
            // behind the shortcut label and close button.
            Text(tab.displayTitle)
                .font(.system(size: AppStyles.General.Typography.textBase))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .mask(
                    HStack(spacing: 0) {
                        // Left: clear zone for close button + fade-in gradient
                        if isHovering {
                            Color.clear.frame(width: Self.closeButtonClearWidth)
                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: AppStyles.Shell.PaneChrome.maskFadeWidth)
                        } else {
                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: AppStyles.General.Spacing.loose)
                        }

                        Color.black

                        // Right: fade-out gradient + clear zone for shortcut label
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: AppStyles.Shell.PaneChrome.maskFadeWidth)
                        if index < 9 {
                            Color.clear.frame(width: Self.shortcutLabelClearWidth)
                        }
                    }
                )

            // Close (left) and shortcut (right) overlay
            HStack(spacing: 0) {
                if isHovering, let inlineCloseAction {
                    Button(action: inlineCloseAction.perform) {
                        Image(systemName: "xmark")
                            .font(.system(size: AppStyles.General.Typography.textXs, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(AppStyles.General.Fill.pressed))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!inlineCloseAction.isEnabled)
                    .transition(.opacity)
                }

                Spacer()

                if let notificationDotColor = tab.notificationDotColor {
                    Circle()
                        .fill(notificationDotColor.swiftUIColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(notificationDotColor.accessibilityLabel)
                        .padding(.trailing, AppStyles.General.Spacing.tight)
                }

                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: AppStyles.General.Typography.textSm, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, AppStyles.General.Spacing.standard)
        .padding(.vertical, AppStyles.General.Spacing.standard)
        .frame(width: tabWidth, height: AppStyles.Shell.TabBar.tabPillHeight)
        .background(
            RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.pill)
                .fill(backgroundColor)
        )
        .overlay(alignment: .top) {
            if let tabColor {
                Capsule()
                    .fill(tabColor)
                    .frame(height: 2)
                    .padding(.horizontal, AppStyles.General.Spacing.loose)
                    .padding(.top, 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.pill))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var backgroundColor: Color {
        if isActive { return Color.white.opacity(AppStyles.General.Fill.active) }
        if isHovering { return Color.white.opacity(AppStyles.General.Fill.hover) }
        return Color.white.opacity(AppStyles.General.Fill.subtle)
    }

    private var tabColor: Color? {
        guard let colorHex = tab.colorHex, let nsColor = NSColor(hex: colorHex) else { return nil }
        return Color(nsColor: nsColor)
    }
}

extension TabNotificationDotColor {
    fileprivate var swiftUIColor: Color {
        switch self {
        case .red:
            .red
        case .amber:
            .orange
        case .yellow:
            .yellow
        }
    }

    fileprivate var accessibilityLabel: String {
        switch self {
        case .red:
            "Tab has action notifications"
        case .amber:
            "Tab has safety notifications"
        case .yellow:
            "Tab has settled agent attention"
        }
    }
}

/// Empty state shown when no tabs are open
struct TabBarEmptyState: View {
    var onAddTab: () -> Void

    var body: some View {
        HStack {
            Text("No terminals open")
                .font(.system(size: AppStyles.General.Typography.textBase))
                .foregroundStyle(.secondary)

            Button(action: onAddTab) {
                HStack(spacing: AppStyles.General.Spacing.tight) {
                    Image(systemName: "plus")
                    Text("New Tab")
                }
                .font(.system(size: AppStyles.General.Typography.textBase))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: AppStyles.Shell.TabBar.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Preview

#if DEBUG
    struct CustomTabBar_Previews: PreviewProvider {
        static var previews: some View {
            let atomRegistry = AtomRegistry()
            let store = WorkspaceStore(
                identityAtom: atomRegistry.core.workspaceIdentity,
                windowMemoryAtom: atomRegistry.core.workspaceWindowMemory,
                repositoryTopologyAtom: atomRegistry.core.workspaceRepositoryTopology,
                paneAtom: atomRegistry.core.workspacePane,
                tabLayoutAtom: atomRegistry.core.workspaceTabLayout,
                mutationCoordinator: atomRegistry.core.workspaceMutationCoordinator
            )
            let adapter = TabBarAdapter(
                store: store,
                repoCache: RepoCacheAtom()
            )

            return VStack(spacing: 0) {
                CustomTabBar(
                    adapter: adapter,
                    onSelect: { _ in },
                    canDispatchCommand: { _, _ in true },
                    onCommand: { _, _ in },
                    onShowArrangements: { _ in }
                )

                Spacer()
            }
            .frame(width: 600, height: 400)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
#endif
