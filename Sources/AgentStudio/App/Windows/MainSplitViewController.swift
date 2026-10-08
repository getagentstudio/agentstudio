import AgentStudioBridge
import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import AppKit
import SwiftUI

struct SidebarRootViewDependencies {
    let store: WorkspaceStore
    let octiconLoader: OcticonLoader
    var paneContextReaders: PaneContextUIReaders?
    let paneActivityStatusAtom: PaneActivityStatusAtom
    let applicationLifecycleMonitor: ApplicationLifecycleMonitor
    let sidebarTimeInvalidationConsumerID: UUID
    let sidebarState: WorkspaceSidebarState
    let repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom
    let bridgeAttendanceSnapshot: BridgeAttendanceSnapshot
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    let onRefocusActivePane: () -> Void
    let onSelectedPaneTargetChange:
        @MainActor (RepoExplorerSelectedPaneTarget?, RepoExplorerSelectedPaneTargetChangeOrigin) -> Void
    let onPreviewEligibilityLoss: @MainActor () -> Void
    let onPreviewCommit: @MainActor () -> Void
    let onSidebarVisibleWorktreesChanged: @MainActor @Sendable () -> Void
    let onPerformanceProofReadback: @MainActor @Sendable (RepoExplorerPerformanceProofReadback) -> Void
    let onRepositoryFactUpdateProgressPresented: @MainActor @Sendable (UUID, UUID) -> Void
}

final class ShellSplitView: NSSplitView {
    override var dividerThickness: CGFloat {
        0
    }

    override func drawDivider(in dirtyRect: NSRect) {}
}

/// Main split view controller with sidebar and terminal content area
class MainSplitViewController: NSSplitViewController {
    typealias SidebarRootViewBuilder = @MainActor (SidebarRootViewDependencies) -> AnyView
    private static let sidebarFocusRetryTurns = 20

    @MainActor
    private static func defaultSidebarRootViewBuilder(
        dependencies: SidebarRootViewDependencies
    ) -> AnyView {
        AnyView(
            SidebarSurfaceHost(
                store: dependencies.store,
                octiconLoader: dependencies.octiconLoader,
                paneActivityStatusAtom: dependencies.paneActivityStatusAtom,
                paneContextReaders: dependencies.paneContextReaders,
                applicationLifecycleMonitor: dependencies.applicationLifecycleMonitor,
                sidebarTimeInvalidationConsumerID: dependencies.sidebarTimeInvalidationConsumerID,
                sidebarState: dependencies.sidebarState,
                repoExplorerSidebarPrefs: dependencies.repoExplorerSidebarPrefs,
                bridgeAttendanceSnapshot: dependencies.bridgeAttendanceSnapshot,
                performanceTraceRecorder: dependencies.performanceTraceRecorder,
                onRefocusActivePane: dependencies.onRefocusActivePane,
                onSelectedPaneTargetChange: dependencies.onSelectedPaneTargetChange,
                onPreviewEligibilityLoss: dependencies.onPreviewEligibilityLoss,
                onPreviewCommit: dependencies.onPreviewCommit,
                onSidebarVisibleWorktreesChanged: dependencies.onSidebarVisibleWorktreesChanged,
                onPerformanceProofReadback: dependencies.onPerformanceProofReadback,
                onRepositoryFactUpdateProgressPresented: dependencies
                    .onRepositoryFactUpdateProgressPresented
            )
        )
    }

    private var sidebarHostingController: NSHostingController<AnyView>?
    private var paneTabViewController: PaneTabViewController?
    private var sidebarFocusTask: Task<Void, Never>?
    private var sidebarWidthRestoreTask: Task<Void, Never>?
    private let sidebarReturnFocusOrigin = SidebarReturnFocusOrigin()
    private var shouldExpandSidebarOnLoad = false
    private var shouldFocusSidebarWhenVisible = false
    private var didApplySidebarWidthAfterLayout = false
    private var hasShutdown = false

    // MARK: - Dependencies (injected)

