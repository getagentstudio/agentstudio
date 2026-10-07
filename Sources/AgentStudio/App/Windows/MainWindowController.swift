import AgentStudioBridge
import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import AgentStudioSharedComponents
import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Main window controller for AgentStudio
class MainWindowController: NSWindowController, NSWindowDelegate {
    private var splitViewController: MainSplitViewController?
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var awaitsLaunchRestoreResize = false
    private var awaitsLaunchMaximize = false
    private var hasShutdown = false
    private var applicationLifecycleMonitor: ApplicationLifecycleMonitor!
    private var workspaceWindowMemoryAtom: WorkspaceWindowMemoryAtom!
    private var windowId = UUID()

    var workspaceWindowId: UUID { windowId }
    var acceptsIPCCommands: Bool { !hasShutdown && window != nil }

    private static let estimatedTitlebarHeight: CGFloat = 40

    convenience init(
        workspaceWindowId: UUID = UUID(),
        store: WorkspaceStore,
        octiconLoader: OcticonLoader,
        workspaceActionExecutor: WorkspaceActionExecutor,
        runtimeCommandDispatcher: any PaneRuntimeCommandDispatching,
        applicationLifecycleMonitor: ApplicationLifecycleMonitor,
        appLifecycleStore: AppLifecycleAtom,
        tabBarAdapter: TabBarAdapter,
        viewRegistry: ViewRegistry,
        bridgePaneAttendance: BridgePaneAttendanceAtom,
        editorChooser: EditorChooserState,
        sessionsPaneViewedMailbox: SessionsPaneViewedMailbox? = nil,
        repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom,
        bridgeAttendanceSnapshot: @escaping BridgeAttendanceSnapshot,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        onSidebarVisibleWorktreesChanged: @escaping @MainActor @Sendable () -> Void = {},
        onPerformanceProofReadback:
            @escaping @MainActor @Sendable (RepoExplorerPerformanceProofReadback) -> Void = { _ in },
        onRepositoryFactUpdateProgressPresented:
            @escaping @MainActor @Sendable (UUID, UUID) -> Void = { _, _ in },
        closeTransitionCoordinator: PaneCloseTransitionCoordinator = PaneCloseTransitionCoordinator()
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentStudio"
        window.backgroundColor = AppStyles.Shell.TabBar.titlebarBackground
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovable = true
        window.isMovableByWindowBackground = false
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.isHidden = false
            window.standardWindowButton(buttonType)?.isEnabled = true
        }
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenDisallowsTiling)
        window.minSize = NSSize(width: 720, height: 600)
        window.isRestorable = false

        // Always launch maximized to the current screen (not full-screen mode)
        if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        } else {
            window.center()
        }

        self.init(window: window)
        self.windowId = workspaceWindowId
        self.applicationLifecycleMonitor = applicationLifecycleMonitor
        self.workspaceWindowMemoryAtom = store.windowMemoryAtom
        window.delegate = self
        applicationLifecycleMonitor.installFirstDisplayCommitScheduler { [weak window] completion in
            guard let window else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock(completion)
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
            CATransaction.commit()
        }
        applicationLifecycleMonitor.handleWindowRegistered(windowId)
        synchronizeWindowPresentationFacts()

        // Create and set content view controller
        let splitVC = MainSplitViewController(
            store: store,
            octiconLoader: octiconLoader,
            workspaceWindowId: windowId,
            workspaceActionExecutor: workspaceActionExecutor,
            runtimeCommandDispatcher: runtimeCommandDispatcher,
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            appLifecycleStore: appLifecycleStore,
            tabBarAdapter: tabBarAdapter,
            viewRegistry: viewRegistry,
            repoExplorerSidebarPrefs: repoExplorerSidebarPrefs,
            bridgeAttendanceSnapshot: bridgeAttendanceSnapshot,
            bridgePaneAttendance: bridgePaneAttendance,
            editorChooser: editorChooser,
            sessionsPaneViewedMailbox: sessionsPaneViewedMailbox,
            performanceTraceRecorder: performanceTraceRecorder,
            onSidebarVisibleWorktreesChanged: onSidebarVisibleWorktreesChanged,
            onPerformanceProofReadback: onPerformanceProofReadback,
            onRepositoryFactUpdateProgressPresented: onRepositoryFactUpdateProgressPresented,
            closeTransitionCoordinator: closeTransitionCoordinator
        )
        self.splitViewController = splitVC
        window.contentViewController = splitVC
        splitVC.loadViewIfNeeded()
        setupToolbar()

        // MainSplitViewController owns the pane content; the native toolbar owns
        // the single top line containing its composed tab/control surface.
    }

    // MARK: - NSWindowDelegate (frame persistence)

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
        guard awaitsLaunchRestoreResize else { return }
        awaitsLaunchRestoreResize = false
        window?.contentView?.layoutSubtreeIfNeeded()
        applicationLifecycleMonitor.handleLaunchLayoutSettled()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        applyLaunchMaximizeIfNeeded()
        synchronizeWindowPresentationFacts()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        applyLaunchMaximizeIfNeeded()
        applicationLifecycleMonitor.handleWindowDidBecomeKey(windowId)
        synchronizeWindowPresentationFacts()
    }

    func windowDidResignKey(_ notification: Notification) {
        splitViewController?.cancelHeldPanePreview()
        applicationLifecycleMonitor.handleWindowDidResignKey(windowId)
        synchronizeWindowPresentationFacts()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        synchronizeWindowPresentationFacts()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        synchronizeWindowPresentationFacts()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        synchronizeWindowPresentationFacts()
    }

    func windowWillClose(_ notification: Notification) {
        shutdown()
        guard let window else { return }
        applicationLifecycleMonitor.handleWindowPresentationChanged(
            windowId,
            isVisible: false,
            isMiniaturized: window.isMiniaturized,
            isOccluded: true
        )
    }

    func shutdown() {
        guard !hasShutdown else { return }
        hasShutdown = true
        splitViewController?.shutdown()
    }

    func makePaneFocusAppControl(store: WorkspaceStore) -> (any PaneFocusAppControlling)? {
        splitViewController?.loadViewIfNeeded()
        return splitViewController?.makePaneFocusAppControl(store: store)
    }

    private func saveWindowFrame() {
        guard let frame = window?.frame else { return }
        workspaceWindowMemoryAtom.setWindowFrame(frame)
    }

    private func synchronizeWindowPresentationFacts() {
        guard let window else { return }
        applicationLifecycleMonitor.handleWindowPresentationChanged(
            windowId,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isOccluded: !window.occlusionState.contains(.visible)
        )
    }

    // MARK: - Frame Validation

    /// Check if at least the titlebar region of the frame is visible on any connected screen.
    private static func isFrameOnScreen(_ frame: NSRect) -> Bool {
        guard !NSScreen.screens.isEmpty else { return false }
        let titleBarRect = NSRect(
            x: frame.origin.x, y: frame.maxY - estimatedTitlebarHeight,
            width: frame.width, height: estimatedTitlebarHeight
        )
        return NSScreen.screens.contains { $0.visibleFrame.intersects(titleBarRect) }
    }

    /// Shrink the window if it exceeds the current screen's visible area.
    private static func clampFrameToScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        var frame = window.frame
        var changed = false
        if frame.width > screenFrame.width {
            frame.size.width = screenFrame.width
            changed = true
        }
        if frame.height > screenFrame.height {
            frame.size.height = screenFrame.height
            changed = true
        }
        if changed {
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        toolbar.autosavesConfiguration = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unifiedCompact
        splitViewController?.updateWindowContentSafeArea()
        window?.contentView?.layoutSubtreeIfNeeded()
        refreshToolbarToggleState()
        observeToolbarPresentationState()
    }

    // MARK: - Actions

    func toggleSidebar() {
        splitViewController?.toggleSidebarFromCommand()
    }

    func focusSidebarFromCommand() {
        splitViewController?.focusSidebarFromCommand()
    }

    func showSidebarFilter() {
        splitViewController?.showSidebarFilter()
    }

    func showWorktreeSidebar() {
        splitViewController?.showWorktreeSidebar()
    }

    func expandSidebar() {
        splitViewController?.expandSidebar()
    }

    func sidebarPerformanceProofShellReadback() -> SidebarPerformanceProofShellReadback? {
        splitViewController?.sidebarPerformanceProofShellReadback(window: window)
    }

    func refocusActivePane() {
        splitViewController?.refocusActivePane()
    }

    func cancelHeldPanePreview() {
        splitViewController?.cancelHeldPanePreview()
    }

    func awaitLaunchRestoreAfterNextResize() {
        awaitsLaunchRestoreResize = true
    }

    func prepareLaunchMaximizeAndRestore() {
        awaitsLaunchMaximize = true
    }

    func syncVisibleTerminalGeometry(reason: StaticString) {
        splitViewController?.syncVisibleTerminalGeometry(reason: reason)
    }

    func completeLaunchPresentation() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        synchronizeWindowPresentationFacts()
        applyLaunchMaximizeIfNeeded()
    }

    private func applyLaunchMaximizeIfNeeded() {
        guard awaitsLaunchMaximize else { return }
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        awaitsLaunchMaximize = false
        let targetFrame = screen.visibleFrame
        RestoreTrace.log(
            "MainWindowController.applyLaunchMaximize currentFrame=\(NSStringFromRect(window.frame)) targetFrame=\(NSStringFromRect(targetFrame))"
        )
        if window.frame.equalTo(targetFrame) {
            RestoreTrace.log("MainWindowController.applyLaunchMaximize alreadyAtTargetFrame")
            window.contentView?.layoutSubtreeIfNeeded()
            applicationLifecycleMonitor.handleLaunchLayoutSettled()
            return
        }
        // Mark launch geometry as settled before the maximize resize begins so the
        // first full-size terminalContainer bounds publish can immediately
        // materialize the active tab instead of waiting for the later bridge path.
        applicationLifecycleMonitor.handleLaunchLayoutSettled()
        awaitLaunchRestoreAfterNextResize()
        window.setFrame(targetFrame, display: true)
    }

    @objc private func toggleSidebarAction() {
        toggleSidebar()
    }

    @objc private func toggleSidebarToolbarAction() {
        AppCommandDispatcher.shared.dispatch(.toggleSidebar)
        Task { @MainActor [weak self] in
            self?.refreshToolbarToggleState()
        }
    }

}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .worktreeSidebar,
            .sidebarDivider,
            .watchFolder,
            .managementLayer,
            .arrangement,
            .arrangementDivider,
            .workspaceTabs,
            .selectTab,
            .tabActionsDivider,
            .newTab,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if let cachedItem = toolbarItems[itemIdentifier] {
            return cachedItem
        }

        let item: NSToolbarItem?
        switch itemIdentifier {
        case .worktreeSidebar:
            item = makeNativeToolbarItem(
                identifier: itemIdentifier,
                label: AppCommand.toggleSidebar.definition.label,
                command: .toggleSidebar,
                symbolName: SystemSymbol.sidebarLeft.rawValue,
                isBordered: false,
                action: #selector(toggleSidebarToolbarAction)
            )
        case .sidebarDivider:
            item = makeToolbarDividerItem(identifier: itemIdentifier, label: "Sidebar Divider")
        case .watchFolder:
            item = makeControlToolbarItem(
                identifier: itemIdentifier,
                label: "Watch Folder",
                control: .watchFolder
            )
        case .managementLayer:
            item = makeControlToolbarItem(
                identifier: itemIdentifier,
                label: "Management Mode",
                control: .managementLayer
            )
        case .arrangement:
            item = makeControlToolbarItem(
                identifier: itemIdentifier,
                label: "Arrangements",
                control: .arrangement
            )
        case .arrangementDivider:
            item = makeToolbarDividerItem(identifier: itemIdentifier, label: "Arrangement Divider")
        case .workspaceTabs:
            let workspaceTabsItem = NSToolbarItem(itemIdentifier: itemIdentifier)
            workspaceTabsItem.label = "Workspace Tabs"
            workspaceTabsItem.paletteLabel = "Workspace Tabs"
            workspaceTabsItem.visibilityPriority = .low
            workspaceTabsItem.isBordered = false
            workspaceTabsItem.view = splitViewController?.makeToolbarChromeView()
            item = workspaceTabsItem
        case .selectTab:
            item = makeControlToolbarItem(
                identifier: itemIdentifier,
                label: "Select Tab",
                control: .selectTab
            )
        case .tabActionsDivider:
            item = makeToolbarDividerItem(identifier: itemIdentifier, label: "Tab Actions Divider")
        case .newTab:
            item = makeControlToolbarItem(
                identifier: itemIdentifier,
                label: "New Tab",
                control: .newTab
            )

        default:
            item = nil
        }

        if let item {
            toolbarItems[itemIdentifier] = item
        }
        return item
    }

    private func makeControlToolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        control: MainToolbarControl
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.visibilityPriority = .high
        item.isBordered = false
        item.view = splitViewController?.makeToolbarControlView(control)
        return item
    }

    private func makeNativeToolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        command: AppCommand,
        symbolName: String,
        isBordered: Bool,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.visibilityPriority = .high
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: AppStyles.Shell.Chrome.ToolbarButton.iconSize,
            weight: .medium
        ).applying(
            NSImage.SymbolConfiguration(paletteColors: [AppStyles.Shell.Chrome.ToolbarButton.iconForegroundNSColor])
        )
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(symbolConfiguration)
        item.isBordered = isBordered
        item.target = self
        item.action = action
        item.applyControlTooltip(
            AppCommandDispatcher.shared.definition(for: command).controlTooltipRenderValue()
        )
        item.isEnabled = AppCommandDispatcher.shared.canDispatch(command)
        return item
    }

    private func makeToolbarDividerItem(
        identifier: NSToolbarItem.Identifier,
        label: String
    ) -> NSToolbarItem {
        let dividerView = ToolbarDividerView()
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.visibilityPriority = .high
        item.isBordered = false
        item.view = dividerView
        return item
    }

    func refreshToolbarToggleState() {
        let sidebarState = atom(\.workspaceSidebarState)
        let sidebarOpen = !sidebarState.sidebarCollapsed
        setToggleImage(
            identifier: .worktreeSidebar,
            baseSymbol: SystemSymbol.sidebarLeft.rawValue,
            selectedSymbol: SystemSymbol.sidebarLeft.rawValue,
            label: AppCommand.toggleSidebar.definition.label,
            isSelected: sidebarOpen
        )
    }

    private func observeToolbarPresentationState() {
        guard !hasShutdown else { return }
        withObservationTracking {
            let sidebarState = atom(\.workspaceSidebarState)
            _ = sidebarState.sidebarCollapsed
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.hasShutdown else { return }
                self.refreshToolbarToggleState()
                self.observeToolbarPresentationState()
            }
        }
    }

    private func setToggleImage(
        identifier: NSToolbarItem.Identifier,
        baseSymbol: String,
        selectedSymbol: String,
        label: String,
        isSelected: Bool
    ) {
        guard let item = toolbarItems[identifier] else { return }
        let symbolName = isSelected ? selectedSymbol : baseSymbol
        var configuration = NSImage.SymbolConfiguration(
            pointSize: AppStyles.Shell.Chrome.ToolbarButton.iconSize,
            weight: .medium
        )
        let paletteColor: NSColor =
            isSelected
            ? AppStyles.General.Accent.primaryNSColor
            : AppStyles.Shell.Chrome.ToolbarButton.iconForegroundNSColor
        configuration = configuration.applying(
            NSImage.SymbolConfiguration(paletteColors: [paletteColor])
        )
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        item.image = image
    }
}

private final class ToolbarDividerView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: AppStyles.Shell.Chrome.dividerHorizontalPadding * 2 + 1,
            height: AppStyles.Shell.Chrome.dividerHeight
        )
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let lineView = NSView(frame: .zero)
        lineView.translatesAutoresizingMaskIntoConstraints = false
        lineView.wantsLayer = true
        lineView.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(lineView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(
                equalToConstant: AppStyles.Shell.Chrome.dividerHorizontalPadding * 2 + 1
            ),
            heightAnchor.constraint(equalToConstant: AppStyles.Shell.Chrome.dividerHeight),
            lineView.centerXAnchor.constraint(equalTo: centerXAnchor),
            lineView.centerYAnchor.constraint(equalTo: centerYAnchor),
            lineView.widthAnchor.constraint(equalToConstant: 1),
            lineView.heightAnchor.constraint(equalToConstant: AppStyles.Shell.Chrome.dividerHeight),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}

// MARK: - Toolbar Item Identifiers