    private let paneContextReaders: PaneContextUIReaders?
    private let store: WorkspaceStore
    private let octiconLoader: OcticonLoader
    private let workspaceWindowId: UUID?
    private var repoCache: RepoCacheAtom { atom(\.repoCache) }
    private var uiState: WorkspaceSidebarState { atom(\.workspaceSidebarState) }
    private let workspaceActionExecutor: WorkspaceActionExecutor
    private let runtimeCommandDispatcher: any PaneRuntimeCommandDispatching
    private let commandDispatcher: any AppCommandDispatching
    private let applicationLifecycleMonitor: ApplicationLifecycleMonitor
    private let sidebarTimeInvalidationConsumerID: UUID
    private let appLifecycleStore: AppLifecycleAtom
    private let windowLifecycleStore: WindowLifecycleAtom
    private let tabBarAdapter: TabBarAdapter
    private let viewRegistry: ViewRegistry
    private let repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom
    private let bridgeAttendanceSnapshot: BridgeAttendanceSnapshot
    private let bridgePaneAttendance: BridgePaneAttendanceAtom
    private let editorChooser: EditorChooserState
    private let sessionsPaneViewedMailbox: SessionsPaneViewedMailbox?
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private let onSidebarVisibleWorktreesChanged: @MainActor @Sendable () -> Void
    private let onPerformanceProofReadback: @MainActor @Sendable (RepoExplorerPerformanceProofReadback) -> Void
    private let onRepositoryFactUpdateProgressPresented: @MainActor @Sendable (UUID, UUID) -> Void
    private let sidebarRootViewBuilder: SidebarRootViewBuilder
    private let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    private let paneTabRegistersAsCommandHandler: Bool
    private(set) var heldPanePreviewState: HeldPanePreviewState? = HeldPanePreviewState()

    func syncVisibleTerminalGeometry(reason: StaticString) {
        paneTabViewController?.syncVisibleTerminalGeometry(reason: reason)
        workspaceActionExecutor.prepareHeldPanePreview()
    }

    func makePaneFocusAppControl(store: WorkspaceStore) -> (any PaneFocusAppControlling)? {
        guard let paneTabViewController else {
            return nil
        }
        return PaneTabViewControllerPaneFocusAppControl(
            targetedPaneFocusSubmitter: paneTabViewController,
            workspaceStore: store
        )
    }

    init(
        store: WorkspaceStore,
        octiconLoader: OcticonLoader,
        paneContextReaders: PaneContextUIReaders? = nil,
        workspaceWindowId: UUID? = nil,
        workspaceActionExecutor: WorkspaceActionExecutor,
        runtimeCommandDispatcher: any PaneRuntimeCommandDispatching,
        commandDispatcher: any AppCommandDispatching = AppCommandDispatcher.shared,
        applicationLifecycleMonitor: ApplicationLifecycleMonitor,
        appLifecycleStore: AppLifecycleAtom,
        windowLifecycleStore: WindowLifecycleAtom = atom(\.windowLifecycle),
        tabBarAdapter: TabBarAdapter,
        viewRegistry: ViewRegistry,
        repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom,
        bridgeAttendanceSnapshot: @escaping BridgeAttendanceSnapshot,
        bridgePaneAttendance: BridgePaneAttendanceAtom,
        editorChooser: EditorChooserState,
        sessionsPaneViewedMailbox: SessionsPaneViewedMailbox? = nil,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        onSidebarVisibleWorktreesChanged: @escaping @MainActor @Sendable () -> Void = {},
        onPerformanceProofReadback:
            @escaping @MainActor @Sendable (RepoExplorerPerformanceProofReadback) -> Void = { _ in },
        onRepositoryFactUpdateProgressPresented:
            @escaping @MainActor @Sendable (UUID, UUID) -> Void = { _, _ in },
        sidebarRootViewBuilder: @escaping SidebarRootViewBuilder = MainSplitViewController
            .defaultSidebarRootViewBuilder,
        closeTransitionCoordinator: PaneCloseTransitionCoordinator = PaneCloseTransitionCoordinator(),
        paneTabRegistersAsCommandHandler: Bool = true
    ) {
        self.paneContextReaders = paneContextReaders
        self.store = store
        self.octiconLoader = octiconLoader
        self.workspaceWindowId = workspaceWindowId
        self.workspaceActionExecutor = workspaceActionExecutor
        self.runtimeCommandDispatcher = runtimeCommandDispatcher
        self.commandDispatcher = commandDispatcher
        self.applicationLifecycleMonitor = applicationLifecycleMonitor
        sidebarTimeInvalidationConsumerID = workspaceWindowId ?? UUIDv7.generate()
        self.appLifecycleStore = appLifecycleStore
        self.windowLifecycleStore = windowLifecycleStore
        self.tabBarAdapter = tabBarAdapter
        self.viewRegistry = viewRegistry
        self.repoExplorerSidebarPrefs = repoExplorerSidebarPrefs
        self.bridgeAttendanceSnapshot = bridgeAttendanceSnapshot
        self.bridgePaneAttendance = bridgePaneAttendance
        self.editorChooser = editorChooser
        self.sessionsPaneViewedMailbox = sessionsPaneViewedMailbox
        self.performanceTraceRecorder = performanceTraceRecorder
        self.onSidebarVisibleWorktreesChanged = onSidebarVisibleWorktreesChanged
        self.onPerformanceProofReadback = onPerformanceProofReadback
        self.onRepositoryFactUpdateProgressPresented = onRepositoryFactUpdateProgressPresented
        self.sidebarRootViewBuilder = sidebarRootViewBuilder
        self.closeTransitionCoordinator = closeTransitionCoordinator
        self.paneTabRegistersAsCommandHandler = paneTabRegistersAsCommandHandler
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        splitView = ShellSplitView()

        splitView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor),
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let heldPanePreviewState else {
            preconditionFailure("Held pane preview state must exist before loading the window")
        }
        workspaceActionExecutor.bindHeldPanePreviewState(heldPanePreviewState)
        let paneTabVC = PaneTabViewController(
            store: store,
            octiconLoader: octiconLoader,
            repoCache: repoCache,
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore,
            workspaceWindowId: workspaceWindowId,
            executor: workspaceActionExecutor,
            runtimeCommandDispatcher: runtimeCommandDispatcher,
            tabBarAdapter: tabBarAdapter,
            viewRegistry: viewRegistry,
            bridgePaneAttendance: bridgePaneAttendance,
            editorChooser: editorChooser,
            sessionsPaneViewedMailbox: sessionsPaneViewedMailbox,
            paneContextReaders: paneContextReaders,
            paneInboxPresentation: nil,
            pinnedPanePreferences: repoExplorerSidebarPrefs,
            closeTransitionCoordinator: closeTransitionCoordinator,
            heldPanePreviewState: heldPanePreviewState,
            performanceTraceRecorder: performanceTraceRecorder,
            onPreviewEligibilityLoss: { [weak self] in
                self?.heldPanePreviewState?.cancelIfHeld()
            },
            registersAsCommandHandler: paneTabRegistersAsCommandHandler,
            embedsTabBarInView: false
        )
        self.paneTabViewController = paneTabVC
        // Initialize the shared tab host before PaneTabViewController's view
        // lifecycle evaluates empty-state visibility. The toolbar owns placement
        // of this host; this controller only owns its feature wiring.
        _ = paneTabVC.makeTabBarHostingView()

        // Configure split view
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarView = makeSidebarRootView()
        let sidebarHosting = NSHostingController(
            rootView: AnyView(sidebarView.tint(AppStyles.General.Accent.primaryColor)))
        sidebarHosting.sizingOptions = []
        self.sidebarHostingController = sidebarHosting

        let sidebarItem = NSSplitViewItem(viewController: sidebarHosting)
        sidebarItem.minimumThickness = 250
        sidebarItem.maximumThickness = 450
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = NSSplitViewItem.CollapseBehavior.preferResizingSiblingsWithFixedSplitView
        addSplitViewItem(sidebarItem)

        let paneTabItem = NSSplitViewItem(viewController: paneTabVC)
        paneTabItem.minimumThickness = 400
        addSplitViewItem(paneTabItem)

        // Pre-load collapse/expand requests only update atoms. Once AppKit has
        // splitViewItems, realize the persisted presentation exactly once here.
        if shouldExpandSidebarOnLoad {
            sidebarItem.isCollapsed = false
            shouldExpandSidebarOnLoad = false
        } else if store.repositoryTopologyAtom.repos.isEmpty {
            sidebarItem.isCollapsed = true
        } else if uiState.sidebarCollapsed {
            sidebarItem.isCollapsed = true
        }

        scheduleSidebarWidthRestore()
    }

    @MainActor
    private func makeSidebarRootView() -> AnyView {
        sidebarRootViewBuilder(
            SidebarRootViewDependencies(
                store: store,
                octiconLoader: octiconLoader,
                paneContextReaders: paneContextReaders,
                paneActivityStatusAtom: atom(\.paneActivityStatus),
                applicationLifecycleMonitor: applicationLifecycleMonitor,
                sidebarTimeInvalidationConsumerID: sidebarTimeInvalidationConsumerID,
                sidebarState: uiState,
                repoExplorerSidebarPrefs: repoExplorerSidebarPrefs,
                bridgeAttendanceSnapshot: bridgeAttendanceSnapshot,
                performanceTraceRecorder: performanceTraceRecorder,
                onRefocusActivePane: { [weak self] in
                    self?.restoreSidebarReturnFocusOrigin()
                },
                onSelectedPaneTargetChange: { [weak self] target, origin in
                    guard let self else { return }
                    let validatedTarget = self.validatedPreviewTarget(for: target)
                    let didChangeTarget: Bool
                    if self.heldPanePreviewState?.isHeld == true {
                        didChangeTarget =
                            self.heldPanePreviewState?.updateRequestedTarget(validatedTarget) == true
                    } else if origin == .arrowNavigation {
                        didChangeTarget =
                            self.heldPanePreviewState?.beginSpaceHold(requestedTarget: validatedTarget) == true
                    } else {
                        didChangeTarget = false
                    }
                    if didChangeTarget {
                        self.workspaceActionExecutor.prepareHeldPanePreview()
                    }
                },
                onPreviewEligibilityLoss: { [weak self] in
                    self?.heldPanePreviewState?.cancelIfHeld()
                    self?.workspaceActionExecutor.prepareHeldPanePreview()
                },
                onPreviewCommit: { [weak self] in
                    self?.heldPanePreviewState?.commitBeforeActivation()
                    self?.workspaceActionExecutor.prepareHeldPanePreview()
                },
                onSidebarVisibleWorktreesChanged: onSidebarVisibleWorktreesChanged,
                onPerformanceProofReadback: onPerformanceProofReadback,
                onRepositoryFactUpdateProgressPresented: onRepositoryFactUpdateProgressPresented
            )
        )
    }

    func makeToolbarChromeView() -> MainToolbarChromeView {
        loadViewIfNeeded()
        guard let paneTabViewController else {
            preconditionFailure("Pane tab view controller must exist before toolbar chrome is created")
        }
        return MainToolbarChromeView(tabBarHostingView: paneTabViewController.makeTabBarHostingView())
    }

    func makeToolbarControlView(_ control: MainToolbarControl) -> NSView {
        loadViewIfNeeded()
        guard let paneTabViewController else {
            preconditionFailure("Pane tab view controller must exist before toolbar controls are created")
        }
        return paneTabViewController.makeToolbarControlView(control)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySidebarWidthAfterLayoutIfNeeded()
        guard shouldFocusSidebarWhenVisible else { return }
        shouldFocusSidebarWhenVisible = false
        scheduleSidebarFocus()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWindowContentSafeArea()
        applySidebarWidthAfterLayoutIfNeeded()
    }

    func updateWindowContentSafeArea() {
        guard let window = view.window else { return }

        let nonObscuredRect = view.convert(window.contentLayoutRect, from: nil)
        let bounds = view.bounds
        let targetInsets = NSEdgeInsets(
            top: max(0, bounds.maxY - nonObscuredRect.maxY),
            left: max(0, nonObscuredRect.minX - bounds.minX),
            bottom: max(0, nonObscuredRect.minY - bounds.minY),
            right: max(0, bounds.maxX - nonObscuredRect.maxX)
        )

        let existingInsets = view.additionalSafeAreaInsets
        let inheritedInsets = view.safeAreaInsets
        let insets = NSEdgeInsets(
            top: max(0, targetInsets.top - inheritedInsets.top + existingInsets.top),
            left: max(0, targetInsets.left - inheritedInsets.left + existingInsets.left),
            bottom: max(0, targetInsets.bottom - inheritedInsets.bottom + existingInsets.bottom),
            right: max(0, targetInsets.right - inheritedInsets.right + existingInsets.right)
        )
        guard
            existingInsets.top != insets.top
                || existingInsets.left != insets.left
                || existingInsets.bottom != insets.bottom
                || existingInsets.right != insets.right
        else { return }
        view.additionalSafeAreaInsets = insets
    }

    private func saveSidebarState() {
        let isCollapsed = splitViewItems.first?.isCollapsed ?? false
        if uiState.sidebarCollapsed != isCollapsed {
            uiState.setSidebarCollapsed(isCollapsed)
        }

        guard !isCollapsed, didApplySidebarWidthAfterLayout, let sidebarWidth = currentSidebarWidth() else { return }
        store.windowMemoryAtom.setSidebarWidth(sidebarWidth)
    }

    private func validatedPreviewTarget(
        for selection: RepoExplorerSelectedPaneTarget?
    ) -> ValidatedPanePreviewTarget? {
        guard let selection,
            let pane = store.paneAtom.pane(selection.paneID),
            store.tabLayoutAtom.tabID(containingPane: pane.parentPaneId ?? pane.id)
                == selection.owningTabID
        else { return nil }
        let terminalState = pane.terminalState
        return ValidatedPanePreviewTarget(
            paneID: pane.id,
            owningTabID: selection.owningTabID,
            provider: pane.provider,
            sessionID: terminalState?.zmxSessionID
        )
    }

    private func applySidebarWidthAfterLayoutIfNeeded() {
        guard !didApplySidebarWidthAfterLayout else { return }
        guard splitViewItems.count >= 2 else { return }
        guard let sidebarItem = splitViewItems.first, !sidebarItem.isCollapsed else { return }
        guard splitView.bounds.width > 0 else { return }
        let sidebarWidth = clampedSidebarWidth(for: sidebarItem)
        let trailingMinimumThickness = splitViewItems.dropFirst().reduce(CGFloat(0)) { result, item in
            result + item.minimumThickness
        }
        guard splitView.bounds.width >= sidebarWidth + trailingMinimumThickness else { return }
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        if let currentWidth = currentSidebarWidth(), abs(currentWidth - sidebarWidth) > 1 {
            splitView.setPosition(sidebarWidth + (sidebarWidth - currentWidth), ofDividerAt: 0)
            splitView.adjustSubviews()
            splitView.layoutSubtreeIfNeeded()
        }
        guard let currentWidth = currentSidebarWidth(), abs(currentWidth - sidebarWidth) <= 1 else { return }
        didApplySidebarWidthAfterLayout = true
    }

    private func scheduleSidebarWidthRestore() {
        sidebarWidthRestoreTask?.cancel()
        sidebarWidthRestoreTask = Task { @MainActor [weak self] in
            for _ in 0..<5 {
                guard let self, !Task.isCancelled, !self.didApplySidebarWidthAfterLayout else { return }
                await Task.yield()
                self.applySidebarWidthAfterLayoutIfNeeded()
            }
        }
    }

    private func clampedSidebarWidth(for sidebarItem: NSSplitViewItem) -> CGFloat {
        let sidebarWidth = min(
            max(store.windowMemoryAtom.sidebarWidth, sidebarItem.minimumThickness),
            sidebarItem.maximumThickness
        )
        return sidebarWidth
    }

    private func currentSidebarWidth() -> CGFloat? {
        guard let sidebarView = splitViewItems.first?.viewController.view else { return nil }
        let width = sidebarView.frame.width
        guard width > 0 else { return nil }
        return width
    }

    func savePersistentUIState() {
        saveSidebarState()
    }

    private func scheduleSaveSidebarState() {
        Task { @MainActor [weak self] in
            self?.saveSidebarState()
        }
    }

    private func handleToggleSidebar() {
        let clock = ContinuousClock()
        let toggleStart = clock.now
        let wasCollapsed = isSidebarCollapsed
        if wasCollapsed {
            expandSidebar()
        } else {
            collapseSidebar()
        }
        performanceTraceRecorder?.recordDuration(
            .sidebarToggle,
            duration: toggleStart.duration(to: clock.now),
            attributes: [
                "agentstudio.performance.sidebar.toggle.intent": .string(wasCollapsed ? "expand" : "collapse"),
                "agentstudio.performance.sidebar.was_collapsed": .bool(wasCollapsed),
                "agentstudio.performance.sidebar.is_collapsed": .bool(isSidebarCollapsed),
            ]
        )
    }

    private func handleFilterSidebar() {
        guard isSidebarCollapsed else { return }
        expandSidebar()
    }

    // MARK: - Sidebar State

    var isSidebarCollapsed: Bool {
        splitViewItems.first?.isCollapsed ?? false
    }

    func sidebarPerformanceProofShellReadback(
        window: NSWindow?
    ) -> SidebarPerformanceProofShellReadback? {
        guard let sidebarItem = splitViewItems.first,
            let sidebarView = sidebarItem.viewController.viewIfLoaded,
            let paneTabViewController
        else { return nil }

        let nativeSidebarGeometryIsVisible =
            !sidebarItem.isCollapsed
            && SidebarPerformanceProofAccessibility.isEffectivelyVisible(sidebarView)
            && sidebarView.frame.width > 0
            && sidebarView.frame.height > 0
        let tableView = SidebarPerformanceProofAccessibility.firstDescendant(
            of: NSTableView.self,
            in: sidebarView
        )
        let nativeSelectedGroupingMode = SidebarPerformanceProofAccessibility.selectedRepoGroupingMode(
            in: sidebarView
        )
        let nativeSidebarAccessibilityIsReady =
            nativeSidebarGeometryIsVisible
            && nativeSelectedGroupingMode != nil
            && tableView?.accessibilityRole() == .table

        return SidebarPerformanceProofShellReadback(
            semanticSidebarIsCollapsed: uiState.sidebarCollapsed,
            nativeSidebarIsCollapsed: sidebarItem.isCollapsed,
            nativeSidebarGeometryIsVisible: nativeSidebarGeometryIsVisible,
            nativeFilterValue: (window?.firstResponder as? NSTextView)?.string,
            nativeSelectedGroupingMode: nativeSelectedGroupingMode,
            nativeSidebarAccessibilityIsReady: nativeSidebarAccessibilityIsReady,
            nativePresentedRowCount: tableView?.numberOfRows,
            nativeVisibleProjection: tableView.flatMap {
                RepoExplorerNativeVisibleProjectionReadback.capture(in: $0)
            },
            tab: paneTabViewController.sidebarPerformanceProofTabReadback(window: window)
        )
    }

    func expandSidebar() {
        guard isViewLoaded else {
            shouldExpandSidebarOnLoad = true
            uiState.setSidebarCollapsed(false)
            return
        }
        guard let sidebarItem = splitViewItems.first, sidebarItem.isCollapsed else { return }
        didApplySidebarWidthAfterLayout = false
        sidebarItem.isCollapsed = false
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.applySidebarWidthAfterLayoutIfNeeded()
        }
        scheduleSaveSidebarState()
    }

    func ensureSidebarVisible() {
        expandSidebar()
    }

    func collapseSidebar() {
        heldPanePreviewState?.cancelIfHeld()
        sidebarFocusTask?.cancel()
        shouldFocusSidebarWhenVisible = false
        guard isViewLoaded else {
            // Contract: restore and composite commands may ask for collapse before
            // splitViewItems exist. Clear the pending expansion bit here so the
            // last pre-load intent wins once viewDidLoad realizes shell state.
            shouldExpandSidebarOnLoad = false
            uiState.setSidebarCollapsed(true)
            uiState.setSidebarHasFocus(false)
            sidebarReturnFocusOrigin.clear()
            return
        }
        guard let sidebarItem = splitViewItems.first, !sidebarItem.isCollapsed else { return }
        let shouldRestoreFocus =
            view.window.map {
                sidebarReturnFocusOrigin.currentResponderBelongsToSidebar(
                    in: $0,
                    sidebarRoot: sidebarHostingController?.view
                )
            } ?? false
        sidebarItem.isCollapsed = true
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        uiState.setSidebarCollapsed(true)
        uiState.setSidebarHasFocus(false)
        scheduleSaveSidebarState()
        if shouldRestoreFocus {
            restoreSidebarReturnFocusOrigin()
        }
    }

    @discardableResult
    func focusSidebarHostIfReady() -> Bool {
        guard isViewLoaded else { return false }
        guard let window = view.window else { return false }
        window.makeKey()

        guard
            let focusTarget = sidebarHostingController?.view.descendantView(
                matching: RepoExplorerView.focusTargetIdentifier
            )
        else {
            return false
        }
        return RepoExplorerView.requestListFocus(on: focusTarget)
    }

    private func scheduleSidebarFocus() {
        sidebarFocusTask?.cancel()
        sidebarFocusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<Self.sidebarFocusRetryTurns {
                guard !Task.isCancelled else { return }
                if self.focusSidebarHostIfReady() {
                    return
                }
                await Task.yield()
            }
        }
    }

    func toggleSidebarFromCommand() {
        handleToggleSidebar()
    }

    func focusSidebarFromCommand() {
        guard isViewLoaded, let window = view.window else {
            shouldFocusSidebarWhenVisible = true
            ensureSidebarVisible()
            return
        }
        if sidebarReturnFocusOrigin.currentResponderBelongsToSidebar(
            in: window,
            sidebarRoot: sidebarHostingController?.view
        ) {
            sidebarFocusTask?.cancel()
            restoreSidebarReturnFocusOrigin()
            return
        }
        sidebarReturnFocusOrigin.captureCurrentResponder(
            in: window,
            sidebarRoot: sidebarHostingController?.view
        )
        ensureSidebarVisible()
        scheduleSidebarFocus()
    }

    func showSidebarFilter() {
        // Focus the current screen's always-visible filter, including repeat requests.
        guard uiState.sidebarSurface != .inbox else { return }
        if let window = view.window {
            sidebarReturnFocusOrigin.captureCurrentResponder(
                in: window,
                sidebarRoot: sidebarHostingController?.view
            )
        }
        expandSidebar()
        uiState.setFilterVisible(true)
        if let target = sidebarHostingController?.view.descendantView(
            matching: RepoExplorerView.focusTargetIdentifier
        ) {
            RepoExplorerView.requestFilterFocus(on: target)
        }
    }

    func showWorktreeSidebar() {
        // Preserve the legacy toolbar toggle behavior for this surface-specific entry point.
        if !isSidebarCollapsed && uiState.sidebarSurface == .repos {
            collapseSidebar()
            return
        }
        sidebarFocusTask?.cancel()
        shouldFocusSidebarWhenVisible = false
        uiState.setSidebarSurface(.repos)
        ensureSidebarVisible()
    }

    func refocusActivePane() {
        paneTabViewController?.refocusActivePane()
    }

    func cancelHeldPanePreview() {
        heldPanePreviewState?.cancelIfHeld()
    }

    private func restoreSidebarReturnFocusOrigin() {
        heldPanePreviewState?.cancelIfHeld()
        sidebarReturnFocusOrigin.restore(in: view.window) { [weak self] in
            self?.paneTabViewController?.refocusActivePane()
        }
    }

    func shutdown() {
        guard !hasShutdown else { return }
        hasShutdown = true
        sidebarFocusTask?.cancel()
        sidebarWidthRestoreTask?.cancel()
        shouldFocusSidebarWhenVisible = false
        sidebarReturnFocusOrigin.clear()
        heldPanePreviewState?.cancelIfHeld()
        heldPanePreviewState = nil
        paneTabViewController?.shutdown()
    }

    // MARK: - Subtle Divider

    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        // Make the divider very thin/subtle
        var rect = proposedEffectiveRect
        rect.size.width = 1
        return rect
    }
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        let clock = ContinuousClock()
        let resizeStart = clock.now
        super.splitViewDidResizeSubviews(notification)
        RestoreTrace.log(
            "MainSplitViewController.splitViewDidResizeSubviews splitBounds=\(NSStringFromRect(splitView.bounds)) sidebarCollapsed=\(isSidebarCollapsed)"
        )
        saveSidebarState()
        paneTabViewController?.syncVisibleTerminalGeometry(reason: "splitViewDidResizeSubviews")
        performanceTraceRecorder?.recordDuration(
            .sidebarResize,
            duration: resizeStart.duration(to: clock.now),
            attributes: [
                "agentstudio.performance.sidebar.is_collapsed": .bool(isSidebarCollapsed),
                "agentstudio.performance.sidebar.width": .double(Double(currentSidebarWidth() ?? 0)),
                "agentstudio.performance.sidebar.split_width": .double(Double(splitView.bounds.width)),
            ]
        )
    }
}

extension NSView {
    fileprivate func descendantView(matching identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        if self.identifier == identifier {
            return self
        }

        for subview in subviews {
            if let match = subview.descendantView(matching: identifier) {
                return match
            }
        }

        return nil
    }
}

#if DEBUG
    extension MainSplitViewController {
        func syncTabContentHostsForTesting() {
            paneTabViewController?.syncTabContentHostsForTesting()
        }
    }
#endif
