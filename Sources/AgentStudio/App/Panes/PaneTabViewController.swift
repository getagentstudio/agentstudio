import AgentStudioBridge
import AgentStudioCommandBar
import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInboxNotification
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioTerminal
import AppKit
import GhosttyKit
import Observation
import SwiftUI
import os.log

// swiftlint:disable file_length type_body_length

private final class RestoreAwareTerminalContainerView: NSView {
    var onNonEmptyLayoutBoundsChanged: ((CGRect) -> Void)?
    private var lastLoggedBounds: CGRect = .zero
    private var lastPublishedBounds: CGRect = .zero
    private var layoutGeneration: Int = 0

    override func layout() {
        super.layout()
        logBoundsChangeIfNeeded(reason: "layout")
        publishNonEmptyLayoutBoundsChangedIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        RestoreTrace.log(
            "RestoreAwareTerminalContainerView.viewDidMoveToWindow window=\(window != nil) id=\(ObjectIdentifier(self)) superview=\(superview != nil) bounds=\(NSStringFromRect(bounds))"
        )
        logBoundsChangeIfNeeded(reason: "viewDidMoveToWindow")
        publishNonEmptyLayoutBoundsChangedIfNeeded()
    }

    private func logBoundsChangeIfNeeded(reason: StaticString) {
        guard bounds != lastLoggedBounds else { return }
        layoutGeneration += 1
        lastLoggedBounds = bounds
        RestoreTrace.log(
            "RestoreAwareTerminalContainerView \(reason) generation=\(layoutGeneration) bounds=\(NSStringFromRect(bounds)) window=\(window != nil)"
        )
    }

    private func publishNonEmptyLayoutBoundsChangedIfNeeded() {
        guard !bounds.isEmpty, bounds != lastPublishedBounds else { return }
        lastPublishedBounds = bounds
        onNonEmptyLayoutBoundsChanged?(bounds)
    }
}

struct SplitDropCommitDestination: Equatable {
    let paneId: UUID
    let drawerParentPaneId: UUID?
}

struct ArrangementPanelProgrammaticPresentation: Equatable {
    let workspaceWindowId: UUID
    let tabId: UUID
    let contextPaneId: UUID?
}

enum ArrangementPanelProgrammaticPresentationFailure: Error, Equatable {
    case noActiveWindow
    case targetNotFound
    case validationRejected
}

private struct PaneInboxCommandTarget {
    let parentPaneId: UUID
    let paneIds: [UUID]
}

/// Tab-based terminal controller with custom Ghostty-style tab bar.
///
/// PaneTabViewController is a composition-oriented controller in `App/`. It reads
/// from WorkspaceStore for state and routes user actions through the validated
/// WorkspaceActionExecutor pipeline. Most flow changes are dispatched, while AppKit-only
/// concerns (focus, observers, empty-state visibility, tab bar coordination) stay
/// local. It also handles direct tab-order updates (`store.moveTab`) from drag
/// interactions as a UI-only mutation.
@MainActor
class PaneTabViewController: NSViewController, NSPopoverDelegate, WorkspaceCommandHandling {
    typealias OpenEditorHandler =
        @MainActor (_ id: EditorTargetId, _ path: URL, _ installedTargets: [ExternalEditorTarget]) -> Bool
    typealias BridgeViewerSurfaceRequestHandler =
        @MainActor (_ surface: BridgeProductSurface, _ paneId: UUID) -> Bool

    private static let logger = Logger(subsystem: "com.agentstudio", category: "PaneTabViewController")

    private enum WorkspaceNavigationFocusScope: Equatable {
        case mainRow
        case drawer(parentPaneId: UUID)
    }

    // MARK: - Dependencies (injected)

    let store: WorkspaceStore
    let pinnedPanePreferences: RepoExplorerSidebarPrefsAtom?
    private let heldPanePreviewState: HeldPanePreviewState
    private let onPreviewEligibilityLoss: @MainActor () -> Void
    private let repoCache: RepoCacheAtom
    private let applicationLifecycleMonitor: ApplicationLifecycleMonitor
    private let appLifecycleStore: AppLifecycleAtom
    private let windowLifecycleStore: WindowLifecycleAtom
    private let workspaceWindowId: UUID?
    let executor: WorkspaceActionExecutor
    let runtimeCommandDispatcher: any PaneRuntimeCommandDispatching
    private let tabBarAdapter: TabBarAdapter
    private let viewRegistry: ViewRegistry
    private let bridgePaneAttendance: BridgePaneAttendanceAtom
    private let editorChooser: EditorChooserState
    private let paneInboxPresentation: PaneInboxPresentation?
    private let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private let interactionProbe: AgentStudioInteractionPerformanceProbe?
    private var pendingTabMovePublication: PendingTabMovePublication?
    private let tabContextMenuPresenter = TabContextMenuPresenter()
    private var hasShutdown = false
    private let tabRenamePopoverState: TabRenamePopoverState
    private let arrangementInlineRenameState: ArrangementInlineRenameState
    private let arrangementPanelPresentation: ArrangementPanelPresentationAtom
    private let registersAsCommandHandler: Bool
    private var tabRenamePopover: NSPopover?
    private var paneNotePopover: NSPopover?
    private var tabRenameTransientSurfaceToken: TransientKeyboardSurfaceToken?
    private let installedEditorTargetsProvider: @MainActor () -> [ExternalEditorTarget]
    private let openEditorHandler: OpenEditorHandler
    private let openFinderHandler: @MainActor (URL) -> Bool
    private let openExternalURLHandler: @MainActor (URL) -> Bool
    private let copyPathHandler: @MainActor (URL) -> Void
    let paneNotePresentation: PaneNotePresentation
    private let bridgeViewerSurfaceRequestHandler: BridgeViewerSurfaceRequestHandler
    private let bridgeViewerOpenTelemetryAnchorFactory: @MainActor () -> BridgeViewerOpenTelemetryAnchor
    var arrangementView: WorkspaceArrangementViewDerived {
        WorkspaceArrangementViewDerived(
            tabLayoutAtom: store.tabLayoutAtom,
            paneAtom: store.paneAtom,
            managementLayerAtom: atom(\.managementLayer)
        )
    }

    var acceptsIPCCommands: Bool { !hasShutdown }

    func hasNativePaneHost(_ paneId: UUID) -> Bool {
        viewRegistry.view(for: paneId) != nil
    }

    private struct PendingTabMovePublication {
        let correlationId: UUID
        let movedTabId: UUID
        let expectedOrderedTabIds: [UUID]
    }

    private struct TabSelectionObservation: Equatable {
        let orderedTabIds: [UUID]
        let activeTabId: UUID?
        let tabGraphRevision: Int?
        let activeArrangementId: UUID?
        let activeArrangementRevision: Int?
        let activePaneId: UUID?
        let activePaneRevision: Int?
        let activeDrawerId: UUID?
        let activeDrawerRevision: Int?
    }
    private lazy var actionDispatcher = PaneTabActionDispatcher(
        dispatch: { [weak self] action in
            guard let self else {
                RestoreTrace.log(
                    "PaneTabActionDispatcher.dispatch dropped ownerReleased action=\(String(describing: action))"
                )
                return
            }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = self.dispatchPaneAction(action)
        },
        shouldHandleSplitDragPayload: { [weak self] payload in
            guard let self else {
                RestoreTrace.log("PaneTabActionDispatcher.shouldHandleSplitDragPayload dropped ownerReleased")
                return false
            }
            return self.shouldHandleSplitDragPayload(payload)
        },
        shouldAcceptDrop: { [weak self] payload, destPaneId, zone, sizingMode in
            guard let self else {
                RestoreTrace.log(
                    "PaneTabActionDispatcher.shouldAcceptDrop dropped ownerReleased destPaneId=\(destPaneId) zone=\(zone)"
                )
                return false
            }
            return self.evaluateDropAcceptance(
                payload: payload,
                destPaneId: destPaneId,
                zone: zone,
                sizingMode: sizingMode
            )
        },
        handleDrop: { [weak self] payload, destPaneId, zone, sizingMode in
            guard let self else {
                RestoreTrace.log(
                    "PaneTabActionDispatcher.handleDrop dropped ownerReleased destPaneId=\(destPaneId) zone=\(zone)"
                )
                return
            }
            self.handleSplitDrop(payload: payload, destPaneId: destPaneId, zone: zone, sizingMode: sizingMode)
        }
    )

    // MARK: - View State

    private var tabBarHostingView: DraggableTabBarHostingView!
    private let octiconLoader: OcticonLoader
    private let appEventBus: EventBus<AppEvent>
    private var terminalContainer: RestoreAwareTerminalContainerView!
    private var emptyStateView: NSHostingView<AnyView>?
    private var lastEmptyStateModel: WorkspaceEmptyStateModel?
    private var tabContentHosts: [UUID: PersistentTabHostView] = [:]
    #if DEBUG
        private(set) var paneRepresentableDismantleCount = 0
    #endif

    /// Local event monitor for arrangement bar keyboard shortcut
    private var arrangementBarEventMonitor: Any?
    private var notificationTasks: [Task<Void, Never>] = []
    private var pendingVisibleViewRestoreTask: Task<Void, Never>?

    /// Focus tracking — only refocus when the active tab or pane actually changes
    private var lastFocusedTabId: UUID?
    private var lastFocusedPaneId: UUID?
    private var suppressedSelectionDrivenRefocus: (tabId: UUID?, paneId: UUID?)?
    private var pendingBridgeAttendanceEventForNextFocus: BridgePaneAttendanceEvent?
    private var lastManagementLayerActive = false
    private var managementNavigationScope: WorkspaceNavigationFocusScope = .mainRow
    private let embedsTabBarInView: Bool
    private lazy var paneFocusExecutor = makePaneFocusExecutor()

    // MARK: - Init

    init(
        store: WorkspaceStore,
        octiconLoader: OcticonLoader,
        repoCache: RepoCacheAtom,
        applicationLifecycleMonitor: ApplicationLifecycleMonitor,
        appLifecycleStore: AppLifecycleAtom,
        windowLifecycleStore: WindowLifecycleAtom = atom(\.windowLifecycle),
        workspaceWindowId: UUID? = nil,
        executor: WorkspaceActionExecutor,
        runtimeCommandDispatcher: any PaneRuntimeCommandDispatching,
        tabBarAdapter: TabBarAdapter,
        viewRegistry: ViewRegistry,
        bridgePaneAttendance: BridgePaneAttendanceAtom,
        editorChooser: EditorChooserState,
        paneInboxPresentation: PaneInboxPresentation? = nil,
        pinnedPanePreferences: RepoExplorerSidebarPrefsAtom? = nil,
        installedEditorTargetsProvider: @escaping @MainActor () -> [ExternalEditorTarget] = {
            ExternalEditorTarget.refreshInstalledTargets()
        },
        openEditorHandler: @escaping OpenEditorHandler = { id, path, installedTargets in
            ExternalWorkspaceOpener.openInEditor(
                id: id,
                path: path,
                installedTargets: installedTargets
            )
        },
        openFinderHandler: @escaping @MainActor (URL) -> Bool = { path in
            ExternalWorkspaceOpener.openInFinder(path)
        },
        openExternalURLHandler: @escaping @MainActor (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        },
        copyPathHandler: @escaping @MainActor (URL) -> Void = { path in
            PathActions.copyPath(path)
        },
        paneNotePresentation: PaneNotePresentation? = nil,
        closeTransitionCoordinator: PaneCloseTransitionCoordinator = PaneCloseTransitionCoordinator(),
        heldPanePreviewState: HeldPanePreviewState,
        tabRenamePopoverState: TabRenamePopoverState = TabRenamePopoverState(),
        arrangementInlineRenameState: ArrangementInlineRenameState = ArrangementInlineRenameState(),
        arrangementPanelPresentation: ArrangementPanelPresentationAtom = atom(\.arrangementPanelPresentation),
        bridgeViewerSurfaceRequestHandler: BridgeViewerSurfaceRequestHandler? = nil,
        bridgeViewerOpenTelemetryAnchorFactory:
            @escaping @MainActor () -> BridgeViewerOpenTelemetryAnchor = {
                .live()
            },
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        onPreviewEligibilityLoss: @escaping @MainActor () -> Void = {},
        interactionProbe: AgentStudioInteractionPerformanceProbe? = nil,
        registersAsCommandHandler: Bool = true,
        embedsTabBarInView: Bool = true,
        appEventBus: EventBus<AppEvent> = AppEventBus.shared
    ) {
        self.store = store
        self.pinnedPanePreferences = pinnedPanePreferences
        self.heldPanePreviewState = heldPanePreviewState
        self.onPreviewEligibilityLoss = onPreviewEligibilityLoss
        self.octiconLoader = octiconLoader
        self.appEventBus = appEventBus
        self.repoCache = repoCache
        self.applicationLifecycleMonitor = applicationLifecycleMonitor
        self.appLifecycleStore = appLifecycleStore
        self.windowLifecycleStore = windowLifecycleStore
        self.workspaceWindowId = workspaceWindowId
        self.executor = executor
        self.runtimeCommandDispatcher = runtimeCommandDispatcher
        self.tabBarAdapter = tabBarAdapter
        self.viewRegistry = viewRegistry
        self.bridgePaneAttendance = bridgePaneAttendance
        self.editorChooser = editorChooser
        self.paneInboxPresentation = paneInboxPresentation
        self.installedEditorTargetsProvider = installedEditorTargetsProvider
        self.openEditorHandler = openEditorHandler
        self.openFinderHandler = openFinderHandler
        self.openExternalURLHandler = openExternalURLHandler
        self.copyPathHandler = copyPathHandler
        self.paneNotePresentation = paneNotePresentation ?? .toolbarAnchored()
        self.bridgeViewerSurfaceRequestHandler =
            bridgeViewerSurfaceRequestHandler
            ?? { surface, paneId in
                executor.requestBridgePaneSurface(surface, paneId: paneId)
            }
        self.bridgeViewerOpenTelemetryAnchorFactory = bridgeViewerOpenTelemetryAnchorFactory
        self.closeTransitionCoordinator = closeTransitionCoordinator
        self.performanceTraceRecorder = performanceTraceRecorder
        self.interactionProbe =
            interactionProbe
            ?? performanceTraceRecorder.map {
                AgentStudioInteractionPerformanceProbe(recorder: $0)
            }
        self.tabRenamePopoverState = tabRenamePopoverState
        self.arrangementInlineRenameState = arrangementInlineRenameState
        self.arrangementPanelPresentation = arrangementPanelPresentation
        self.registersAsCommandHandler = registersAsCommandHandler
        self.embedsTabBarInView = embedsTabBarInView
        super.init(nibName: nil, bundle: nil)
        setupNotificationObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    #if DEBUG
        func recordPaneRepresentableDismantleForTesting() {
            paneRepresentableDismantleCount += 1
        }
    #endif

    // MARK: - View Lifecycle

    override func loadView() {
        let containerView = NSView()
        containerView.wantsLayer = true

        // Create terminal container FIRST (so it's behind tab bar)
        terminalContainer = RestoreAwareTerminalContainerView()
        terminalContainer.wantsLayer = true
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.layer?.cornerRadius = 8
        terminalContainer.layer?.masksToBounds = true
        terminalContainer.onNonEmptyLayoutBoundsChanged = { [weak self] bounds in
            self?.applicationLifecycleMonitor.handleTerminalContainerBoundsChanged(bounds)
            self?.handleTerminalContainerBoundsChanged(reason: "terminalContainerLayout")
        }
        containerView.addSubview(terminalContainer)

        if embedsTabBarInView {
            let tabBarHostingView = makeTabBarHostingView()
            tabBarHostingView.translatesAutoresizingMaskIntoConstraints = false
            tabBarHostingView.wantsLayer = true
            containerView.addSubview(tabBarHostingView)
        }

        // Create empty state view
        let emptyView = createEmptyStateView()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(emptyView)
        self.emptyStateView = emptyView
        lastEmptyStateModel = emptyStateModel

        var constraints: [NSLayoutConstraint] = [
            terminalContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            emptyView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ]

        if embedsTabBarInView, let tabBarHostingView {
            constraints.append(contentsOf: [
                // Tab bar at top - use safeAreaLayoutGuide to respect titlebar
                tabBarHostingView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
                tabBarHostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                tabBarHostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                tabBarHostingView.heightAnchor.constraint(equalToConstant: AppStyles.Shell.TabBar.height),

                // Terminal container below tab bar
                terminalContainer.topAnchor.constraint(equalTo: tabBarHostingView.bottomAnchor),

                // Empty state fills container (respects safe area)
                emptyView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            ])
        } else {
            constraints.append(contentsOf: [
                terminalContainer.topAnchor.constraint(equalTo: containerView.topAnchor),
                emptyView.topAnchor.constraint(equalTo: containerView.topAnchor),
            ])
        }

        NSLayoutConstraint.activate(constraints)

        view = containerView
        updateEmptyState()
    }

    func makeTabBarHostingView() -> DraggableTabBarHostingView {
        if let tabBarHostingView {
            return tabBarHostingView
        }

        let tabBar = CustomTabBar(
            adapter: tabBarAdapter,
            onSelect: { [weak self] tabId in
                self?.handlePaneFocusTrigger(.tabClick(PaneTabClickFocusTrigger(targetTabId: tabId)))
            },
            canDispatchCommand: { command, tabId in
                AppCommandDispatcher.shared.canDispatch(
                    command,
                    target: tabId,
                    targetType: .tab
                )
            },
            onCommand: { [weak self] command, tabId in
                guard self != nil else { return }
                AppCommandDispatcher.shared.dispatch(
                    command,
                    target: tabId,
                    targetType: .tab
                )
            },
            onShowArrangements: { [weak self] tabId in
                self?.showTabContextMenuArrangements(tabId: tabId)
            },
            onTabFramesChanged: { [weak self] frames in
                self?.tabBarHostingView?.updateTabFrames(frames)
                self?.acknowledgeTabBarPublication(frames: frames)
            }
        )
        let hostingView = DraggableTabBarHostingView(
            rootView: tabBar,
            performanceTraceRecorder: performanceTraceRecorder
        )
        hostingView.configure(adapter: tabBarAdapter) { [weak self] fromId, insertionIndex, correlationId in
            self?.handleTabReorder(
                fromId: fromId,
                insertionIndex: insertionIndex,
                correlationId: correlationId
            )
        }
        hostingView.contextMenuRequestHandler = { [weak self, weak hostingView] tabId, event in
            guard
                let self,
                let hostingView,
                let clickedTab = self.tabBarAdapter.tabs.first(where: { $0.id == tabId })
            else { return false }
            return self.tabContextMenuPresenter.present(
                clickedTabIsSplit: clickedTab.isSplit,
                event: event,
                in: hostingView,
                canDispatchCommand: { command in
                    AppCommandDispatcher.shared.canDispatch(
                        command,
                        target: tabId,
                        targetType: .tab
                    )
                },
                onCommand: { command in
                    AppCommandDispatcher.shared.dispatch(
                        command,
                        target: tabId,
                        targetType: .tab
                    )
                },
                onShowArrangements: { [weak self] in
                    self?.showTabContextMenuArrangements(tabId: tabId)
                }
            )
        }
        hostingView.dragPayloadProvider = { [weak self] tabId in
            self?.createDragPayload(for: tabId)
        }
        hostingView.onSelect = { [weak self] tabId in
            self?.handlePaneFocusTrigger(.tabClick(PaneTabClickFocusTrigger(targetTabId: tabId)))
        }
        hostingView.expandedDrawerParentIdForTab = { [weak self] tabId in
            guard let self else { return nil }
            return DrawerDragOwnershipPolicy.expandedDrawerParentPaneId(
                tabId: tabId,
                tabLayoutAtom: self.store.tabLayoutAtom,
                paneAtom: self.store.paneAtom
            )
        }
        hostingView.onAutoDismissDrawerForDrag = { [weak self] _, drawerParentPaneId in
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = self?.dispatchPaneAction(.toggleDrawer(paneId: drawerParentPaneId))
        }
        tabBarHostingView = hostingView
        return hostingView
    }

    func makeToolbarControlView(_ control: MainToolbarControl) -> NSView {
        let content: AnyView =
            switch control {
            case .watchFolder:
                AnyView(WatchFolderTabBarMenu())
            case .managementLayer:
                AnyView(TabBarManagementLayerButton())
            case .arrangement:
                AnyView(
                    TabBarArrangementButton(
                        adapter: tabBarAdapter,
                        arrangementInlineRenameState: arrangementInlineRenameState,
                        octiconLoader: octiconLoader,
                        onCommand: { command, tabId in
                            AppCommandDispatcher.shared.dispatch(
                                command,
                                target: tabId,
                                targetType: .tab
                            )
                        },
                        onPaneAction: { [weak self] action in
                            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
                            _ = self?.dispatchPaneAction(action)
                        },
                        workspaceWindowId: workspaceWindowId
                    )
                )
            case .selectTab:
                AnyView(
                    TabSelectionToolbarMenu(adapter: tabBarAdapter) { [weak self] tabId in
                        self?.handlePaneFocusTrigger(.tabClick(PaneTabClickFocusTrigger(targetTabId: tabId)))
                    }
                )
            case .newTab:
                AnyView(NewTabButton())
            }

        let hostingView = ToolbarControlHostingView(
            rootView: AnyView(content.tint(AppStyles.General.Accent.primaryColor)))
        hostingView.identifier = control.viewIdentifier
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.safeAreaRegions = []
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
        return hostingView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if registersAsCommandHandler {
            AppCommandDispatcher.shared.handler = self
        }

        syncPaneViewRegistrySlots()
        syncTabContentHosts()
        updateVisibleTabHost()

        // Observe AppKit concerns at their narrowest owning fact sets.
        updateEmptyState()
        observeForTabSelectionState()
        observeForEmptyState()
        observeForPaneInboxMaintenance()
        observeForManagementLayerState()

        // App-owned global shortcuts route through the centralized command pipeline.
        arrangementBarEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.view.window?.isKeyWindow == true else { return event }
            if self.handleAppOwnedKeyEvent(event) {
                return nil
            }
            return event
        }

    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleAppOwnedKeyEvent(event, allowsModifiedEmptyDrawerShortcutWithTextFocus: true) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func viewWillLayout() {
        let clock = ContinuousClock()
        let layoutStart = clock.now
        super.viewWillLayout()
        syncTabContentHosts()
        updateVisibleTabHost()
        updateEmptyState()
        performanceTraceRecorder?.recordDuration(
            .paneTabLayout,
            duration: layoutStart.duration(to: clock.now),
            attributes: [
                "agentstudio.performance.pane_tab_layout.pane.count": .int(store.paneAtom.graphAtom.paneIDs.count),
                "agentstudio.performance.pane_tab_layout.tab.count": .int(store.tabLayoutAtom.tabs.count),
                "agentstudio.performance.pane_tab_layout.subview.count": .int(view.subviews.count),
                "agentstudio.performance.management_layer.is_active": .bool(atom(\.managementLayer).isActive),
            ]
        )
    }

    private func setupNotificationObservers() {
        guard notificationTasks.isEmpty else { return }
        setupAppNotificationObservers()
    }

    private func setupAppNotificationObservers() {
        notificationTasks.append(
            Task { [weak self] in
                let stream = await self?.appEventBus.subscribe(
                    policy: .criticalUnbounded,
                    subscriberName: "PaneTabViewController.terminalTermination"
                )
                guard let stream else { return }
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .terminalProcessTerminated(let paneId):
                        guard let self else { return }
                        let didHandleTermination = await MainActor.run { [weak self] in
                            self?.handleTerminalProcessTerminated(paneId: paneId) ?? false
                        }
                        if didHandleTermination {
                            await self.appEventBus.post(
                                .terminalProcessTerminationHandled(paneId: paneId)
                            )
                        }
                    case .terminalProcessTerminationHandled, .worktreeBellRang:
                        continue
                    }
                }
            })
    }

    func shutdown() {
        guard !hasShutdown else { return }
        hasShutdown = true
        tabBarAdapter.stop()
        pendingVisibleViewRestoreTask?.cancel()
        pendingVisibleViewRestoreTask = nil
        if let monitor = arrangementBarEventMonitor {
            NSEvent.removeMonitor(monitor)
            arrangementBarEventMonitor = nil
        }
        for task in notificationTasks {
            task.cancel()
        }
        notificationTasks.removeAll()
    }

    isolated deinit {
        let monitor = arrangementBarEventMonitor
        let tasks = notificationTasks
        let pendingVisibleViewRestoreTask = pendingVisibleViewRestoreTask
        pendingVisibleViewRestoreTask?.cancel()
        Task { @MainActor in
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            for task in tasks {
                task.cancel()
            }
        }
    }

    // MARK: - Store Observation (AppKit-Level Concerns)

    /// Observe only tab membership plus the active tab's keyed selection facts.
    /// SwiftUI owns pane rendering; this bridge owns AppKit host visibility and focus.
    private func observeForTabSelectionState() {
        let observedSelection = tabSelectionObservation()
        withObservationTracking {
            _ = self.store.tabShellAtom.orderedTabIds
            let activeTabId = self.store.tabShellAtom.activeTabId
            if let activeTabId {
                _ = self.store.tabArrangementAtom.graphAtom.tabStateRevision(for: activeTabId)
                _ = self.store.tabArrangementAtom.cursorAtom.activeArrangementRevision(forTab: activeTabId)
                if let activeArrangementId = self.store.tabArrangementAtom.cursorAtom.activeArrangementId(
                    forTab: activeTabId)
                {
                    _ = self.store.tabArrangementAtom.cursorAtom.paneCursorRevision(forArrangement: activeArrangementId)
                    if let activeDrawerId = self.activeDrawerId(for: activeTabId) {
                        _ = self.store.tabArrangementAtom.cursorAtom.drawerCursorRevision(
                            arrangementId: activeArrangementId, drawerId: activeDrawerId)
                    }
                }
            }
            _ = self.heldPanePreviewState.lifecycle
            _ = self.heldPanePreviewState.presentedTarget
            if let presentedTarget = self.heldPanePreviewState.presentedTarget {
                // A held preview can become ready after its tab was already
                // admitted. Observe the owning pane slot so late host
                // registration re-runs the AppKit visibility projection.
                _ = self.viewRegistry.slot(for: presentedTarget.paneID).host
            }
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if observedSelection != self.tabSelectionObservation() {
                    self.handleTabSelectionStateChange()
                } else {
                    self.updateVisibleTabHost()
                }
                self.observeForTabSelectionState()
            }
        }
    }

    private func tabSelectionObservation() -> TabSelectionObservation {
        let activeTabId = store.tabShellAtom.activeTabId
        let activeArrangementId = activeTabId.flatMap {
            store.tabArrangementAtom.cursorAtom.activeArrangementId(forTab: $0)
        }
        let activePaneId = activeTabId.flatMap { store.tabLayoutAtom.activePaneID(forTab: $0) }
        let activeDrawerId = activeTabId.flatMap { self.activeDrawerId(for: $0) }
        return TabSelectionObservation(
            orderedTabIds: store.tabShellAtom.orderedTabIds,
            activeTabId: activeTabId,
            tabGraphRevision: activeTabId.map { store.tabArrangementAtom.graphAtom.tabStateRevision(for: $0) },
            activeArrangementId: activeArrangementId,
            activeArrangementRevision: activeTabId.map {
                store.tabArrangementAtom.cursorAtom.activeArrangementRevision(forTab: $0)
            },
            activePaneId: activePaneId,
            activePaneRevision: activeArrangementId.map {
                store.tabArrangementAtom.cursorAtom.paneCursorRevision(forArrangement: $0)
            },
            activeDrawerId: activeDrawerId,
            activeDrawerRevision: activeArrangementId.flatMap { arrangementId in
                activeDrawerId.map { drawerId in
                    store.tabArrangementAtom.cursorAtom.drawerCursorRevision(
                        arrangementId: arrangementId, drawerId: drawerId)
                }
            }
        )
    }

    private func activeDrawerId(for activeTabId: UUID) -> UUID? {
        guard let paneId = store.tabLayoutAtom.activePaneID(forTab: activeTabId),
            let drawer = store.paneAtom.pane(paneId)?.drawer, drawer.isExpanded
        else { return nil }
        return drawer.drawerId
    }

    private func observeForEmptyState() {
        withObservationTracking {
            let hasTabs = !self.store.tabShellAtom.orderedTabIds.isEmpty
            if !hasTabs {
                _ = self.emptyStateModel
            }
        } onChange: {
            Task { @MainActor [weak self] in
                self?.rebuildEmptyStateView()
                self?.updateEmptyState()
                self?.observeForEmptyState()
            }
        }
    }

    private func observeForPaneInboxMaintenance() {
        withObservationTracking {
            _ = self.store.paneAtom.graphAtom.paneIDs
        } onChange: {
            Task { @MainActor [weak self] in
                self?.syncPaneViewRegistrySlots()
                self?.prunePaneInboxPresentationState()
                self?.observeForPaneInboxMaintenance()
            }
        }
    }

    private func observeForManagementLayerState() {
        withObservationTracking {
            _ = atom(\.managementLayer).isActive
        } onChange: {
            Task { @MainActor [weak self] in
                self?.handleManagementLayerStateChange()
                self?.observeForManagementLayerState()
            }
        }
    }

    private func handleTabSelectionStateChange() {
        syncTabContentHosts(orderedTabIds: store.tabShellAtom.orderedTabIds)
        updateVisibleTabHost()
        updateEmptyState()

        managementNavigationScope = normalizedWorkspaceNavigationFocusScope()

        // Focus management: only refocus when active tab or pane actually changes
        let currentTabId = store.tabLayoutAtom.activeTabId
        let currentPaneId = preferredVisibleFocusPaneId()
        let selectionChanged = currentTabId != lastFocusedTabId || currentPaneId != lastFocusedPaneId
        let activePaneViewMissing = currentPaneId.map { viewRegistry.view(for: $0) == nil } ?? false

        if selectionChanged || activePaneViewMissing {
            executor.restoreVisibleViewsForActiveTabIfNeeded()
        }

        if selectionChanged {
            lastFocusedTabId = currentTabId
            lastFocusedPaneId = currentPaneId
            if shouldSkipSelectionDrivenRefocus(currentTabId: currentTabId, currentPaneId: currentPaneId) {
                suppressedSelectionDrivenRefocus = nil
            } else {
                scheduleSelectionDrivenRefocus()
            }
        }
    }

    private func handleManagementLayerStateChange() {
        let clock = ContinuousClock()
        let start = clock.now
        let isManagementLayerActive = atom(\.managementLayer).isActive
        let didExitManagementLayer = lastManagementLayerActive && !isManagementLayerActive
        if lastManagementLayerActive != isManagementLayerActive {
            let transition: PaneModeFocusTrigger.Transition =
                isManagementLayerActive ? .enteredManagementLayer : .exitedManagementLayer
            handlePaneFocusTrigger(
                .mode(
                    PaneModeFocusTrigger(
                        transition: transition,
                        source: .command
                    )
                )
            )
        }

        if !lastManagementLayerActive && isManagementLayerActive {
            managementNavigationScope = initialWorkspaceNavigationFocusScope()
        }
        lastManagementLayerActive = isManagementLayerActive
        managementNavigationScope = normalizedWorkspaceNavigationFocusScope()

        // Management layer exit is intentionally a two-step sequence:
        // the mode trigger releases content interaction, then refocus chooses
        // the pane-specific responder target once the mode change has landed.
        if didExitManagementLayer {
            requestPaneRefocus(.managementLayerExited)
        }

        performanceTraceRecorder?.recordDuration(
            .managementLayerAppKitState,
            duration: start.duration(to: clock.now),
            attributes: [
                "agentstudio.performance.management_layer.is_active": .bool(isManagementLayerActive),
                "agentstudio.performance.management_layer.did_exit": .bool(didExitManagementLayer),
            ]
        )
    }

    private func prunePaneInboxPresentationState() {
        guard let paneInboxPresentation else { return }
        let paneGraph = store.paneAtom.graphAtom
        let retainedParentPaneIds = Set<UUID>(
            paneGraph.paneIDs.compactMap { paneID in
                guard paneGraph.paneStructuralFacts(paneID)?.isDrawerChild == false else { return nil }
                return paneID
            }
        )
        paneInboxPresentation.pruneFilterModes(retainedParentPaneIds)
    }

    private func preferredVisibleFocusPaneId() -> UUID? {
        switch normalizedWorkspaceNavigationScopeState() {
        case .drawerPane(_, let drawerPaneId):
            return drawerPaneId
        case .emptyDrawer:
            return nil
        case .mainPane(let paneId):
            return paneId
        }
    }

    private func scheduleSelectionDrivenRefocus() {
        // Tab host visibility changes land after the active-tab mutation, so
        // refocus on the next main-actor turn instead of racing the hidden host.
        Task { @MainActor [weak self] in
            self?.requestPaneRefocus(.explicit)
        }
    }

    private func makePaneFocusExecutor() -> PaneFocusExecutor {
        PaneFocusExecutor(
            hostViewProvider: { [weak self] paneId in
                self?.viewRegistry.view(for: paneId)
            },
            hostViewsProvider: { [weak self] in
                guard let self else { return [] }
                return self.viewRegistry.registeredPaneIds.compactMap { self.viewRegistry.view(for: $0) }
            },
            selectTab: { [weak self] tabId in
                guard let self else { return }
                self.selectTabAndRestoreVisibleViews(tabId)
                self.restoreFocusOwnerForSelectedTab()
            },
            selectPane: { [weak self] tabId, paneId in
                guard let self else { return }
                self.recordSelectionDrivenRefocusSuppression(tabId: tabId, paneId: paneId)
                if self.store.tabLayoutAtom.activeTabId != tabId {
                    self.selectTabAndRestoreVisibleViews(tabId)
                }
                self.revealArrangementContainingPane(tabId: tabId, paneId: paneId)
                if let tab = self.store.tabLayoutAtom.tab(tabId),
                    tab.activeMinimizedPaneIds.contains(paneId)
                {
                    // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
                    _ = self.dispatchGesture { execute in
                        guard await execute(.expandPane(tabId: tabId, paneId: paneId)) else { return false }
                        self.store.tabLayoutAtom.setActivePane(paneId, inTab: tabId)
                        atom(\.workspaceFocusOwner).focusMainPane(paneId)
                        self.managementNavigationScope = .mainRow
                        return true
                    }
                    return
                }
                self.store.tabLayoutAtom.setActivePane(paneId, inTab: tabId)
                atom(\.workspaceFocusOwner).focusMainPane(paneId)
                self.managementNavigationScope = .mainRow
            },
            selectDrawerPane: { [weak self] parentPaneId, drawerPaneId in
                guard let self else { return }
                self.recordSelectionDrivenRefocusSuppression(
                    tabId: self.store.tabLayoutAtom.activeTabId,
                    paneId: drawerPaneId
                )
                if let tabId = self.store.tabLayoutAtom.tabContaining(paneId: parentPaneId)?.id,
                    let drawerId = self.store.paneAtom.pane(parentPaneId)?.drawer?.drawerId
                {
                    self.store.tabArrangementAtom.setActiveDrawerPane(drawerPaneId, drawerId: drawerId, inTab: tabId)
                }
                atom(\.workspaceFocusOwner).focusDrawerPane(
                    parentPaneId: parentPaneId,
                    paneId: drawerPaneId
                )
                self.managementNavigationScope = .drawer(parentPaneId: parentPaneId)
            },
            selectEmptyDrawer: { [weak self] parentPaneId in
                guard let self else { return }
                atom(\.workspaceFocusOwner).focusEmptyDrawer(parentPaneId: parentPaneId)
                self.managementNavigationScope = .drawer(parentPaneId: parentPaneId)
                _ = self.clearFirstResponderToWindowContentForDrawer(parentPaneId: parentPaneId)
            },
            syncRuntimeFocus: { surfaceId in
                SurfaceManager.shared.syncFocus(activeSurfaceId: surfaceId)
            }
        )
    }

    private func selectTabAndRestoreVisibleViews(_ tabId: UUID) {
        store.tabLayoutAtom.setActiveTab(tabId)
        executor.restoreVisibleViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)
    }

    private func restoreFocusOwnerForSelectedTab() {
        guard let parentPaneId = activeMainPaneId() else {
            applyWorkspaceFocusOwner(.mainPane(paneId: nil))
            return
        }

        let requestedFocusOwner: WorkspaceFocusOwner =
            if store.paneAtom.pane(parentPaneId)?.drawer?.isExpanded == true {
                .emptyDrawer(parentPaneId: parentPaneId)
            } else {
                .mainPane(paneId: parentPaneId)
            }

        applyWorkspaceFocusOwner(
            WorkspaceFocusOwnerNormalizer.normalize(
                requested: requestedFocusOwner,
                context: currentWorkspaceFocusOwnerContext()
            )
        )
    }

    private func applyWorkspaceFocusOwner(_ owner: WorkspaceFocusOwner) {
        switch owner {
        case .mainPane(let paneId):
            atom(\.workspaceFocusOwner).focusMainPane(paneId)
            managementNavigationScope = .mainRow
        case .drawerPane(let parentPaneId, let drawerPaneId):
            atom(\.workspaceFocusOwner).focusDrawerPane(parentPaneId: parentPaneId, paneId: drawerPaneId)
            managementNavigationScope = .drawer(parentPaneId: parentPaneId)
        case .emptyDrawer(let parentPaneId):
            atom(\.workspaceFocusOwner).focusEmptyDrawer(parentPaneId: parentPaneId)
            managementNavigationScope = .drawer(parentPaneId: parentPaneId)
            _ = clearFirstResponderToWindowContentForDrawer(parentPaneId: parentPaneId)
        }
    }

    private func recordSelectionDrivenRefocusSuppression(tabId: UUID?, paneId: UUID?) {
        suppressedSelectionDrivenRefocus = (tabId, paneId)
    }

    private func shouldSkipSelectionDrivenRefocus(currentTabId: UUID?, currentPaneId: UUID?) -> Bool {
        suppressedSelectionDrivenRefocus?.tabId == currentTabId
            && suppressedSelectionDrivenRefocus?.paneId == currentPaneId
    }

    func handlePaneFocusTrigger(_ trigger: PaneFocusTrigger) {
        _ = applyPaneFocusTrigger(trigger)
    }

    private func applyPaneFocusTrigger(_ trigger: PaneFocusTrigger) -> Bool {
        if trigger.isUserFocusInteraction {
            executor.clearPendingPaneRefocusRequestsAfterUserFocusChange()
        }
        let bridgeAttendanceEvent = pendingBridgeAttendanceEventForNextFocus ?? bridgeAttendanceEvent(for: trigger)
        pendingBridgeAttendanceEventForNextFocus = nil
        guard let context = makePaneFocusContext(for: trigger) else {
            Self.logger.warning(
                "Pane focus trigger dropped because context assembly failed trigger=\(String(describing: trigger), privacy: .public)"
            )
            return false
        }
        let decision = PaneFocusOrchestrator.decide(trigger: trigger, context: context)
        guard paneFocusExecutor.apply(decision) else {
            Self.logger.warning(
                "Pane focus apply returned false for trigger \(String(describing: trigger), privacy: .public)")
            return false
        }
        if trigger.isUserFocusInteraction {
            performanceTraceRecorder?.recordFocusResponderChange(reason: .userClick)
        }
        if let bridgeAttendanceEvent,
            let paneId = context.targetPaneId,
            let pane = store.paneAtom.pane(paneId),
            pane.residency == .active,
            case .bridgePanel = pane.content
        {
            bridgePaneAttendance.record(bridgeAttendanceEvent, for: paneId)
        }
        return true
    }

    private func bridgeAttendanceEvent(for trigger: PaneFocusTrigger) -> BridgePaneAttendanceEvent? {
        switch trigger {
        case .contentClick, .keyboard:
            return .paneFocus
        case .tabClick:
            return .tabActivation
        case .drawer(let drawerTrigger):
            if case .selectPane = drawerTrigger { return .paneFocus }
            return nil
        case .command(let commandTrigger):
            switch commandTrigger {
            case .focusPane:
                return .paneFocus
            case .selectTab:
                return .tabActivation
            case .paneCreated:
                return .newTabCreation
            }
        case .mode, .refocusRequest:
            return nil
        }
    }

    func requestPaneRefocus(_ reason: PaneRefocusRequestTrigger.Reason = .explicit) {
        handlePaneFocusTrigger(.refocusRequest(PaneRefocusRequestTrigger(reason: reason)))
    }

    private func makePaneFocusContext(for trigger: PaneFocusTrigger) -> PaneFocusContext? {
        let activeTabId = store.tabLayoutAtom.activeTabId
        let activePaneId = preferredVisibleFocusPaneId()
        let targetTabId = paneFocusTargetTabId(for: trigger, activeTabId: activeTabId)
        let targetPaneId = paneFocusTargetPaneId(
            for: trigger,
            targetTabId: targetTabId,
            activePaneId: activePaneId
        )
        guard targetPaneId == nil || targetTabId != nil else {
            return nil
        }
        let targetPaneKind = PaneFocusContext.PaneKind(
            content: targetPaneId.flatMap { store.paneAtom.pane($0)?.content }
        )
        let targetMountedContent =
            targetPaneId
            .flatMap { viewRegistry.view(for: $0)?.mountedContentStateForPaneFocus }
            ?? .unmounted
        let activeDrawerParentPaneId = activeMainPaneId()

        return PaneFocusContext(
            activeTabId: activeTabId,
            activePaneId: activePaneId,
            activeDrawer: activeDrawerParentPaneId.map {
                .init(
                    parentPaneId: $0,
                    paneId: visibleActiveDrawerPaneId(for: $0),
                    isEmpty: store.paneAtom.pane($0)?.drawer?.paneIds.isEmpty == true
                )
            },
            targetPaneId: targetPaneId,
            targetTabId: targetTabId,
            targetPaneKind: targetPaneKind,
            targetPaneIsAlreadyActive: paneFocusTargetIsAlreadyActive(
                trigger: trigger,
                targetPaneId: targetPaneId,
                activePaneId: activePaneId,
                activeTabId: activeTabId
            ),
            targetMountedContent: targetMountedContent,
            managementLayer: atom(\.managementLayer).isActive
                ? .active(scope: paneFocusManagementScope)
                : .inactive,
            windowState: paneFocusWindowState(for: targetPaneId)
        )
    }

    private var paneFocusManagementScope: PaneManagementFocusScope {
        switch managementNavigationScope {
        case .mainRow:
            return .mainRow
        case .drawer(let parentPaneId):
            return .drawer(parentPaneId: parentPaneId)
        }
    }

    private func paneFocusTargetTabId(for trigger: PaneFocusTrigger, activeTabId: UUID?) -> UUID? {
        switch trigger {
        case .contentClick(let trigger):
            return store.tabLayoutAtom.tabs.first { $0.paneIds.contains(trigger.targetPaneId) }?.id
        case .tabClick(let trigger):
            return trigger.targetTabId
        case .drawer:
            return activeTabId
        case .keyboard(let trigger):
            switch trigger {
            case .moveToPane(let tabId, _, _):
                return tabId
            }
        case .mode, .refocusRequest:
            return activeTabId
        case .command(let trigger):
            switch trigger {
            case .focusPane(let tabId, _):
                return tabId
            case .selectTab(let tabId):
                return tabId
            case .paneCreated:
                return activeTabId
            }
        }
    }

    private func paneFocusTargetPaneId(
        for trigger: PaneFocusTrigger,
        targetTabId: UUID?,
        activePaneId: UUID?
    ) -> UUID? {
        switch trigger {
        case .contentClick(let trigger):
            return trigger.targetPaneId
        case .tabClick:
            return targetTabId.flatMap { store.tabLayoutAtom.tab($0) }?.activePaneId
        case .drawer(let trigger):
            switch trigger {
            case .selectPane(_, let drawerPaneId):
                return drawerPaneId
            case .toggle(let parentPaneId):
                return parentPaneId
            }
        case .keyboard(let trigger):
            switch trigger {
            case .moveToPane(_, let paneId, _):
                return paneId
            }
        case .mode:
            return activePaneId
        case .refocusRequest:
            return activePaneId
        case .command(let trigger):
            switch trigger {
            case .focusPane(_, let paneId), .paneCreated(let paneId, _):
                return paneId
            case .selectTab(let tabId):
                return store.tabLayoutAtom.tab(tabId)?.activePaneId
            }
        }
    }

    private func paneFocusTargetIsAlreadyActive(
        trigger: PaneFocusTrigger,
        targetPaneId: UUID?,
        activePaneId: UUID?,
        activeTabId: UUID?
    ) -> Bool {
        switch trigger {
        case .tabClick(let trigger):
            return activeTabId == trigger.targetTabId
        case .drawer(let trigger):
            switch trigger {
            case .selectPane(_, let drawerPaneId):
                return activeMainPaneId().flatMap { visibleActiveDrawerPaneId(for: $0) } == drawerPaneId
            case .toggle(let parentPaneId):
                return activePaneId == parentPaneId
            }
        default:
            return activePaneId == targetPaneId
        }
    }

    private func paneFocusWindowState(for paneId: UUID?) -> PaneFocusContext.WindowState {
        let window = paneId.flatMap { viewRegistry.view(for: $0)?.window } ?? view.window
        guard let window else { return .background }
        if window.isKeyWindow {
            return .key
        }
        if window.isMainWindow {
            return .focused
        }
        return .background
    }

    private func normalizedWorkspaceNavigationFocusScope() -> WorkspaceNavigationFocusScope {
        guard case .drawer(let parentPaneId) = managementNavigationScope else {
            return managementNavigationScope
        }
        guard
            let activeTabId = store.tabLayoutAtom.activeTabId,
            let activePaneId = store.tabLayoutAtom.tab(activeTabId)?.activePaneId,
            activePaneId == parentPaneId,
            let drawer = store.paneAtom.pane(parentPaneId)?.drawer,
            drawer.isExpanded
        else {
            return .mainRow
        }
        return managementNavigationScope
    }

    func normalizedWorkspaceNavigationScopeState() -> WorkspaceFocusOwner {
        WorkspaceFocusOwnerNormalizer.normalize(
            requested: atom(\.workspaceFocusOwner).owner,
            context: currentWorkspaceFocusOwnerContext()
        )
    }

    @discardableResult
    private func clearFirstResponderToWindowContentForDrawer(parentPaneId: UUID) -> Bool {
        let window = viewRegistry.view(for: parentPaneId)?.window ?? view.window ?? NSApp.keyWindow
        guard let window, let contentView = window.contentView else { return false }
        return window.makeFirstResponder(contentView)
    }

    private func currentWorkspaceFocusOwnerContext() -> WorkspaceFocusOwnerNormalizer.Context {
        let activeMainPaneId = activeMainPaneId()
        let drawer = activeMainPaneId.flatMap { store.paneAtom.pane($0)?.drawer }
        let drawerView = activeMainPaneId.flatMap { arrangementView.drawerView(forParent: $0) }
        return .init(
            activeMainPaneId: activeMainPaneId,
            expandedDrawerParentPaneId: drawer?.isExpanded == true ? activeMainPaneId : nil,
            paneIds: drawer?.paneIds ?? [],
            activeDrawerPaneId: drawerView?.activeChildId,
            minimizedDrawerPaneIds: drawerView?.minimizedPaneIds ?? []
        )
    }

    private func syncFocusOwnerAfterDrawerMutation(parentPaneId: UUID) {
        guard let drawer = store.paneAtom.pane(parentPaneId)?.drawer else { return }

        if drawer.isExpanded {
            managementNavigationScope = .drawer(parentPaneId: parentPaneId)
            let drawerView = arrangementView.drawerView(forParent: parentPaneId)
            if let drawerPaneId = drawerView?.activeChildId,
                drawerView?.minimizedPaneIds.contains(drawerPaneId) == false
            {
                atom(\.workspaceFocusOwner).focusDrawerPane(parentPaneId: parentPaneId, paneId: drawerPaneId)
            } else {
                atom(\.workspaceFocusOwner).focusEmptyDrawer(parentPaneId: parentPaneId)
                _ = clearFirstResponderToWindowContentForDrawer(parentPaneId: parentPaneId)
            }
        } else {
            managementNavigationScope = .mainRow
            atom(\.workspaceFocusOwner).focusMainPane(parentPaneId)
        }
    }

    private func drawerParentByPaneId() -> [UUID: UUID] {
        Dictionary(
            uniqueKeysWithValues: store.paneAtom.graphAtom.paneIDs.compactMap { paneID in
                guard let parentPaneID = store.paneAtom.graphAtom.paneStructuralFacts(paneID)?.parentPaneID else {
                    return nil
                }
                return (paneID, parentPaneID)
            }
        )
    }

    private func drawerLayoutByParentPaneId() -> [UUID: DrawerGridLayout] {
        Dictionary(
            uniqueKeysWithValues: store.paneAtom.graphAtom.paneIDs.compactMap { paneID in
                guard
                    store.paneAtom.graphAtom.paneStructuralFacts(paneID)?.ownedDrawerID != nil,
                    let drawerView = arrangementView.drawerView(forParent: paneID)
                else {
                    return nil
                }
                return (paneID, drawerView.layout)
            }
        )
    }

    private func visibleActiveDrawerPaneId(for parentPaneId: UUID) -> UUID? {
        guard let drawer = store.paneAtom.pane(parentPaneId)?.drawer else { return nil }
        guard drawer.isExpanded else { return nil }
        guard let drawerView = arrangementView.drawerView(forParent: parentPaneId),
            let drawerPaneId = drawerView.activeChildId
        else { return nil }
        guard !drawerView.minimizedPaneIds.contains(drawerPaneId) else { return nil }
        return drawerPaneId
    }

    // MARK: - Tab Content Hosts

    private func buildTabContentHost(for tabId: UUID) -> PersistentTabHostView {
        if let tab = store.tabLayoutAtom.tab(tabId) {
            for paneId in tab.allPaneIds {
                viewRegistry.ensureSlot(for: paneId)
            }
        }
        let contentView = SingleTabContent(
            tabId: tabId,
            octiconLoader: octiconLoader,
            store: store,
            repoCache: repoCache,
            editorChooser: editorChooser,
            viewRegistry: viewRegistry,
            heldPanePreviewState: heldPanePreviewState,
            appLifecycleStore: appLifecycleStore,
            closeTransitionCoordinator: closeTransitionCoordinator,
            actionDispatcher: actionDispatcher,
            arrangementInlineRenameState: arrangementInlineRenameState,
            onPaneFocusTrigger: { [weak self] trigger in
                self?.handlePaneFocusTrigger(trigger)
            },
            onFocusPane: { [weak self] paneId in
                self?.handlePaneFocusTrigger(
                    .command(.focusPane(tabId: tabId, paneId: paneId))
                )
            },
            paneInboxPresentation: paneInboxPresentation,
            paneNotePresentation: paneNotePresentation,
            onOpenPaneGitHub: { [weak self] paneId in
                self?.openGitHubWebview(for: paneId)
            },
            workspaceWindowId: workspaceWindowId,
            paneSurfaceToolbarPresentation: { [weak self] paneId in
                self?.normalPaneSurfaceToolbarPresentation(for: paneId) ?? .hidden
            },
            zoomPaneSurfaceToolbarPresentation: { [weak self] paneId, viewerPresentation in
                self?.zoomPaneSurfaceToolbarPresentation(
                    for: paneId,
                    viewerPresentation: viewerPresentation
                ) ?? .hidden
            },
            interactionProbe: interactionProbe
        )

        return PersistentTabHostView(tabId: tabId, rootView: contentView)
    }

    func normalPaneSurfaceToolbarPresentation(
        for paneId: UUID
    ) -> PaneSurfaceToolbarPresentation {
        guard
            let paneState = store.paneAtom.graphAtom.paneState(paneId),
            !paneState.isDrawerChild,
            let tabId = store.tabLayoutAtom.tabID(containingPane: paneId)
        else {
            return .hidden
        }

        let terminalModeActions: TerminalModeToolbarActions?
        if case .terminal = paneState.paneContent {
            terminalModeActions = TerminalModeToolbarActions(
                zoomAction: paneSurfaceToolbarAction(
                    command: .zoomPane,
                    sourcePaneId: paneId,
                    surface: .pane
                ),
                viewerAction: paneSurfaceToolbarAction(
                    command: .showViewer,
                    sourcePaneId: paneId,
                    surface: .pane
                )
            )
        } else {
            terminalModeActions = nil
        }

        return PaneSurfaceToolbarResolver.resolve(
            content: paneState.paneContent,
            placement: .normalMainPane,
            terminalModeActions: terminalModeActions,
            showArrangementsAction: paneShowArrangementsAction(
                sourcePaneId: paneId,
                sourceTabId: tabId
            )
        )
    }

    func zoomPaneSurfaceToolbarPresentation(
        for paneId: UUID,
        viewerPresentation: ZoomViewerPresentation
    ) -> PaneSurfaceToolbarPresentation {
        guard let tabId = store.tabLayoutAtom.tabID(containingPane: paneId) else {
            return .hidden
        }
        return PaneSurfaceToolbarResolver.resolveZoom(
            viewerPresentation: viewerPresentation,
            viewerAction: paneSurfaceToolbarAction(
                command: .showViewer,
                sourcePaneId: paneId,
                surface: .terminalZoom
            ),
            zoomAction: paneSurfaceToolbarAction(
                command: .zoomPane,
                sourcePaneId: paneId,
                surface: .terminalZoom
            ),
            showArrangementsAction: paneShowArrangementsAction(
                sourcePaneId: paneId,
                sourceTabId: tabId
            )
        )
    }

    private func paneSurfaceToolbarAction(
        command: AppCommand,
        sourcePaneId: UUID,
        surface: AppCommandToolbarSurface
    ) -> PaneSurfaceToolbarAction? {
        let definition = command.definition
        guard
            definition.shouldPresent(
                AppCommandPresentationQuery(
                    surface: .toolbar(surface),
                    subject: .targeted(.pane)
                )
            )
        else {
            return nil
        }

        let dispatcher = AppCommandDispatcher.shared
        let isEnabled = dispatcher.canDispatch(
            command,
            target: sourcePaneId,
            targetType: .pane
        )
        return PaneSurfaceToolbarAction(
            state: PaneSurfaceToolbarAction.State(
                label: definition.label,
                accessibilityIdentifier: paneSurfaceToolbarAccessibilityIdentifier(for: command),
                icon: definition.icon,
                tooltip: definition.controlTooltipRenderValue(),
                isEnabled: isEnabled,
                isSelected: false
            ),
            perform: {
                dispatcher.dispatch(
                    command,
                    target: sourcePaneId,
                    targetType: .pane
                )
            }
        )
    }

    package func canExecutePaneSurfaceViewerCommand(sourcePaneId: UUID) -> Bool {
        if canExecute(.showViewer, target: sourcePaneId, targetType: .pane) {
            return true
        }
        return zoomCommandCapability(explicitPaneId: sourcePaneId) != nil
    }

    private func executePaneSurfaceViewerCommand(sourcePaneId: UUID) -> Bool {
        guard canExecutePaneSurfaceViewerCommand(sourcePaneId: sourcePaneId) else { return false }
        // fire-and-forget: this function reports command admission; the executor serializes the gesture outcome
        _ = dispatchGesture { [self] execute in
            switch executeZoomLocalViewerCommand(explicitPaneId: sourcePaneId) {
            case .notZoomLocal:
                return await enterZoomAndShowViewerAfterAdmission(
                    explicitPaneId: sourcePaneId,
                    execute: execute
                )
            case .toggled(let didToggle):
                return didToggle
            }
        }
        return true
    }

    func paneShowArrangementsAction(
        sourcePaneId: UUID,
        sourceTabId: UUID
    ) -> PaneSurfaceToolbarAction {
        let actionSpec = LocalActionSpec.showArrangements.actionSpec
        let isEnabled =
            store.tabLayoutAtom.tab(sourceTabId)?.activePaneIds.contains(sourcePaneId) == true

        return PaneSurfaceToolbarAction(
            state: PaneSurfaceToolbarAction.State(
                label: actionSpec.label,
                accessibilityIdentifier: "paneManagement.showArrangements",
                icon: actionSpec.icon,
                tooltip: actionSpec.controlTooltipRenderValue(
                    provenance: .localAction(rawValue: "paneShowArrangements"),
                    shortcutText: AppShortcut.showArrangementPanel.spec.trigger.displayText
                ),
                isEnabled: isEnabled,
                isSelected: false
            ),
            perform: { [weak self] in
                self?.requestArrangementPanel(
                    tabId: sourceTabId,
                    contextPaneId: sourcePaneId
                )
            }
        )
    }

    private func paneSurfaceToolbarAccessibilityIdentifier(
        for command: AppCommand
    ) -> String {
        switch command {
        case .zoomPane:
            "paneSurfaceToolbar.zoom"
        case .showViewer:
            "paneSurfaceToolbar.viewer"
        default:
            "paneSurfaceToolbar.\(command.rawValue)"
        }
    }

    private func syncTabContentHosts(
        orderedTabIds: [UUID]? = nil
    ) {
        let orderedTabIds = orderedTabIds ?? store.tabShellAtom.orderedTabIds
        let liveTabIds = Set(orderedTabIds)
        guard liveTabIds != Set(tabContentHosts.keys) else { return }

        for tabId in orderedTabIds where tabContentHosts[tabId] == nil {
            let host = buildTabContentHost(for: tabId)
            terminalContainer.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                host.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                host.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            ])
            tabContentHosts[tabId] = host
        }

        for (tabId, host) in tabContentHosts where !liveTabIds.contains(tabId) {
            host.removeFromSuperview()
            tabContentHosts.removeValue(forKey: tabId)
        }
    }

    private func syncPaneViewRegistrySlots() {
        for paneId in store.paneAtom.graphAtom.paneIDs {
            viewRegistry.ensureSlot(for: paneId)
        }
    }

    private func updateVisibleTabHost() {
        let activeTabId = store.tabLayoutAtom.activeTabId
        let visibleTabId: UUID? = {
            guard heldPanePreviewState.isHeld,
                let target = heldPanePreviewState.presentedTarget,
                let pane = store.paneAtom.pane(target.paneID),
                viewRegistry.view(for: target.paneID) != nil,
                store.tabLayoutAtom.tabID(containingPane: pane.parentPaneId ?? pane.id)
                    == target.owningTabID,
                pane.provider == target.provider,
                pane.terminalState?.zmxSessionID == target.sessionID
            else {
                return activeTabId
            }
            return target.owningTabID
        }()
        for (tabId, host) in tabContentHosts {
            host.isHidden = tabId != visibleTabId
        }
    }

    private func activeTabHost() -> PersistentTabHostView? {
        guard let activeTabId = store.tabLayoutAtom.activeTabId else { return nil }
        return tabContentHosts[activeTabId]
    }

    func sidebarPerformanceProofTabReadback(
        window: NSWindow?
    ) -> SidebarPerformanceProofTabReadback {
        let orderedTabIDs = store.tabShellAtom.orderedTabIds
        let activeTabID = store.tabLayoutAtom.activeTabId
        let activePaneID = activeTabID.flatMap { store.tabLayoutAtom.tab($0)?.activePaneId }
        let activePaneIDByTabID = Dictionary(
            uniqueKeysWithValues: orderedTabIDs.compactMap { tabID in
                store.tabLayoutAtom.tab(tabID)?.activePaneId.map { (tabID, $0) }
            }
        )
        let activeHost = activeTabID.flatMap { tabContentHosts[$0] }
        let activePaneView = activePaneID.flatMap { viewRegistry.view(for: $0) }
        let responderView = window?.firstResponder as? NSView

        return SidebarPerformanceProofTabReadback(
            orderedTabIDs: orderedTabIDs,
            activeTabID: activeTabID,
            activePaneID: activePaneID,
            activePaneIDByTabID: activePaneIDByTabID,
            nativeActiveTabIsVisible: activeHost.map(Self.isEffectivelyVisible) ?? false,
            nativeActivePaneIsVisible: activePaneView.map(Self.isEffectivelyVisible) ?? false,
            nativeActivePaneHasFocus: activePaneView.map { paneView in
                responderView.map { responder in
                    responder === paneView || responder.isDescendant(of: paneView)
                } ?? false
            } ?? false
        )
    }

    private static func isEffectivelyVisible(_ view: NSView) -> Bool {
        guard view.window != nil, !view.frame.isEmpty else { return false }
        var currentView: NSView? = view
        while let candidate = currentView {
            if candidate.isHidden { return false }
            currentView = candidate.superview
        }
        return true
    }

    private func handleTerminalContainerBoundsChanged(reason: StaticString) {
        let terminalContainerBounds = terminalContainer?.bounds ?? .zero
        RestoreTrace.log(
            "PaneTabViewController terminalContainerBoundsChanged reason=\(reason) bounds=\(NSStringFromRect(terminalContainerBounds))"
        )
        RestoreTrace.log(geometryHierarchySnapshot(reason: reason))
        executor.reevaluatePreparedTerminalGeometry()
        scheduleVisibleViewRestoreAfterLayout(reason: reason)
    }

    private func scheduleVisibleViewRestoreAfterLayout(reason: StaticString) {
        if AgentStudioStartupDiagnosticAction.fromEnvironment()?.suppressesAutomaticLaunchPaneRestore == true {
            RestoreTrace.log(
                "PaneTabViewController skipped visible view restore for startup diagnostic reason=\(reason)")
            return
        }
        pendingVisibleViewRestoreTask?.cancel()
        pendingVisibleViewRestoreTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.executor.restoreVisibleViewsForActiveTabIfNeeded()
            self.syncVisibleTerminalGeometry(reason: reason)
            self.pendingVisibleViewRestoreTask = nil
        }
    }

    func syncVisibleTerminalGeometry(reason: StaticString) {
        let traceClock = performanceTraceRecorder?.isEnabled == true ? ContinuousClock() : nil
        let syncStart = traceClock?.now
        let visibleTerminalViews = visibleTerminalPaneIdsForActiveTab().compactMap {
            viewRegistry.terminalView(for: $0)
        }.filter { terminalView in
            terminalView.window != nil && !terminalView.isHidden
        }
        guard !visibleTerminalViews.isEmpty else { return }
        RestoreTrace.log(
            "PaneTabViewController.syncVisibleTerminalGeometry reason=\(reason) count=\(visibleTerminalViews.count)"
        )
        for terminalView in visibleTerminalViews {
            terminalView.forceGeometrySync(reason: reason)
        }
        guard let traceClock, let syncStart else { return }
        performanceTraceRecorder?.recordDuration(
            .terminalGeometrySync,
            duration: syncStart.duration(to: traceClock.now),
            attributes: [
                "agentstudio.performance.terminal.geometry.reason": .string("\(reason)"),
                "agentstudio.performance.terminal.geometry.visible_terminal.count": .double(
                    Double(visibleTerminalViews.count)),
            ]
        )
    }

    func visibleTerminalPaneIdsForActiveTab() -> [UUID] {
        guard let activeTabId = store.tabLayoutAtom.activeTabId,
            let tab = store.tabLayoutAtom.tab(activeTabId)
        else { return [] }

        var seenPaneIds: Set<UUID> = []
        var paneIds: [UUID] = []
        func append(_ candidatePaneId: UUID) {
            guard seenPaneIds.insert(candidatePaneId).inserted else { return }
            paneIds.append(candidatePaneId)
        }

        for paneId in tab.activeArrangement.layout.paneIds {
            append(paneId)
            guard let drawer = store.paneAtom.pane(paneId)?.drawer, drawer.isExpanded else { continue }
            guard let drawerView = tab.activeArrangement.drawerViews[drawer.drawerId] else { continue }
            for drawerPaneId in drawerView.layout.paneIds where !drawerView.minimizedPaneIds.contains(drawerPaneId) {
                append(drawerPaneId)
            }
        }

        return paneIds
    }

    func geometryHierarchySnapshot(reason: StaticString) -> String {
        let rootFrame = isViewLoaded ? NSStringFromRect(view.frame) : "nil"
        let rootBounds = isViewLoaded ? NSStringFromRect(view.bounds) : "nil"
        let terminalFrame = terminalContainer.map { NSStringFromRect($0.frame) } ?? "nil"
        let terminalBounds = terminalContainer.map { NSStringFromRect($0.bounds) } ?? "nil"
        let hostingFrame = activeTabHost().map { NSStringFromRect($0.frame) } ?? "nil"
        let hostingBounds = activeTabHost().map { NSStringFromRect($0.bounds) } ?? "nil"
        let tabBarFrame = tabBarHostingView.map { NSStringFromRect($0.frame) } ?? "nil"
        return
            "PaneTabViewController.geometry reason=\(reason) viewFrame=\(rootFrame) viewBounds=\(rootBounds) terminalFrame=\(terminalFrame) terminalBounds=\(terminalBounds) hostingFrame=\(hostingFrame) hostingBounds=\(hostingBounds) tabBarFrame=\(tabBarFrame)"
    }

    /// Evaluate whether a drop is acceptable at the given pane and zone.
    private func evaluateDropAcceptance(
        payload: SplitDropPayload,
        destPaneId: UUID,
        zone: DropZoneSide,
        sizingMode: DropSizingMode
    ) -> Bool {
        guard shouldHandleSplitDragPayload(payload) else {
            return false
        }
        let snapshot = dragDropSnapshot()
        return Self.splitDropCommitPlan(
            payload: payload,
            destination: SplitDropCommitDestination(
                paneId: destPaneId,
                drawerParentPaneId: store.paneAtom.pane(destPaneId)?.parentPaneId
            ),
            zone: zone,
            sizingMode: sizingMode,
            activeTabId: store.tabLayoutAtom.activeTabId,
            state: snapshot
        ) != nil
    }

    /// Handle a completed drop on a split pane.
    private func handleSplitDrop(
        payload: SplitDropPayload,
        destPaneId: UUID,
        zone: DropZoneSide,
        sizingMode: DropSizingMode
    ) {
        guard shouldHandleSplitDragPayload(payload) else {
            return
        }
        let snapshot = dragDropSnapshot()
        guard
            let plan = Self.splitDropCommitPlan(
                payload: payload,
                destination: SplitDropCommitDestination(
                    paneId: destPaneId,
                    drawerParentPaneId: store.paneAtom.pane(destPaneId)?.parentPaneId
                ),
                zone: zone,
                sizingMode: sizingMode,
                activeTabId: store.tabLayoutAtom.activeTabId,
                state: snapshot
            )
        else {
            return
        }
        executeDropCommitPlan(plan)
    }

    private func dragDropSnapshot() -> ActionStateSnapshot {
        WorkspaceCommandResolver.snapshot(
            from: store.tabLayoutAtom.tabs,
            activeTabId: store.tabLayoutAtom.activeTabId,
            isManagementLayerActive: atom(\.managementLayer).isActive,
            zoomSourcePaneIdByTabId: store.panePresentationAtom.zoomPresentationsByTabId.mapValues(
                \.sourcePaneId
            ),
            knownRepoIds: Set(store.repositoryTopologyAtom.repos.map(\.id)),
            knownWorktreeIds: store.repositoryTopologyAtom.availableWorktreeIDs,
            knownPaneIds: store.paneAtom.graphAtom.paneIDs,
            drawerParentByPaneId: drawerParentByPaneId(),
            drawerLayoutByParentPaneId: drawerLayoutByParentPaneId(),
            visiblePaneIds: { [arrangementView] tab in
                arrangementView.activeVisiblePaneIds(forTab: tab.id)
            }
        )
    }

    private func executeDropCommitPlan(_ plan: DropCommitPlan) {
        switch plan {
        case .paneAction(let action):
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(action)
        case .moveTab(let tabId, let insertionIndex):
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.reorderTab(tabId: tabId, insertionIndex: insertionIndex))
        case .extractPaneToTabThenMove(let paneId, let sourceTabId, let insertionIndex):
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchGesture { [self] execute in
                let tabCountBefore = store.tabLayoutAtom.tabs.count
                guard await execute(.extractPaneToTab(tabId: sourceTabId, paneId: paneId)) else { return false }
                guard
                    store.tabLayoutAtom.tabs.count == tabCountBefore + 1,
                    let extractedTabId = store.tabLayoutAtom.activeTabId,
                    let insertedTabIndexAfterExtraction = store.tabShellAtom.orderedTabIds.firstIndex(
                        of: extractedTabId
                    )
                else {
                    return false
                }
                let postExtractionInsertionIndex = Self.postExtractionInsertionIndex(
                    preExtractionInsertionIndex: insertionIndex,
                    insertedTabIndexAfterExtraction: insertedTabIndexAfterExtraction
                )
                return await execute(
                    .reorderTab(
                        tabId: extractedTabId,
                        insertionIndex: postExtractionInsertionIndex
                    )
                )
            }
        }
    }

    private static func postExtractionInsertionIndex(
        preExtractionInsertionIndex: Int,
        insertedTabIndexAfterExtraction: Int
    ) -> Int {
        guard insertedTabIndexAfterExtraction < preExtractionInsertionIndex else {
            return preExtractionInsertionIndex
        }
        return preExtractionInsertionIndex + 1
    }

    nonisolated static func splitDropCommitPlan(
        payload: SplitDropPayload,
        destination: SplitDropCommitDestination,
        zone: DropZoneSide,
        sizingMode: DropSizingMode,
        activeTabId: UUID?,
        state: ActionStateSnapshot
    ) -> DropCommitPlan? {
        guard let activeTabId else {
            return nil
        }
        let paneDropDestination = PaneDropDestination.split(
            targetPaneId: destination.paneId,
            targetTabId: activeTabId,
            direction: splitDirection(for: zone),
            sizingMode: sizingMode,
            targetDrawerParentPaneId: destination.drawerParentPaneId
        )
        let decision = PaneDropPlanner.previewDecision(
            payload: payload,
            destination: paneDropDestination,
            state: state
        )
        if case .eligible(let plan) = decision {
            return plan
        }
        return nil
    }

    private func shouldHandleSplitDragPayload(_ payload: SplitDropPayload) -> Bool {
        switch payload.kind {
        case .existingPane(let sourcePaneId, _):
            guard let sourcePane = store.paneAtom.pane(sourcePaneId) else { return false }
            return sourcePane.parentPaneId == nil
        case .newTerminal:
            return true
        case .existingTab:
            return false
        }
    }

    // MARK: - Empty State

    private var emptyStateModel: WorkspaceEmptyStateModel {
        WorkspaceLauncherProjector.project(store: store)
    }

    private func createEmptyStateView() -> NSHostingView<AnyView> {
        PaneTabEmptyStateViewFactory.make(
            model: emptyStateModel,
            octiconLoader: octiconLoader,

            onWatchFolder: { [weak self] in self?.watchFolderAction() },
            onOpenRecent: { [weak self] target in self?.openRecentTarget(target) },
            onOpenAllRecent: { [weak self] in self?.openAllRecentTargets() }
        )
    }

    @objc private func watchFolderAction() {
        AppCommandDispatcher.shared.dispatch(.watchFolder)
    }

    private func updateEmptyState() {
        let hasTabs = !store.tabLayoutAtom.tabs.isEmpty
        tabBarHostingView.isHidden = embedsTabBarInView && !hasTabs
        terminalContainer.isHidden = !hasTabs
        emptyStateView?.isHidden = hasTabs
    }

    private func rebuildEmptyStateView() {
        let currentModel = emptyStateModel
        guard currentModel != lastEmptyStateModel else { return }
        emptyStateView?.rootView = AnyView(
            WorkspaceEmptyStateView(
                model: currentModel,
                octiconLoader: octiconLoader,

                onWatchFolder: { [weak self] in self?.watchFolderAction() },
                onOpenRecent: { [weak self] target in self?.openRecentTarget(target) },
                onOpenAllRecent: { [weak self] in self?.openAllRecentTargets() }
            )
            .tint(AppStyles.General.Accent.primaryColor))
        lastEmptyStateModel = currentModel
    }

    private func openRecentTarget(_ target: ApplicationRecentEntity) {
        guard
            let worktree = WorkspaceLauncherProjector.resolveActivationWorktree(
                target: target,
                repositoryTopology: store.repositoryTopologyAtom
            )
        else {
            Self.logger.debug("Recent launcher target is not currently available")
            let applicationRecency = atom(\.applicationEntityRecency)
            WorkspaceLauncherProjector.pruneStaleTarget(
                target,
                repositoryTopology: store.repositoryTopologyAtom,
                applicationRecency: applicationRecency
            )
            return
        }

        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(
            .openNewTerminalInTab(
                worktreeId: worktree.id,
                launchDirectory: worktree.path,
                title: worktree.name
            )
        )
    }

    private func openAllRecentTargets() {
        for target in emptyStateModel.recentEntities {
            openRecentTarget(target)
        }
    }

    private func openGitHubWebview(for paneId: UUID) {
        let url = GitHubWebviewLaunchResolver.url(
            for: paneId,
            store: store,
            repoCache: repoCache
        )
        guard let targetTabId = store.tabLayoutAtom.activeTabId else {
            executor.openWebview(url: url)
            return
        }
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(
            .insertPane(
                source: .newWebview(WebviewState(url: url)),
                targetTabId: targetTabId,
                targetPaneId: paneId,
                direction: .right,
                sizingMode: .halveTarget
            )
        )
    }

    private func activeMainPaneId() -> UUID? {
        store.tabLayoutAtom.activeTabId
            .flatMap { store.tabLayoutAtom.tab($0) }?
            .activePaneId
    }

    func handleAppOwnedKeyEvent(
        _ event: NSEvent,
        allowsModifiedEmptyDrawerShortcutWithTextFocus: Bool = false
    ) -> Bool {
        guard let trigger = ShortcutDecoder.decode(event: event) else {
            return false
        }

        if shouldConsumeSuppressedTerminalHostTrigger(trigger) { return true }

        let globalShortcut = ShortcutDecoder.shortcut(for: trigger, in: .global)

        let keyboardContext = KeyboardRoutingContext.current(
            windowLifecycle: windowLifecycleStore,
            managementLayer: atom(\.managementLayer),
            uiState: atom(\.workspaceSidebarState),
            commandBarSurface: atom(\.commandBarSurface),
            transientKeyboardSurface: atom(\.transientKeyboardSurface),
            workspaceWindowId: workspaceWindowId
        )

        if let shortcut = globalShortcut,
            AppShortcutDispatchPolicy.isCommandBarActivationShortcut(shortcut)
        {
            guard
                AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                    shortcut,
                    context: keyboardContext
                ),
                AppCommandDispatcher.shared.canDispatch(shortcut.command)
            else {
                return false
            }
            AppCommandDispatcher.shared.dispatchKeyboardShortcut(shortcut)
            return true
        }

        if let handled = handleTerminalRuntimeShortcut(trigger, context: keyboardContext) {
            return handled
        }

        if let shortcut = globalShortcut {
            let shouldDispatchGlobalShortcut = AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                shortcut,
                context: keyboardContext
            )
            guard shouldDispatchGlobalShortcut || shortcut.requiresPaneTargetFallback else {
                return false
            }
            guard
                shouldDispatchGlobalShortcut
                    || AppShortcutDispatchPolicy.shouldRouteAppOwnedKeyEvent(context: keyboardContext)
            else {
                return false
            }
            if AppCommandDispatcher.shared.canDispatch(shortcut.command) {
                AppCommandDispatcher.shared.dispatchKeyboardShortcut(shortcut)
                return true
            }
            if AppShortcutDispatchPolicy.shouldConsumeUnavailableGlobalShortcut(
                shortcut,
                context: keyboardContext
            ) {
                // Global shortcuts only consume unavailable commands when
                // the active surface explicitly reserves that chord.
                return true
            }
            guard shortcut.requiresPaneTargetFallback else {
                return false
            }
            // Empty-drawer creation needs a pane target, so it falls
            // through to the targeted app-owned path below.
        }

        guard AppShortcutDispatchPolicy.shouldRouteAppOwnedKeyEvent(context: keyboardContext) else {
            return false
        }

        // Raw-character triggers always require neutral focus, even
        // when modifier-keyed shortcuts are allowed through text focus.
        if let parentPaneId = firstDrawerPaneParentId(
            for: trigger,
            event: event,
            requiresNeutralFocus: trigger.modifiers.isEmpty || !allowsModifiedEmptyDrawerShortcutWithTextFocus
        ) {
            guard
                AppCommandDispatcher.shared.canDispatch(
                    .addDrawerPane,
                    target: parentPaneId,
                    targetType: .pane
                )
            else {
                return false
            }
            AppCommandDispatcher.shared.dispatch(.addDrawerPane, target: parentPaneId, targetType: .pane)
            return true
        }

        let keyboardOwner = keyboardContext.stableOwner

        if shouldHandleScopeAwarePaneTrigger(event: event, keyboardOwner: keyboardOwner),
            isScopeAwarePaneMovementTrigger(trigger)
        {
            // Consume every reserved option-I/J/K/L chord in pane scope,
            // even when there is no concrete move, so terminal content
            // never receives app-owned navigation keystrokes.
            if let command = scopeAwarePaneCommand(for: trigger), canExecute(command) {
                execute(command)
            }
            return true
        }

        return false
    }

    private func shouldConsumeSuppressedTerminalHostTrigger(_ trigger: ShortcutTrigger) -> Bool {
        AppShortcutDispatchPolicy.shouldSuppressTerminalHostTrigger(trigger)
    }

    private func handleTerminalRuntimeShortcut(
        _ trigger: ShortcutTrigger,
        context keyboardContext: KeyboardRoutingContext
    ) -> Bool? {
        guard let shortcut = ShortcutDecoder.shortcut(for: trigger, in: .terminalAppOwned),
            AppShortcutDispatchPolicy.isTerminalRuntimeCommand(shortcut.command)
        else {
            return nil
        }

        // Terminal runtime shortcuts are app-owned reservations. When AppKit
        // sends them through the pane controller instead of Ghostty, consume
        // even rejected chords so terminal/default responders never see them.
        guard
            AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(
                shortcut,
                context: keyboardContext
            ),
            AppCommandDispatcher.shared.canDispatch(shortcut.command)
        else {
            return true
        }
        AppCommandDispatcher.shared.dispatch(shortcut.command)
        return true
    }

    private func scopeAwarePaneCommand(for trigger: ShortcutTrigger) -> AppCommand? {
        let scope = normalizedWorkspaceNavigationScopeState()
        switch trigger {
        case .init(key: .character(.i), modifiers: [.option]):
            return if case .drawerPane = scope { .focusDrawerPaneUp } else { nil }
        case .init(key: .character(.j), modifiers: [.option]):
            switch scope {
            case .mainPane:
                return .focusPaneLeft
            case .emptyDrawer:
                return nil
            case .drawerPane:
                return .focusDrawerPaneLeft
            }
        case .init(key: .character(.k), modifiers: [.option]):
            switch scope {
            case .mainPane:
                return nil
            case .emptyDrawer:
                return nil
            case .drawerPane:
                return .focusDrawerPaneDown
            }
        case .init(key: .character(.l), modifiers: [.option]):
            switch scope {
            case .mainPane:
                return .focusPaneRight
            case .emptyDrawer:
                return nil
            case .drawerPane:
                return .focusDrawerPaneRight
            }
        default:
            return nil
        }
    }

    private func isScopeAwarePaneMovementTrigger(_ trigger: ShortcutTrigger) -> Bool {
        switch trigger {
        case .init(key: .character(.i), modifiers: [.option]),
            .init(key: .character(.j), modifiers: [.option]),
            .init(key: .character(.k), modifiers: [.option]),
            .init(key: .character(.l), modifiers: [.option]):
            return true
        default:
            return false
        }
    }

    private func shouldHandleScopeAwarePaneTrigger(
        event: NSEvent,
        keyboardOwner: KeyboardOwner
    ) -> Bool {
        guard keyboardOwner == .mainWindowChain else { return false }
        return !rawCharacterHasTextResponder(for: event)
    }

    private func firstDrawerPaneParentId(
        for trigger: ShortcutTrigger,
        event: NSEvent,
        requiresNeutralFocus: Bool = true
    ) -> UUID? {
        // Routing goes through the command-spec system: decode the
        // event once, then ask whether it dispatches `.addDrawerPane`
        // in the `.emptyDrawer` context. The raw-character "P"
        // alternate is empty-drawer only; cmd-shift-D reaches this
        // path when the drawer is open and empty.
        guard
            atom(\.managementLayer).isActive == false,
            ShortcutDecoder.shortcut(for: trigger, in: .emptyDrawer) == .addDrawerPane
        else {
            return nil
        }
        // Raw-character alternates must never be intercepted while
        // text input owns focus. Modified shortcuts may fire from
        // performKeyEquivalent even when a text field is focused.
        if requiresNeutralFocus, rawCharacterHasTextResponder(for: event) {
            return nil
        }

        guard
            case .emptyDrawer(let parentPaneId) = normalizedWorkspaceNavigationScopeState(),
            store.paneAtom.pane(parentPaneId)?.drawer?.paneIds.isEmpty == true
        else {
            Self.logger.warning(
                "empty drawer shortcut ignored because navigation scope and pane drawer state disagree")
            return nil
        }
        return parentPaneId
    }

    private func rawCharacterHasTextResponder(for event: NSEvent) -> Bool {
        let eventWindow = event.window ?? windowForRawCharacterEvent(event)
        let responders = [
            eventWindow?.firstResponder,
            view.window?.firstResponder,
        ]
        return responders.contains { !Self.isNeutralResponderForRawCharacter($0) }
    }

    private func windowForRawCharacterEvent(_ event: NSEvent) -> NSWindow? {
        guard event.windowNumber > 0 else { return nil }

        let application = NSApplication.shared
        return application.window(withWindowNumber: event.windowNumber)
            ?? application.windows.first { $0.windowNumber == event.windowNumber }
    }

    /// A responder is "neutral" for raw character keystrokes when it
    /// will NOT consume the keystroke as text input. NSText (and its
    /// subclasses NSTextView / NSTextField field editor) absorb typed
    /// characters; everything else is considered neutral.
    static func isNeutralResponderForRawCharacter(_ responder: NSResponder?) -> Bool {
        guard let responder else { return true }
        return !(responder is NSText)
    }

    private func managementLayerParentPaneId() -> UUID? {
        switch normalizedWorkspaceNavigationFocusScope() {
        case .mainRow:
            return activeMainPaneId()
        case .drawer(let parentPaneId):
            return parentPaneId
        }
    }

    private func initialWorkspaceNavigationFocusScope() -> WorkspaceNavigationFocusScope {
        if let parentPaneId = activeMainPaneId(),
            store.paneAtom.pane(parentPaneId)?.drawer?.isExpanded == true
        {
            return .drawer(parentPaneId: parentPaneId)
        }

        return .mainRow
    }

    private func managementLayerCreationScope() -> WorkspaceNavigationFocusScope {
        // Intentional: creation follows the normalized navigation scope first,
        // then upgrades main-row scope to an already-expanded drawer so
        // management-layer create commands act in visible drawer context.
        let navigationScope = normalizedWorkspaceNavigationFocusScope()

        if case .drawer = navigationScope {
            return navigationScope
        }

        return initialWorkspaceNavigationFocusScope()
    }

    private func visibleDrawerPaneIds(for parentPaneId: UUID) -> [UUID] {
        arrangementView.drawerVisiblePaneIds(forParent: parentPaneId)
    }

    private func focusSiblingDrawerPane(in parentPaneId: UUID, delta: Int) {
        let visiblePaneIds = visibleDrawerPaneIds(for: parentPaneId)
        guard !visiblePaneIds.isEmpty else { return }

        let currentPaneId = visibleActiveDrawerPaneId(for: parentPaneId) ?? visiblePaneIds.first!
        guard let currentIndex = visiblePaneIds.firstIndex(of: currentPaneId) else { return }

        let nextIndex = (currentIndex + delta + visiblePaneIds.count) % visiblePaneIds.count
        let nextPaneId = visiblePaneIds[nextIndex]
        managementNavigationScope = .drawer(parentPaneId: parentPaneId)
        handlePaneFocusTrigger(.drawer(.selectPane(parentPaneId: parentPaneId, drawerPaneId: nextPaneId)))
    }

    private func handleManagementMoveLeft() {
        switch normalizedWorkspaceNavigationFocusScope() {
        case .mainRow:
            execute(.focusPaneLeft)
        case .drawer(let parentPaneId):
            focusSiblingDrawerPane(in: parentPaneId, delta: -1)
        }
    }

    private func handleManagementMoveRight() {
        switch normalizedWorkspaceNavigationFocusScope() {
        case .mainRow:
            execute(.focusPaneRight)
        case .drawer(let parentPaneId):
            focusSiblingDrawerPane(in: parentPaneId, delta: 1)
        }
    }

    private func handleManagementMoveDown() {
        guard case .drawer(let parentPaneId) = normalizedWorkspaceNavigationFocusScope() else {
            return
        }
        managementNavigationScope = .drawer(parentPaneId: parentPaneId)
        if let drawerPaneId = visibleActiveDrawerPaneId(for: parentPaneId) {
            handlePaneFocusTrigger(.drawer(.selectPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId)))
        }
    }

    private func handleManagementOpenDrawer() {
        guard let parentPaneId = activeMainPaneId() else { return }
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchGesture { [self] execute in
            guard store.paneAtom.pane(parentPaneId) != nil else { return false }
            if store.paneAtom.pane(parentPaneId)?.drawer?.isExpanded != true {
                guard await execute(.toggleDrawer(paneId: parentPaneId)) else { return false }
                handlePaneFocusTrigger(.drawer(.toggle(parentPaneId: parentPaneId)))
            }
            managementNavigationScope = .drawer(parentPaneId: parentPaneId)
            if let drawerPaneId = visibleActiveDrawerPaneId(for: parentPaneId) {
                handlePaneFocusTrigger(.drawer(.selectPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId)))
            }
            return true
        }
    }

    private func handleManagementMoveUp() {
        guard case .drawer(let parentPaneId) = normalizedWorkspaceNavigationFocusScope() else { return }
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchGesture { [self] execute in
            if store.paneAtom.pane(parentPaneId)?.drawer?.isExpanded == true {
                guard await execute(.toggleDrawer(paneId: parentPaneId)) else { return false }
                handlePaneFocusTrigger(.drawer(.toggle(parentPaneId: parentPaneId)))
            }
            managementNavigationScope = .mainRow
            return true
        }
    }

    private func enterDrawerFromActivePane() {
        guard let activeTabId = store.tabLayoutAtom.activeTabId,
            let parentPaneId = store.tabLayoutAtom.tab(activeTabId)?.activePaneId
        else { return }
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchGesture { [self] execute in
            guard store.paneAtom.pane(parentPaneId) != nil else { return false }
            if store.paneAtom.pane(parentPaneId)?.drawer?.isExpanded == false {
                guard await execute(.toggleDrawer(paneId: parentPaneId)) else { return false }
            }
            managementNavigationScope = .drawer(parentPaneId: parentPaneId)
            if let drawerPaneId = arrangementView.drawerView(forParent: parentPaneId)?.activeChildId {
                handlePaneFocusTrigger(.drawer(.selectPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId)))
            } else {
                atom(\.workspaceFocusOwner).focusEmptyDrawer(parentPaneId: parentPaneId)
                _ = clearFirstResponderToWindowContentForDrawer(parentPaneId: parentPaneId)
            }
            return true
        }
    }

    private func moveDrawerFocus(_ command: AppCommand) {
        guard let target = drawerFocusNeighbor(for: command) else { return }
        handlePaneFocusTrigger(
            .drawer(.selectPane(parentPaneId: target.parentPaneId, drawerPaneId: target.drawerPaneId)))
    }

    private func drawerFocusNeighbor(for command: AppCommand) -> (parentPaneId: UUID, drawerPaneId: UUID)? {
        guard case .drawerPane(let parentPaneId, let drawerPaneId) = normalizedWorkspaceNavigationScopeState() else {
            return nil
        }

        let direction: FocusDirection
        switch command {
        case .focusDrawerPaneUp:
            direction = .up
        case .focusDrawerPaneLeft:
            direction = .left
        case .focusDrawerPaneDown:
            direction = .down
        case .focusDrawerPaneRight:
            direction = .right
        default:
            return nil
        }

        guard let drawerView = arrangementView.drawerView(forParent: parentPaneId) else { return nil }
        var candidatePaneId = drawerPaneId
        while let neighborPaneId = drawerView.layout.neighbor(of: candidatePaneId, direction: direction) {
            candidatePaneId = neighborPaneId
            guard !drawerView.minimizedPaneIds.contains(neighborPaneId),
                store.paneAtom.pane(neighborPaneId)?.residency != .backgrounded
            else { continue }
            return (parentPaneId, neighborPaneId)
        }
        return nil
    }

    private func focusDrawerPaneOrdinal(command: AppCommand) -> Bool {
        guard let target = resolveDrawerPaneOrdinalTarget(for: command) else { return false }
        // fire-and-forget: this function reports command admission; the executor serializes the gesture outcome
        _ = dispatchGesture { [self] execute in
            await focusDrawerPaneAfterAdmission(
                parentPaneId: target.parentPaneId, drawerPaneId: target.drawerPaneId, execute: execute)
        }
        return true
    }

    private func resolveDrawerPaneOrdinalTarget(for command: AppCommand) -> (
        parentPaneId: UUID,
        drawerView: DrawerView,
        drawerPaneId: UUID
    )? {
        guard
            let ordinal = drawerPaneOrdinal(for: command),
            let parentPaneId = activeMainPaneId(),
            let drawerView = arrangementView.drawerView(forParent: parentPaneId),
            let drawerPaneId = PaneOrdinalMap(orderedPaneIds: drawerView.layout.paneIds).paneId(forOrdinal: ordinal)
        else {
            return nil
        }
        return (parentPaneId, drawerView, drawerPaneId)
    }

    private func drawerPaneOrdinal(for command: AppCommand) -> Int? {
        AppCommand.focusDrawerPaneCommands.firstIndex(of: command).map { $0 + 1 }
    }

    private func handleManagementCreateTerminal() {
        switch managementLayerCreationScope() {
        case .mainRow:
            managementNavigationScope = .mainRow
            execute(.newTerminalInTab)
        case .drawer(let parentPaneId):
            managementNavigationScope = .drawer(parentPaneId: parentPaneId)
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.addDrawerPane(parentPaneId: parentPaneId))
        }
    }

    private func handleManagementCreateBrowser() {
        switch managementLayerCreationScope() {
        case .mainRow:
            managementNavigationScope = .mainRow
            guard let paneId = activeMainPaneId() else {
                Self.logger.warning("management create browser ignored because active main pane is unavailable")
                return
            }
            openGitHubWebview(for: paneId)
        case .drawer(let parentPaneId):
            managementNavigationScope = .drawer(parentPaneId: parentPaneId)
            let url = GitHubWebviewLaunchResolver.url(
                for: parentPaneId,
                store: store,
                repoCache: repoCache
            )
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(
                .addWebviewDrawerPane(
                    parentPaneId: parentPaneId,
                    state: WebviewState(url: url)
                )
            )
        }
    }

    func canExecuteManagementCommand(_ command: AppCommand) -> Bool {
        let navigationScope = normalizedWorkspaceNavigationFocusScope()

        switch command {
        case .managementLayerFocusLeft:
            switch navigationScope {
            case .mainRow:
                return canExecute(.focusPaneLeft)
            case .drawer(let parentPaneId):
                return visibleDrawerPaneIds(for: parentPaneId).count > 1
            }
        case .managementLayerFocusRight:
            switch navigationScope {
            case .mainRow:
                return canExecute(.focusPaneRight)
            case .drawer(let parentPaneId):
                return visibleDrawerPaneIds(for: parentPaneId).count > 1
            }
        case .managementLayerEnterDrawer, .managementLayerOpenDrawer:
            return activeMainPaneId() != nil
        case .managementLayerExitDrawer, .managementLayerExit:
            if case .drawer = navigationScope {
                return true
            }
            return command == .managementLayerExit
        case .managementLayerCreateTerminal:
            switch managementLayerCreationScope() {
            case .mainRow:
                return canExecute(.newTerminalInTab)
            case .drawer(let parentPaneId):
                return canDispatchAction(.addDrawerPane(parentPaneId: parentPaneId))
            }
        case .managementLayerCreateBrowser:
            guard
                let activeTabId = store.tabLayoutAtom.activeTabId,
                let activePaneId = activeMainPaneId()
            else {
                return false
            }
            switch managementLayerCreationScope() {
            case .mainRow:
                return canDispatchAction(
                    .insertPane(
                        source: .newWebview(WebviewState(url: URL(string: "https://github.com")!)),
                        targetTabId: activeTabId,
                        targetPaneId: activePaneId,
                        direction: .right,
                        sizingMode: .halveTarget
                    )
                )
            case .drawer(let parentPaneId):
                return canDispatchAction(
                    .addWebviewDrawerPane(
                        parentPaneId: parentPaneId,
                        state: WebviewState(url: URL(string: "https://github.com")!)
                    )
                )
            }
        default:
            return false
        }
    }

    private func canExecuteContextualCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .addDrawerPane:
            guard let parentPaneId = activeMainPaneId() else { return false }
            return canDispatchAction(.addDrawerPane(parentPaneId: parentPaneId))
        case .toggleDrawer:
            return activeMainPaneId() != nil
        case .closeDrawerPane:
            guard let parentPaneId = activeMainPaneId() else { return false }
            return visibleActiveDrawerPaneId(for: parentPaneId) != nil
        case .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge:
            guard let side = command.zoomDrawerTargetSide,
                let action = zoomDrawerSideAction(side: side, ownerPaneId: activeZoomSourcePaneId())
            else { return false }
            return canDispatchAction(action)
        default:
            return false
        }
    }

    // MARK: - New Tab

    /// Create a new empty tab rooted at the first watched folder, or the user's
    /// home directory when no watched folder exists yet.
    private func addNewTab() {
        let launchDirectory =
            store.repositoryTopologyAtom.watchedPaths.first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(.openFloatingTerminal(launchDirectory: launchDirectory, title: nil))
    }

    // MARK: - Terminal Management

    func openTerminal(for worktree: Worktree, in _: Repo) {
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(.openWorktree(worktreeId: worktree.id))
    }

    func openNewTerminal(for worktree: Worktree, in _: Repo) {
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(.openNewTerminalInTab(worktreeId: worktree.id, launchDirectory: nil, title: nil))
    }

    func openWorktreeInPane(for worktree: Worktree, in _: Repo) {
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(.openWorktreeInPane(worktreeId: worktree.id))
    }

    func executeQuickOpenDirectory(
        _ directory: URL,
        placement: QuickOpenDirectoryPlacement
    ) {
        switch placement {
        case .newTab:
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.openFloatingTerminal(launchDirectory: directory, title: nil))
        case .currentTabPane:
            guard let activeTabId = store.tabLayoutAtom.activeTabId,
                let activePaneId = store.tabLayoutAtom.tab(activeTabId)?.activePaneId
            else {
                return
            }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(
                .insertPane(
                    source: .newTerminalAtDirectory(directory),
                    targetTabId: activeTabId,
                    targetPaneId: activePaneId,
                    direction: .right,
                    sizingMode: .halveTarget
                )
            )
        }
    }

    func closeTerminal(for worktreeId: UUID) {
        // Find the tab containing this worktree
        guard
            let tab = store.tabLayoutAtom.tabs.first(where: { tab in
                tab.allPaneIds.contains { id in
                    store.paneAtom.pane(id)?.worktreeId == worktreeId
                }
            })
        else { return }

        guard
            let matchedPaneId = tab.allPaneIds.first(where: { id in
                store.paneAtom.pane(id)?.worktreeId == worktreeId
            })
        else { return }
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(.closePane(tabId: tab.id, paneId: matchedPaneId))
    }

    func closeActiveTab() {
        guard let activeId = store.tabLayoutAtom.activeTabId else { return }
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(.closeTab(tabId: activeId))
    }

    func selectTab(at index: Int) {
        let tabs = store.tabLayoutAtom.tabs
        guard index >= 0, index < tabs.count else { return }
        handlePaneFocusTrigger(.command(.selectTab(tabs[index].id)))
    }

    // MARK: - Validated Action Pipeline

    /// Central entry point: validates a WorkspaceActionCommand and executes it if valid.
    /// All input sources (keyboard, menu, drag-drop, commands) converge here.
    private func dispatchPaneAction(_ action: WorkspaceActionCommand) -> Task<Bool, Never> {
        dispatchGesture { execute in await execute(action) }
    }

    func dispatchGesture(
        _ operation: @escaping @MainActor (@MainActor (WorkspaceActionCommand) async -> Bool) async -> Bool
    ) -> Task<Bool, Never> {
        executor.submitGesture { [weak self] execute in
            guard let self else { return false }
            return await operation { action in
                let applied = await execute(action)
                if applied { self.syncFocusOwnerAfterValidatedAction(action) }
                return applied
            }
        }
    }

    private func actionStateSnapshot() -> ActionStateSnapshot {
        WorkspaceCommandResolver.snapshot(
            from: store.tabLayoutAtom.tabs,
            activeTabId: store.tabLayoutAtom.activeTabId,
            isManagementLayerActive: atom(\.managementLayer).isActive,
            zoomSourcePaneIdByTabId: store.panePresentationAtom.zoomPresentationsByTabId.mapValues(
                \.sourcePaneId
            ),
            knownRepoIds: Set(store.repositoryTopologyAtom.repos.map(\.id)),
            knownWorktreeIds: store.repositoryTopologyAtom.availableWorktreeIDs,
            drawerParentByPaneId: drawerParentByPaneId(),
            drawerLayoutByParentPaneId: drawerLayoutByParentPaneId(),
            visiblePaneIds: { [arrangementView] tab in
                arrangementView.activeVisiblePaneIds(forTab: tab.id)
            }
        )
    }

    private func canDispatchAction(_ action: WorkspaceActionCommand) -> Bool {
        if case .success = WorkspaceCommandValidator.validate(
            action,
            state: actionStateSnapshot()
        ) {
            return true
        }
        return false
    }

    private func syncFocusOwnerAfterValidatedAction(_ action: WorkspaceActionCommand) {
        switch action {
        case .addDrawerPane(let parentPaneId),
            .removeDrawerPane(let parentPaneId, _),
            .toggleDrawer(let parentPaneId),
            .setActiveDrawerPane(let parentPaneId, _),
            .insertDrawerPane(let parentPaneId, _, _, _),
            .moveDrawerPane(let parentPaneId, _, _, _),
            .minimizeDrawerPane(let parentPaneId, _),
            .expandDrawerPane(let parentPaneId, _):
            syncFocusOwnerAfterDrawerMutation(parentPaneId: parentPaneId)
        case .detachDrawerPane:
            managementNavigationScope = .mainRow
            atom(\.workspaceFocusOwner).focusMainPane(activeMainPaneId())
        default:
            break
        }
    }

    func handleArrangementPanelZoomToggle(
        tabId: UUID,
        sourcePaneId: UUID?
    ) {
        guard store.tabLayoutAtom.activeTabId == tabId else { return }

        if let sourcePaneId {
            _ = submitZoomCommand(explicitPaneId: sourcePaneId)
            return
        }

        guard store.panePresentationAtom.zoomPresentation(forTab: tabId) != nil else {
            return
        }
        execute(.zoomPane)
    }

    func showTabContextMenuArrangements(tabId: UUID) {
        guard store.tabLayoutAtom.tab(tabId) != nil else { return }
        if store.tabLayoutAtom.activeTabId != tabId {
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.selectTab(tabId: tabId))
        }
        guard
            let workspaceWindowId =
                workspaceWindowId
                ?? windowLifecycleStore.focusedWindowId
                ?? windowLifecycleStore.keyWindowId
        else { return }
        arrangementPanelPresentation.present(
            tabId: tabId,
            workspaceWindowId: workspaceWindowId
        )
    }

    private func requestTabRenamePresentation(for tabId: UUID) {
        guard store.tabLayoutAtom.tab(tabId) != nil else {
            Self.logger.warning("renameTab presentation ignored: tab \(tabId) not found")
            return
        }
        if store.tabLayoutAtom.activeTabId != tabId {
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.selectTab(tabId: tabId))
        }

        tabRenamePopoverState.dismiss()

        // Context menus and command-bar dispatch both run while another transient
        // AppKit surface is unwinding. Move the editor presentation to default
        // run-loop mode and let the controller own the AppKit popover anchor.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                self?.presentTabRenamePopover(for: tabId)
            }
        }
    }

    private func presentTabRenamePopover(for tabId: UUID) {
        guard let tab = store.tabLayoutAtom.tab(tabId) else {
            Self.logger.warning("renameTab presentation ignored after defer: tab \(tabId) not found")
            return
        }

        closeTabRenamePopover(updateState: false)
        tabRenamePopoverState.present(for: tabId)

        guard isViewLoaded, let tabBarHostingView, tabBarHostingView.window != nil else {
            return
        }

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: TabRenamePopover(
                currentTitle: tabBarAdapter.tabs.first(where: { $0.id == tabId })?.displayTitle ?? tab.name,
                onCommit: { [weak self] name in
                    guard let self else { return }
                    // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
                    _ = self.dispatchPaneAction(.renameTab(tabId: tabId, name: name))
                    self.closeTabRenamePopover()
                },
                onCancel: { [weak self] in
                    self?.closeTabRenamePopover()
                }
            )
            .tint(AppStyles.General.Accent.primaryColor)
        )
        tabRenamePopover = popover
        if let workspaceWindowId = workspaceWindowId ?? windowLifecycleStore.focusedWindowId
            ?? windowLifecycleStore.keyWindowId
        {
            tabRenameTransientSurfaceToken = atom(\.transientKeyboardSurface).present(
                .tabRename(tabId: tabId),
                workspaceWindowId: workspaceWindowId
            )
        }

        let anchorRect = tabBarHostingView.tabFrameInView(for: tabId) ?? tabBarHostingView.bounds
        popover.show(relativeTo: anchorRect, of: tabBarHostingView, preferredEdge: .minY)
    }

    private func closeTabRenamePopover(updateState: Bool = true) {
        dismissTabRenameTransientSurface()
        let popover = tabRenamePopover
        tabRenamePopover = nil
        popover?.delegate = nil
        popover?.close()
        if updateState {
            tabRenamePopoverState.dismiss()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === paneNotePopover {
            paneNotePopover = nil
            return
        }

        guard notification.object as? NSPopover === tabRenamePopover else { return }
        dismissTabRenameTransientSurface()
        tabRenamePopover = nil
        tabRenamePopoverState.dismiss()
    }

    private func dismissTabRenameTransientSurface() {
        guard let tabRenameTransientSurfaceToken else { return }
        atom(\.transientKeyboardSurface).dismiss(tabRenameTransientSurfaceToken)
        self.tabRenameTransientSurfaceToken = nil
    }

    // MARK: - Tab Reordering

    private func handleTabReorder(fromId: UUID, insertionIndex: Int, correlationId: UUID) {
        interactionProbe?.beginInteraction(.tabMove, correlationId: correlationId)
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchGesture { [self] execute in
            guard await execute(.reorderTab(tabId: fromId, insertionIndex: insertionIndex)) else { return false }
            pendingTabMovePublication = PendingTabMovePublication(
                correlationId: correlationId, movedTabId: fromId,
                expectedOrderedTabIds: store.tabShellAtom.orderedTabIds
            )
            return true
        }
    }

    func acknowledgeTabBarPublication(frames: [UUID: CGRect]) {
        guard let pendingTabMovePublication,
            tabBarAdapter.tabs.map(\.id) == pendingTabMovePublication.expectedOrderedTabIds,
            frames[pendingTabMovePublication.movedTabId] != nil
        else { return }
        self.pendingTabMovePublication = nil
        interactionProbe?.settleInteraction(
            correlationId: pendingTabMovePublication.correlationId
        )
    }

    // MARK: - Drag Payload

    private func createDragPayload(for tabId: UUID) -> TabDragPayload? {
        guard store.tabLayoutAtom.tab(tabId) != nil else { return nil }
        return TabDragPayload(tabId: tabId)
    }

    // MARK: - Process Termination

    @discardableResult
    func handleTerminalProcessTerminated(paneId: UUID) -> Bool {
        if closeTransitionCoordinator.closingPaneIds.contains(paneId) {
            return true
        }
        if let pane = store.paneAtom.pane(paneId) {
            if let parentPaneId = pane.parentPaneId,
                let parentTab = store.tabLayoutAtom.tabContaining(paneId: parentPaneId)
            {
                // fire-and-forget: termination is acknowledged at admission; the close runs on the gesture tail
                _ = dispatchPaneAction(.closePane(tabId: parentTab.id, paneId: paneId))
                return true
            }

            if let tab = store.tabLayoutAtom.tabContaining(paneId: paneId) {
                // fire-and-forget: termination is acknowledged at admission; the close runs on the gesture tail
                _ = dispatchPaneAction(.closePane(tabId: tab.id, paneId: paneId))
                return true
            }

            RestoreTrace.log(
                "PaneTabViewController.handleTerminalProcessTerminated deferredNoop pane=\(paneId) reason=orphanedPane"
            )
            return false
        }

        RestoreTrace.log(
            "PaneTabViewController.handleTerminalProcessTerminated deferredNoop pane=\(paneId) reason=notInAnyTab"
        )
        return false
    }

    private func handleExtractPaneRequested(tabId: UUID, paneId: UUID, targetTabInsertionIndex: Int?) {
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchGesture { [self] execute in
            guard let sourceTab = store.tabLayoutAtom.tab(tabId) else { return false }
            if sourceTab.activePaneIds.count == 1 {
                guard let targetTabInsertionIndex else { return true }
                return await execute(.reorderTab(tabId: tabId, insertionIndex: targetTabInsertionIndex))
            }
            let tabCountBefore = store.tabLayoutAtom.tabs.count
            guard await execute(.extractPaneToTab(tabId: tabId, paneId: paneId)) else { return false }
            guard let targetTabInsertionIndex else { return true }
            guard store.tabLayoutAtom.tabs.count == tabCountBefore + 1,
                let extractedTabId = store.tabLayoutAtom.activeTabId,
                let insertedIndex = store.tabShellAtom.orderedTabIds.firstIndex(of: extractedTabId)
            else { return false }
            let destination = Self.postExtractionInsertionIndex(
                preExtractionInsertionIndex: targetTabInsertionIndex,
                insertedTabIndexAfterExtraction: insertedIndex
            )
            return await execute(.reorderTab(tabId: extractedTabId, insertionIndex: destination))
        }
    }

    private func dispatchMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID) {
        guard
            let action = makeMovePaneToTabAction(
                sourcePaneId: sourcePaneId,
                sourceTabId: sourceTabId,
                targetTabId: targetTabId
            )
        else { return }
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchPaneAction(action)
    }

    func makeMovePaneToTabAction(
        sourcePaneId: UUID,
        sourceTabId: UUID?,
        targetTabId: UUID
    ) -> WorkspaceActionCommand? {
        let resolvedSourceTabId: UUID? =
            if let sourceTabId, store.tabLayoutAtom.tab(sourceTabId)?.activePaneIds.contains(sourcePaneId) == true {
                sourceTabId
            } else {
                store.tabLayoutAtom.tabs.first(where: { $0.activePaneIds.contains(sourcePaneId) })?.id
            }

        guard let resolvedSourceTabId else { return nil }
        guard resolvedSourceTabId != targetTabId else { return nil }
        guard let targetTab = store.tabLayoutAtom.tab(targetTabId) else { return nil }
        guard let targetPaneId = targetTab.activePaneId ?? targetTab.activePaneIds.first else { return nil }

        return .movePaneAcrossTabs(
            CrossTabPaneMoveRequest(
                paneId: sourcePaneId,
                sourceTabId: resolvedSourceTabId,
                destTabId: targetTabId,
                targetPaneId: targetPaneId,
                direction: .horizontal,
                position: .after
            )
        )
    }

    // MARK: - Undo Close Tab

    private func handleUndoCloseTab() {
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = executor.submitUndoClose()
    }

    // MARK: - Refocus Active Pane

    func refocusActivePane() {
        requestPaneRefocus(.explicit)
    }

    // MARK: - WorkspaceCommandHandling Conformance

    func bridgePaneCommandTarget(worktreeId: UUID) -> BridgePaneCommandTarget? {
        executor.resolveBridgePaneCommand(worktreeId: worktreeId)
    }

    func execute(_ command: AppCommand) {
        if command == .zoomPane {
            _ = submitZoomCommand(explicitPaneId: nil)
            return
        }

        if let side = command.zoomDrawerTargetSide {
            if let action = zoomDrawerSideAction(side: side, ownerPaneId: activeZoomSourcePaneId()) {
                // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
                _ = dispatchPaneAction(action)
            }
            return
        }

        if handlePaneFocusCommand(command) {
            return
        }

        if handleTerminalRuntimeCommand(command) {
            return
        }

        // Try the validated pipeline for pane/tab structural actions
        if let action = WorkspaceCommandResolver.resolve(
            command: command,
            tabs: store.tabLayoutAtom.tabs,
            activeTabId: store.tabLayoutAtom.activeTabId,
            visiblePaneIds: { [arrangementView] tab in
                arrangementView.activeVisiblePaneIds(forTab: tab.id)
            }
        ) {
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(action)
            return
        }

        if handleManagementCommand(command) {
            return
        }

        if handleArrangementCommand(command) {
            return
        }

        handleDirectCommand(command)
    }

    private func handleArrangementCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .switchArrangement:
            requestArrangementPanel()
            return true
        case .previousArrangement:
            switchActiveArrangement(delta: -1)
            return true
        case .nextArrangement, .cycleArrangement:
            switchActiveArrangement(delta: 1)
            return true
        default:
            return false
        }
    }

    private func handleTerminalRuntimeCommand(_ command: AppCommand) -> Bool {
        guard let paneId = focusedTerminalCommandTargetPaneId() else { return false }
        return dispatchTerminalRuntimeCommand(command, paneId: paneId)
    }

    private func dispatchTerminalRuntimeCommand(_ command: AppCommand, paneId: UUID) -> Bool {
        let runtimeCommand: PaneRuntimeCommand
        switch command {
        case .scrollToBottom:
            runtimeCommand = .terminal(.scrollToBottom)
        case .scrollPageUp:
            runtimeCommand = .terminal(
                .scrollPageFractional(fraction: -AppPolicies.TerminalNavigation.pageFraction)
            )
        case .scrollPageDown:
            runtimeCommand = .terminal(
                .scrollPageFractional(fraction: AppPolicies.TerminalNavigation.pageFraction)
            )
        case .scrollSmallStepUp:
            runtimeCommand = .terminal(
                .scrollPageFractional(fraction: -AppPolicies.TerminalNavigation.smallStepFraction)
            )
        case .scrollSmallStepDown:
            runtimeCommand = .terminal(
                .scrollPageFractional(fraction: AppPolicies.TerminalNavigation.smallStepFraction)
            )
        case .jumpToPreviousPrompt:
            runtimeCommand = .terminal(.jumpToPrompt(delta: -1))
        case .jumpToNextPrompt:
            runtimeCommand = .terminal(.jumpToPrompt(delta: 1))
        default:
            return false
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.runtimeCommandDispatcher.dispatchRuntimeCommand(
                runtimeCommand,
                target: .pane(PaneId(existingUUID: paneId)),
                correlationId: nil
            )
        }
        return true
    }

    private func handleTargetedTerminalRuntimeCommand(
        _ command: AppCommand,
        target targetId: UUID,
        targetType: SearchItemType
    ) -> Bool {
        guard isPaneTargetType(targetType), canExecuteTargetedTerminalRuntimeCommand(command, target: targetId) else {
            return false
        }
        return dispatchTerminalRuntimeCommand(command, paneId: targetId)
    }

    private func canExecuteTargetedTerminalRuntimeCommand(
        _ command: AppCommand,
        target targetId: UUID
    ) -> Bool {
        guard AppShortcutDispatchPolicy.isTerminalRuntimeCommand(command),
            let pane = store.paneAtom.pane(targetId)
        else {
            return false
        }
        guard case .terminal = pane.content else { return false }
        return true
    }

    private func isPaneTargetType(_ targetType: SearchItemType) -> Bool {
        targetType == .pane || targetType == .floatingTerminal
    }

    private func focusedTerminalCommandTargetPaneId() -> UUID? {
        let candidatePaneId: UUID?
        switch normalizedWorkspaceNavigationScopeState() {
        case .mainPane(let mainPaneId):
            candidatePaneId = mainPaneId ?? activeMainPaneId()
        case .emptyDrawer(let parentPaneId):
            candidatePaneId = parentPaneId
        case .drawerPane(_, let drawerPaneId):
            candidatePaneId = drawerPaneId
        }

        guard
            let candidatePaneId,
            let pane = store.paneAtom.pane(candidatePaneId),
            case .terminal = pane.content
        else {
            return nil
        }
        return candidatePaneId
    }

    func handleManagementCommand(_ command: AppCommand) -> Bool {
        guard isManagementCommand(command) else { return false }

        let clock = ContinuousClock()
        let commandStart = clock.now
        defer {
            performanceTraceRecorder?.recordDuration(
                .managementLayerCommand,
                duration: commandStart.duration(to: clock.now),
                attributes: [
                    "agentstudio.performance.management_layer.command": .string(command.rawValue),
                    "agentstudio.performance.management_layer.is_active": .bool(atom(\.managementLayer).isActive),
                    "agentstudio.performance.management_layer.pane.count": .int(store.paneAtom.graphAtom.paneIDs.count),
                    "agentstudio.performance.management_layer.tab.count": .int(store.tabShellAtom.orderedTabIds.count),
                ]
            )
        }

        switch command {
        case .toggleManagementLayer:
            let wasManagementLayerActive = atom(\.managementLayer).isActive
            atom(\.managementLayer).toggle()
            if !wasManagementLayerActive {
                managementNavigationScope = initialWorkspaceNavigationFocusScope()
            }
            return true

        case .managementLayerFocusLeft:
            handleManagementMoveLeft()
            return true

        case .managementLayerFocusRight:
            handleManagementMoveRight()
            return true

        case .managementLayerEnterDrawer:
            handleManagementMoveDown()
            return true

        case .managementLayerExitDrawer:
            handleManagementMoveUp()
            return true

        case .managementLayerOpenDrawer:
            handleManagementOpenDrawer()
            return true

        case .managementLayerCreateTerminal:
            handleManagementCreateTerminal()
            return true

        case .managementLayerCreateBrowser:
            handleManagementCreateBrowser()
            return true

        case .managementLayerExit:
            atom(\.managementLayer).deactivate()
            return true

        default:
            return false
        }
    }

    private func isManagementCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .toggleManagementLayer,
            .managementLayerFocusLeft,
            .managementLayerFocusRight,
            .managementLayerEnterDrawer,
            .managementLayerExitDrawer,
            .managementLayerOpenDrawer,
            .managementLayerCreateTerminal,
            .managementLayerCreateBrowser,
            .managementLayerExit:
            return true
        default:
            return false
        }
    }

    private func handleWebSurfaceCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .openWebview:
            guard canExecute(.openWebview) else {
                return false
            }
            executor.openWebview()
            return true
        case .reloadBridgeWebView:
            guard let bridgeMountView = resolvedBridgeCommandMountView() else {
                return false
            }
            return bridgeMountView.controller.reloadWebView()
        case .showViewer:
            guard canExecute(.showViewer) else { return false }
            // fire-and-forget: this function reports command admission; the executor serializes the gesture outcome
            _ = dispatchGesture { [self] execute in
                switch executeZoomLocalViewerCommand(explicitPaneId: nil) {
                case .notZoomLocal:
                    return await enterZoomAndShowViewerAfterAdmission(
                        explicitPaneId: nil,
                        execute: execute
                    )
                case .toggled(let didToggle):
                    return didToggle
                }
            }
            return true
        case .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab:
            return submitBridgeSurfaceCommand(command, worktreeId: nil)
        default:
            return false
        }
    }

    private func resolvedBridgeCommandMountView() -> BridgePaneMountView? {
        let paneId: UUID?
        switch normalizedWorkspaceNavigationScopeState() {
        case .mainPane(let mainPaneId):
            paneId = mainPaneId ?? activeMainPaneId()
        case .emptyDrawer(let parentPaneId):
            paneId = parentPaneId
        case .drawerPane(_, let drawerPaneId):
            paneId = drawerPaneId
        }

        guard let paneId else {
            return nil
        }
        return resolvedBridgeCommandMountView(paneId: paneId)
    }

    func resolvedBridgeCommandMountView(paneId: UUID) -> BridgePaneMountView? {
        guard
            let pane = store.paneAtom.pane(paneId),
            case .bridgePanel = pane.content
        else {
            return nil
        }
        guard let bridgeMountView = viewRegistry.allBridgeViews[paneId],
            bridgeMountView.controller.canReloadWebView
        else {
            return nil
        }
        return bridgeMountView
    }

    func enterZoomAndShowViewerAfterAdmission(
        explicitPaneId: UUID?,
        execute: @MainActor (WorkspaceActionCommand) async -> Bool
    ) async -> Bool {
        let canEnterZoomWithViewer =
            if let explicitPaneId {
                canExecutePaneSurfaceViewerCommand(sourcePaneId: explicitPaneId)
            } else {
                canExecute(.showViewer)
            }
        guard canEnterZoomWithViewer,
            await executeZoomCommandAfterAdmission(explicitPaneId: explicitPaneId, execute: execute),
            let activeTabId = store.tabLayoutAtom.activeTabId,
            let presentation = store.panePresentationAtom.zoomPresentation(forTab: activeTabId)
        else {
            return false
        }

        switch presentation.viewerPresentation {
        case .retainedVisible, .unavailableVisible:
            return true
        case .retainedHidden, .unavailable:
            let didShowViewer = withAnimation(
                .easeInOut(duration: AppStyles.General.Animation.standard)
            ) {
                store.panePresentationAtom.setZoomViewerVisible(
                    true,
                    forSourcePane: presentation.sourcePaneId
                )
            }
            if didShowViewer {
                executor.refreshZoomCompanionActivities()
                executor.reevaluatePreparedTerminalGeometry()
                // Revealing the viewer reshapes the zoom layout after focus was
                // committed; re-assert it like the Zoom cancel path does.
                requestPaneRefocus(.explicit)
            }
            return didShowViewer
        case .retryable:
            return false
        }
    }

    enum ZoomLocalViewerCommandResult {
        case notZoomLocal
        case toggled(Bool)
    }

    func executeZoomLocalViewerCommand(
        explicitPaneId: UUID?
    ) -> ZoomLocalViewerCommandResult {
        guard
            let activeTabId = store.tabLayoutAtom.activeTabId,
            let presentation = store.panePresentationAtom.zoomPresentation(forTab: activeTabId)
        else {
            return .notZoomLocal
        }
        if let explicitPaneId, explicitPaneId != presentation.sourcePaneId {
            return .notZoomLocal
        }

        switch presentation.viewerPresentation {
        case .retainedHidden, .unavailable:
            let didToggle = withAnimation(
                .easeInOut(duration: AppStyles.General.Animation.standard)
            ) {
                store.panePresentationAtom.setZoomViewerVisible(
                    true,
                    forSourcePane: presentation.sourcePaneId
                )
            }
            if didToggle {
                executor.refreshZoomCompanionActivities()
                executor.reevaluatePreparedTerminalGeometry()
            }
            return .toggled(didToggle)
        case .retainedVisible, .unavailableVisible:
            let didToggle = withAnimation(
                .easeInOut(duration: AppStyles.General.Animation.standard)
            ) {
                store.panePresentationAtom.setZoomViewerVisible(
                    false,
                    forSourcePane: presentation.sourcePaneId
                )
            }
            if didToggle {
                executor.refreshZoomCompanionActivities()
                executor.reevaluatePreparedTerminalGeometry()
            }
            return .toggled(didToggle)
        case .retryable:
            let reconciledPresentation = executor.reconcileZoomCompanion(
                sourcePaneId: presentation.sourcePaneId,
                owningTabId: activeTabId,
                viewerSurfaceRequest: bridgeViewerSurfaceRequestHandler
            )
            executor.reevaluatePreparedTerminalGeometry()
            return .toggled(reconciledPresentation.companionPaneId != nil)
        }
    }

    private func zoomCommandCapability(explicitPaneId: UUID?) -> ZoomCommandCapability? {
        let activeTabId = store.tabLayoutAtom.activeTabId
        let activePaneId = activeTabId.flatMap { store.tabLayoutAtom.activePaneID(forTab: $0) }
        let candidatePaneId = explicitPaneId ?? activePaneId
        let candidate = candidatePaneId.flatMap { paneId -> ZoomCommandCandidate? in
            guard
                let paneState = store.paneAtom.graphAtom.paneState(paneId),
                !paneState.isDrawerChild,
                let tabId = store.tabLayoutAtom.tabID(containingPane: paneId)
            else {
                return nil
            }
            return ZoomCommandCandidate(
                paneId: paneId,
                tabId: tabId,
                isEligible: ZoomCommandCapabilityPolicy.isPaneContentEligible(
                    paneState.paneContent
                )
            )
        }
        let capabilityTabId = candidate?.tabId ?? activeTabId
        let zoomSourcePaneId = capabilityTabId.flatMap {
            store.panePresentationAtom.zoomPresentation(forTab: $0)?.sourcePaneId
        }
        return ZoomCommandCapabilityPolicy.resolve(
            activeTabId: activeTabId,
            activePaneId: activePaneId,
            explicitPaneId: explicitPaneId,
            candidate: candidate,
            zoomSourcePaneId: zoomSourcePaneId
        )
    }

    private func submitZoomCommand(explicitPaneId: UUID?) -> Bool {
        guard zoomCommandCapability(explicitPaneId: explicitPaneId) != nil else { return false }
        // fire-and-forget: this function reports command admission; the executor serializes the gesture outcome
        _ = dispatchGesture { [self] execute in
            await executeZoomCommandAfterAdmission(explicitPaneId: explicitPaneId, execute: execute)
        }
        return true
    }

    func executeZoomCommandAfterAdmission(
        explicitPaneId: UUID?,
        execute: @MainActor (WorkspaceActionCommand) async -> Bool
    ) async -> Bool {
        guard let capability = zoomCommandCapability(explicitPaneId: explicitPaneId) else {
            return false
        }
        let capturedZoomPresentation = store.panePresentationAtom.zoomPresentation(forTab: capability.tabId)

        if capability.requiresTabActivation {
            guard
                await prepareAndApplyTargetFocus(
                    paneId: capability.sourcePaneId,
                    execute: execute
                )
            else { return false }
        }

        guard let currentCapability = zoomCommandCapability(explicitPaneId: explicitPaneId),
            currentCapability.sourcePaneId == capability.sourcePaneId,
            currentCapability.tabId == capability.tabId,
            store.panePresentationAtom.zoomPresentation(forTab: capability.tabId) == capturedZoomPresentation
        else { return false }

        return applyZoomCommand(capability)
    }

    private func applyZoomCommand(_ capability: ZoomCommandCapability) -> Bool {
        switch capability.effect {
        case .enter:
            executor.reattachZoomSourceForPresentationIfHidden(
                sourcePaneId: capability.sourcePaneId,
                tabId: capability.tabId
            )
            store.panePresentationAtom.enterZoom(
                inTab: capability.tabId,
                sourcePaneId: capability.sourcePaneId,
                viewerPresentation: initialZoomViewerPresentation(
                    sourcePaneId: capability.sourcePaneId,
                    tabId: capability.tabId
                )
            )
        case .cancel:
            store.panePresentationAtom.cancelZoom(inTab: capability.tabId)
            executor.detachZoomSourceAfterExitIfHidden(
                sourcePaneId: capability.sourcePaneId,
                tabId: capability.tabId
            )
            executor.refreshZoomCompanionActivities()
            executor.reevaluatePreparedTerminalGeometry()
            requestPaneRefocus(.explicit)
            return true
        case .retarget:
            let didRetarget = store.panePresentationAtom.retargetZoom(
                inTab: capability.tabId,
                to: capability.sourcePaneId,
                viewerPresentation: initialZoomViewerPresentation(
                    sourcePaneId: capability.sourcePaneId,
                    tabId: capability.tabId
                )
            )
            guard didRetarget else {
                return false
            }
            executor.reattachZoomSourceForPresentationIfHidden(
                sourcePaneId: capability.sourcePaneId,
                tabId: capability.tabId
            )
        case .resume:
            executor.reattachZoomSourceForPresentationIfHidden(
                sourcePaneId: capability.sourcePaneId,
                tabId: capability.tabId
            )
        }
        _ = executor.reconcileZoomCompanion(
            sourcePaneId: capability.sourcePaneId,
            owningTabId: capability.tabId,
            viewerSurfaceRequest: bridgeViewerSurfaceRequestHandler
        )
        executor.reevaluatePreparedTerminalGeometry()
        requestPaneRefocus(.explicit)
        return true
    }

    private func initialZoomViewerPresentation(
        sourcePaneId: UUID,
        tabId: UUID
    ) -> ZoomViewerPresentation {
        guard let resolvedWorktreeId = resolvedViewerWorktreeId(forPane: sourcePaneId) else {
            return .unavailable
        }
        guard
            let companion = store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePaneId),
            companion.owningTabId == tabId,
            companion.resolvedWorktreeId == resolvedWorktreeId
        else {
            return .retryable
        }
        return .retainedVisible(companionPaneId: companion.companionPaneId)
    }

    private func resolvedViewerWorktreeId(forPane paneId: UUID) -> UUID? {
        guard let paneState = store.paneAtom.graphAtom.paneState(paneId) else {
            return nil
        }
        let facets = paneState.durableContextFacets
        return store.repositoryTopologyAtom.validatedAssociation(
            repoId: facets.repoId,
            worktreeId: facets.worktreeId
        )?.worktree.id
    }

    private func submitBridgeSurfaceCommand(_ command: AppCommand, worktreeId: UUID?) -> Bool {
        guard
            command == .showBridgeReview || command == .showBridgeFiles
                || command == .openBridgeReviewInNewTab || command == .openBridgeFilesInNewTab
        else { return false }
        // fire-and-forget: this function reports command admission; the executor serializes the gesture outcome
        _ = dispatchGesture { [self] execute in
            await executeBridgeSurfaceCommandAfterAdmission(
                command,
                worktreeId: worktreeId,
                execute: execute
            )
        }
        return true
    }

    func executeBridgeSurfaceCommandAfterAdmission(
        _ command: AppCommand,
        worktreeId: UUID?,
        execute: @MainActor (WorkspaceActionCommand) async -> Bool
    ) async -> Bool {
        let surface: BridgeProductSurface
        let alwaysCreate: Bool
        switch command {
        case .showBridgeReview:
            surface = .review
            alwaysCreate = false
        case .showBridgeFiles:
            surface = .file
            alwaysCreate = false
        case .openBridgeReviewInNewTab:
            surface = .review
            alwaysCreate = true
        case .openBridgeFilesInNewTab:
            surface = .file
            alwaysCreate = true
        default:
            return false
        }
        let viewerOpenTelemetryAnchor = bridgeViewerOpenTelemetryAnchorFactory()

        if !alwaysCreate,
            let target = executor.resolveBridgePaneCommand(worktreeId: worktreeId),
            case .reuse(let paneId) = target.resolution
        {
            guard store.tabLayoutAtom.tabContaining(paneId: paneId) != nil else {
                return false
            }
            let previousOrdinal = bridgePaneAttendance.ordinal(for: paneId)
            guard
                await prepareAndApplyTargetFocus(
                    paneId: paneId,
                    execute: execute,
                    beforeFocus: { [weak self] in
                        self?.pendingBridgeAttendanceEventForNextFocus = .defaultJump
                    }
                )
            else {
                pendingBridgeAttendanceEventForNextFocus = nil
                return false
            }
            guard bridgePaneAttendance.ordinal(for: paneId) != previousOrdinal else {
                return false
            }
            return bridgeViewerSurfaceRequestHandler(surface, paneId)
        }

        let pane =
            switch surface {
            case .review:
                executor.openBridgeReviewInNewTab(
                    worktreeId: worktreeId,
                    viewerOpenTelemetryAnchor: viewerOpenTelemetryAnchor
                )
            case .file:
                executor.openBridgeFilesInNewTab(
                    worktreeId: worktreeId,
                    viewerOpenTelemetryAnchor: viewerOpenTelemetryAnchor
                )
            }
        guard let pane else { return false }
        bridgePaneAttendance.record(.newTabCreation, for: pane.id)
        _ = bridgeViewerSurfaceRequestHandler(surface, pane.id)
        return true
    }

    private func dispatchDrawerToggle(paneId: UUID) {
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchGesture { [self] execute in
            guard await execute(.toggleDrawer(paneId: paneId)) else { return false }
            handlePaneFocusTrigger(.drawer(.toggle(parentPaneId: paneId)))
            return true
        }
    }

    private func handleDirectCommand(_ command: AppCommand) {
        if handlePaneLocationCommand(command) {
            return
        }
        if handlePaneInboxCommand(command) {
            return
        }
        if handleWebSurfaceCommand(command) {
            return
        }

        switch command {
        case .newTab:
            addNewTab()

        case .undoCloseTab:
            handleUndoCloseTab()
        case .renameTab:
            guard let activeTabId = store.tabLayoutAtom.activeTabId else { break }
            requestTabRenamePresentation(for: activeTabId)
        case .watchFolder, .toggleSidebar, .filterSidebar,
            .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications, .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .signInGitHub, .signInGoogle:
            break
        case .enterDrawer:
            enterDrawerFromActivePane()
        case .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown, .focusDrawerPaneRight:
            moveDrawerFocus(command)
        case .addDrawerPane:
            guard let tabId = store.tabLayoutAtom.activeTabId,
                let tab = store.tabLayoutAtom.tab(tabId),
                let paneId = tab.activePaneId
            else { break }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.addDrawerPane(parentPaneId: paneId))

        case .toggleDrawer:
            guard let tabId = store.tabLayoutAtom.activeTabId,
                let tab = store.tabLayoutAtom.tab(tabId),
                let paneId = tab.activePaneId
            else { break }
            dispatchDrawerToggle(paneId: paneId)

        case .closeDrawerPane:
            guard let tabId = store.tabLayoutAtom.activeTabId,
                let tab = store.tabLayoutAtom.tab(tabId),
                let paneId = tab.activePaneId,
                store.paneAtom.pane(paneId)?.drawer != nil,
                let activeDrawerPaneId = arrangementView.drawerView(forParent: paneId)?.activeChildId
            else { break }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.closePane(tabId: tabId, paneId: activeDrawerPaneId))

        case .saveArrangement:
            guard let tabId = store.tabLayoutAtom.activeTabId,
                let tab = store.tabLayoutAtom.tab(tabId)
            else { break }
            let name = ArrangementDerived.nextCustomArrangementName(existing: tab.arrangements)
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.createArrangement(tabId: tabId, name: name))

        case .newTerminalInTab:
            guard let activeTabId = store.tabLayoutAtom.activeTabId,
                let tab = store.tabLayoutAtom.tab(activeTabId),
                let targetPaneId = tab.activePaneId
            else { break }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(
                .insertPane(
                    source: .newTerminal,
                    targetTabId: activeTabId,
                    targetPaneId: targetPaneId,
                    direction: .right,
                    sizingMode: .halveTarget
                ))
        case .newFloatingTerminal:
            let activePaneCwd = store.tabLayoutAtom.activeTabId
                .flatMap { store.tabLayoutAtom.tab($0)?.activePaneId }
                .flatMap { store.paneAtom.pane($0)?.metadata.facets.cwd }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.openFloatingTerminal(launchDirectory: activePaneCwd, title: nil))
        case .detachDrawerPane:
            guard case .drawerPane(let parentPaneId, let drawerPaneId) = normalizedWorkspaceNavigationScopeState()
            else {
                break
            }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchPaneAction(.detachDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId))
        case .showCommandBarEverything, .showCommandBarQuickOpen, .showCommandBarCommands,
            .showCommandBarPanes, .showCommandBarRepos,
            .openNewTerminalInTab, .openWorktree, .openWorktreeInPane,
            .switchArrangement, .deleteArrangement, .renameArrangement,
            .navigateDrawerPane, .movePaneToTab,
            .selectTab, .focusPane, .zoomPane:
            return  // Handled via drill-in (target selection in command bar)
        default:
            Self.logger.warning(
                "PaneTabViewController.handleDirectCommand ignored unhandled command=\(String(describing: command), privacy: .public)"
            )
        }
    }

    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) {
        if command == .selectTab, targetType == .tab {
            handlePaneFocusTrigger(.command(.selectTab(target)))
            return
        }

        if command == .previousArrangement || command == .nextArrangement {
            guard targetType == .tab else { return }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchGesture { [self] execute in
                guard let tab = store.tabLayoutAtom.tab(target), tab.arrangements.count > 1,
                    let activeIndex = tab.arrangements.firstIndex(where: { $0.id == tab.activeArrangementId })
                else { return false }
                if store.tabLayoutAtom.activeTabId != target {
                    guard await execute(.selectTab(tabId: target)) else { return false }
                }
                let delta = command == .previousArrangement ? -1 : 1
                let nextIndex = (activeIndex + delta + tab.arrangements.count) % tab.arrangements.count
                return await execute(.switchArrangement(tabId: target, arrangementId: tab.arrangements[nextIndex].id))
            }
            return
        }

        if command == .zoomPane, targetType == .pane {
            _ = submitZoomCommand(explicitPaneId: target)
            return
        }

        if command == .showViewer, targetType == .pane {
            switch executeZoomLocalViewerCommand(explicitPaneId: target) {
            case .notZoomLocal:
                return
            case .toggled:
                return
            }
        }

        if command == .reloadBridgeWebView, targetType == .pane {
            _ = resolvedBridgeCommandMountView(paneId: target)?.controller.reloadWebView()
            return
        }

        if command == .editPaneNote, targetType == .pane {
            guard store.paneAtom.pane(target) != nil else { return }
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchGesture { [self] execute in
                guard await prepareAndApplyTargetFocus(paneId: target, execute: execute) else {
                    return false
                }
                paneNotePresentation.present(target)
                return true
            }
            return
        }

        if isPaneInboxCommand(command), isPaneInboxTargetType(targetType) {
            handleTargetedPaneInboxCommand(command, target: target, targetType: targetType)
            return
        }

        if command == .focusPane && (targetType == .pane || targetType == .floatingTerminal) {
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = submitTargetedPaneFocus(target)
            return
        }

        if handleTargetedTerminalRuntimeCommand(command, target: target, targetType: targetType) {
            return
        }

        if executeTargetedReviewCommand(command: command, target: target, targetType: targetType) {
            return
        }

        if isTargetedPaneExternalCommand(command) {
            guard targetType == .pane else { return }
            _ = handleTargetedPaneExternalCommand(command, paneId: target)
            return
        }

        if command == .toggleDrawer, targetType == .pane {
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchGesture { [self] execute in
                guard
                    let action = targetedPaneWorkspaceAction(command: command, paneId: target, targetType: targetType),
                    await execute(action)
                else { return false }
                handlePaneFocusTrigger(.drawer(.toggle(parentPaneId: target)))
                return true
            }
            return
        }

        if targetedAction(command: command, target: target, targetType: targetType) != nil {
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchGesture { [self] execute in
                guard let action = targetedAction(command: command, target: target, targetType: targetType),
                    await prepareTargetedArrangementTabSelection(
                        command: command, target: target, targetType: targetType, execute: execute
                    )
                else { return false }
                return await execute(action)
            }
            return
        }

        if executeTargetedRenameCommand(command, target: target, targetType: targetType) {
            return
        }

        Self.logger.warning(
            "Targeted command ignored for unsupported target pair command=\(String(describing: command), privacy: .public) targetType=\(targetType.rawValue, privacy: .public)"
        )
        return
    }

    private func executeTargetedRenameCommand(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) -> Bool {
        switch (command, targetType) {
        case (.renameTab, .tab):
            guard store.tabLayoutAtom.tab(target) != nil else {
                Self.logger.warning("renameTab targeted command ignored: tab \(target) not found")
                return true
            }
            requestTabRenamePresentation(for: target)
            return true
        case (.renameArrangement, .tab):
            guard
                let arrangementTarget = arrangementTarget(target)
            else {
                Self.logger.warning("renameArrangement targeted command ignored: arrangement \(target) not found")
                return true
            }
            let tab = arrangementTarget.tab
            let arrangement = arrangementTarget.arrangement
            guard !arrangement.isDefault else {
                Self.logger.warning("renameArrangement targeted command ignored: cannot rename default arrangement")
                return true
            }
            if store.tabLayoutAtom.activeTabId != tab.id {
                // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
                _ = dispatchPaneAction(.selectTab(tabId: tab.id))
            }
            arrangementInlineRenameState.beginEditing(
                arrangementId: arrangement.id,
                currentName: arrangement.name,
                isDefault: arrangement.isDefault
            )
            return true
        default:
            return false
        }
    }

    func submitTargetedPaneFocus(_ paneId: UUID) -> Task<Bool, Never> {
        dispatchGesture { [self] execute in
            await prepareAndApplyTargetFocus(paneId: paneId, execute: execute)
        }
    }

    private func prepareAndApplyTargetFocus(
        paneId: UUID,
        execute: @MainActor (WorkspaceActionCommand) async -> Bool,
        beforeFocus: @MainActor () -> Void = {}
    ) async -> Bool {
        await PaneCommittedFocusOperation(
            store: store,
            applyFocus: { [weak self] trigger in
                self?.applyPaneFocusTrigger(trigger) ?? false
            }
        ).prepareAndApplyTargetFocus(
            paneID: paneId,
            execute: execute,
            beforeFocus: beforeFocus
        )
    }

    private func revealArrangementContainingPane(tabId: UUID, paneId: UUID) {
        guard let tab = store.tabLayoutAtom.tab(tabId),
            !tab.activeArrangement.layout.contains(paneId),
            let containingArrangement = tab.arrangements.first(where: { $0.layout.contains(paneId) })
        else {
            return
        }

        store.tabLayoutAtom.switchArrangement(to: containingArrangement.id, inTab: tabId)
    }

    func focusTargetedDrawerPane(parentPaneId: UUID, drawerPaneId: UUID) {
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchGesture { [self] execute in
            await focusDrawerPaneAfterAdmission(
                parentPaneId: parentPaneId, drawerPaneId: drawerPaneId, execute: execute)
        }
    }

    func canFocusTargetedPane(_ paneId: UUID) -> Bool {
        let paneGraph = store.paneAtom.graphAtom
        guard let paneState = paneGraph.paneState(paneId) else { return false }
        if let parentPaneId = paneState.parentPaneId {
            guard let drawerId = paneGraph.paneState(parentPaneId)?.ownedDrawerId else { return false }
            return store.tabLayoutAtom.tabID(containingPane: parentPaneId) != nil
                && paneGraph.parentPaneID(containingDrawer: drawerId) == parentPaneId
        }
        return store.tabLayoutAtom.tabID(containingPane: paneId) != nil
    }

    private func focusDrawerPaneAfterAdmission(
        parentPaneId: UUID, drawerPaneId: UUID,
        execute: @MainActor (WorkspaceActionCommand) async -> Bool
    ) async -> Bool {
        guard let tab = store.tabLayoutAtom.tabContaining(paneId: parentPaneId),
            store.paneAtom.pane(parentPaneId)?.drawer?.paneIds.contains(drawerPaneId) == true
        else { return false }
        if store.paneAtom.pane(parentPaneId)?.drawer?.isExpanded == false {
            guard await execute(.toggleDrawer(paneId: parentPaneId)) else { return false }
        }
        if arrangementView.drawerView(forParent: parentPaneId)?.minimizedPaneIds.contains(drawerPaneId) == true {
            guard await execute(.expandDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId)) else {
                return false
            }
        }
        handlePaneFocusTrigger(.command(.focusPane(tabId: tab.id, paneId: parentPaneId)))
        handlePaneFocusTrigger(.drawer(.selectPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId)))
        return true
    }

    private func focusMainPaneOrdinal(command: AppCommand) -> Bool {
        guard resolveMainPaneOrdinalTarget(for: command) != nil else { return false }
        // fire-and-forget: this function reports command admission; the executor serializes the gesture outcome
        _ = dispatchGesture { [self] execute in
            guard let target = resolveMainPaneOrdinalTarget(for: command) else { return false }
            if let zoomPresentation = store.panePresentationAtom.zoomPresentation(forTab: target.tab.id),
                zoomPresentation.sourcePaneId != target.paneId,
                !(await executeZoomCommandAfterAdmission(
                    explicitPaneId: target.paneId,
                    execute: execute
                ))
            {
                return false
            }
            return applyPaneFocusTrigger(
                .command(.focusPane(tabId: target.tab.id, paneId: target.paneId))
            )
        }
        return true
    }

    private func resolveMainPaneOrdinalTarget(for command: AppCommand) -> (tab: AgentStudioCore.Tab, paneId: UUID)? {
        guard
            let ordinal = mainPaneOrdinal(for: command),
            let activeTabId = store.tabLayoutAtom.activeTabId,
            let tab = store.tabLayoutAtom.tab(activeTabId),
            let paneId = PaneOrdinalMap(
                orderedPaneIds: tab.activePaneIds.filter {
                    !tab.activeMinimizedPaneIds.contains($0)
                }
            ).paneId(forOrdinal: ordinal)
        else {
            return nil
        }
        return (tab, paneId)
    }

    private func mainPaneOrdinal(for command: AppCommand) -> Int? {
        AppCommand.focusPaneCommands.firstIndex(of: command).map { $0 + 1 }
    }

    private func requestArrangementPanel() {
        guard let activeTabId = store.tabLayoutAtom.activeTabId else { return }
        guard let activePaneId = store.tabLayoutAtom.tab(activeTabId)?.activePaneId else { return }
        requestArrangementPanel(
            tabId: activeTabId,
            contextPaneId: activePaneId
        )
    }

    private func requestArrangementPanel(
        tabId: UUID,
        contextPaneId: UUID
    ) {
        guard
            let tab = store.tabLayoutAtom.tab(tabId),
            tab.activePaneIds.contains(contextPaneId)
        else { return }
        guard
            let workspaceWindowId =
                workspaceWindowId
                ?? windowLifecycleStore.focusedWindowId
                ?? windowLifecycleStore.keyWindowId
        else { return }
        arrangementPanelPresentation.present(
            tabId: tabId,
            workspaceWindowId: workspaceWindowId
        )
    }

    func presentArrangementPanel(
        contextPaneId: UUID?
    ) -> Result<ArrangementPanelProgrammaticPresentation, ArrangementPanelProgrammaticPresentationFailure> {
        guard
            let resolvedWorkspaceWindowId =
                workspaceWindowId
                ?? windowLifecycleStore.focusedWindowId
                ?? windowLifecycleStore.keyWindowId
        else {
            return .failure(.noActiveWindow)
        }

        let tab: AgentStudioCore.Tab
        if let contextPaneId {
            guard
                store.paneAtom.pane(contextPaneId) != nil,
                let containingTab = store.tabLayoutAtom.tabs.first(where: {
                    $0.allPaneIds.contains(contextPaneId)
                })
            else {
                return .failure(.targetNotFound)
            }
            tab = containingTab
        } else {
            guard
                let activeTabId = store.tabLayoutAtom.activeTabId,
                let activeTab = store.tabLayoutAtom.tab(activeTabId)
            else {
                return .failure(.validationRejected)
            }
            tab = activeTab
        }

        if store.tabLayoutAtom.activeTabId != tab.id {
            handlePaneFocusTrigger(.command(.selectTab(tab.id)))
            guard store.tabLayoutAtom.activeTabId == tab.id else {
                return .failure(.validationRejected)
            }
        }
        arrangementPanelPresentation.present(
            tabId: tab.id,
            workspaceWindowId: resolvedWorkspaceWindowId
        )
        return .success(
            ArrangementPanelProgrammaticPresentation(
                workspaceWindowId: resolvedWorkspaceWindowId,
                tabId: tab.id,
                contextPaneId: contextPaneId
            )
        )
    }

    private func switchActiveArrangement(delta: Int) {
        guard let activeTabId = store.tabLayoutAtom.activeTabId else {
            return
        }
        switchArrangement(inTab: activeTabId, delta: delta)
    }

    private func switchArrangement(inTab tabId: UUID, delta: Int) {
        // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
        _ = dispatchGesture { [self] execute in
            guard
                let tab = store.tabLayoutAtom.tab(tabId),
                tab.arrangements.count > 1,
                let activeIndex = tab.arrangements.firstIndex(where: { $0.id == tab.activeArrangementId })
            else {
                return false
            }

            let count = tab.arrangements.count
            let nextIndex = (activeIndex + delta + count) % count
            let arrangement = tab.arrangements[nextIndex]
            return await execute(.switchArrangement(tabId: tab.id, arrangementId: arrangement.id))
        }
    }

    private func handlePaneFocusCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            return focusMainPaneOrdinal(command: command)
        case .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4,
            .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8,
            .focusDrawerPane9:
            return focusDrawerPaneOrdinal(command: command)
        case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown, .focusNextPane, .focusPrevPane:
            guard let trigger = makePaneKeyboardFocusTrigger(for: command) else { return false }
            handlePaneFocusTrigger(.keyboard(trigger))
            return true
        case .focusPreviousPinnedPane, .focusNextPinnedPane:
            return focusPinnedPane(command: command)
        case .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9:
            guard let tabId = resolvePaneFocusTabSelectionTarget(for: command) else { return false }
            handlePaneFocusTrigger(.command(.selectTab(tabId)))
            return true
        default:
            return false
        }
    }

    private func focusPinnedPane(command: AppCommand) -> Bool {
        guard pinnedPanePreferences != nil, let originPaneID = preferredVisibleFocusPaneId() else {
            return false
        }
        // fire-and-forget: the executor owns the ordered focus outcome after shortcut admission.
        _ = dispatchGesture { [self] execute in
            let request = RepoExplorerPinnedPaneProjectionRequest(coreAtoms: CoreAtomScope.store)
            guard
                let targetPaneID = try? await RepoExplorerPinnedPaneProjector.targetPaneID(
                    from: request,
                    originPaneID: originPaneID,
                    previous: command == .focusPreviousPinnedPane,
                    performanceTraceRecorder: performanceTraceRecorder
                )
            else { return false }
            return await prepareAndApplyTargetFocus(paneId: targetPaneID, execute: execute)
        }
        return true
    }

    private func makePaneKeyboardFocusTrigger(for command: AppCommand) -> PaneKeyboardFocusTrigger? {
        guard
            let activeTabId = store.tabLayoutAtom.activeTabId,
            let tab = store.tabLayoutAtom.tab(activeTabId),
            let activePaneId = tab.activePaneId
        else {
            Self.logger.warning(
                "Pane keyboard focus trigger dropped reason=activeSelectionUnavailable command=\(String(describing: command), privacy: .public)"
            )
            return nil
        }

        let targetPaneId: UUID?
        switch command {
        case .focusPaneLeft:
            targetPaneId = nextVisibleSpatialPane(
                from: activePaneId, direction: .left, in: tab
            )
        case .focusPaneRight:
            targetPaneId = nextVisibleSpatialPane(
                from: activePaneId, direction: .right, in: tab
            )
        case .focusPaneUp:
            targetPaneId = nextVisibleSpatialPane(
                from: activePaneId, direction: .up, in: tab
            )
        case .focusPaneDown:
            targetPaneId = nextVisibleSpatialPane(
                from: activePaneId, direction: .down, in: tab
            )
        case .focusNextPane:
            targetPaneId = tab.nextPaneId(after: activePaneId)
        case .focusPrevPane:
            targetPaneId = tab.previousPaneId(before: activePaneId)
        default:
            targetPaneId = nil
        }

        guard let targetPaneId else {
            Self.logger.warning(
                "Pane keyboard focus trigger dropped reason=neighborUnavailable command=\(String(describing: command), privacy: .public) activePane=\(activePaneId.uuidString, privacy: .public)"
            )
            return nil
        }
        return .moveToPane(
            tabId: activeTabId,
            paneId: targetPaneId,
            paneKind: PaneFocusContext.PaneKind(content: store.paneAtom.pane(targetPaneId)?.content)
        )
    }

    private func nextVisibleSpatialPane(
        from sourcePaneId: UUID,
        direction: SplitFocusDirection,
        in tab: AgentStudioCore.Tab
    ) -> UUID? {
        var candidatePaneId = sourcePaneId
        while let neighborPaneId = tab.neighborPaneId(
            of: candidatePaneId,
            direction: direction
        ) {
            candidatePaneId = neighborPaneId
            guard !tab.activeMinimizedPaneIds.contains(neighborPaneId),
                store.paneAtom.pane(neighborPaneId)?.residency != .backgrounded
            else { continue }
            return neighborPaneId
        }
        return nil
    }

    private func resolvePaneFocusTabSelectionTarget(for command: AppCommand) -> UUID? {
        let tabs = store.tabLayoutAtom.tabs
        guard !tabs.isEmpty else {
            Self.logger.warning(
                "Pane tab selection trigger dropped reason=noTabs command=\(String(describing: command), privacy: .public)"
            )
            return nil
        }

        switch command {
        case .nextTab:
            guard
                let activeTabId = store.tabLayoutAtom.activeTabId,
                let currentIndex = tabs.firstIndex(where: { $0.id == activeTabId }),
                !tabs.isEmpty
            else {
                Self.logger.warning(
                    "Pane tab selection trigger dropped reason=activeTabUnavailable command=\(String(describing: command), privacy: .public)"
                )
                return nil
            }
            return tabs[(currentIndex + 1) % tabs.count].id
        case .prevTab:
            guard
                let activeTabId = store.tabLayoutAtom.activeTabId,
                let currentIndex = tabs.firstIndex(where: { $0.id == activeTabId }),
                !tabs.isEmpty
            else {
                Self.logger.warning(
                    "Pane tab selection trigger dropped reason=activeTabUnavailable command=\(String(describing: command), privacy: .public)"
                )
                return nil
            }
            return tabs[(currentIndex - 1 + tabs.count) % tabs.count].id
        case .selectTab1:
            return tabs.isEmpty ? nil : tabs[0].id
        case .selectTab2:
            return tabs.count > 1 ? tabs[1].id : nil
        case .selectTab3:
            return tabs.count > 2 ? tabs[2].id : nil
        case .selectTab4:
            return tabs.count > 3 ? tabs[3].id : nil
        case .selectTab5:
            return tabs.count > 4 ? tabs[4].id : nil
        case .selectTab6:
            return tabs.count > 5 ? tabs[5].id : nil
        case .selectTab7:
            return tabs.count > 6 ? tabs[6].id : nil
        case .selectTab8:
            return tabs.count > 7 ? tabs[7].id : nil
        case .selectTab9:
            return tabs.count > 8 ? tabs[8].id : nil
        default:
            return nil
        }
    }

    private struct TargetedPaneCommandTarget {
        let paneId: UUID
        let owningTabId: UUID
        let drawerParentPaneId: UUID?
    }

    private func targetedPaneCommandTarget(
        paneId: UUID,
        targetType: SearchItemType
    ) -> TargetedPaneCommandTarget? {
        guard targetType == .pane, let pane = store.paneAtom.pane(paneId) else {
            return nil
        }

        if let parentPaneId = pane.parentPaneId {
            guard
                let parentPane = store.paneAtom.pane(parentPaneId),
                parentPane.drawer?.paneIds.contains(paneId) == true,
                let owningTab = store.tabLayoutAtom.tabContaining(paneId: parentPaneId)
            else {
                return nil
            }
            return TargetedPaneCommandTarget(
                paneId: paneId,
                owningTabId: owningTab.id,
                drawerParentPaneId: parentPaneId
            )
        }

        guard let owningTab = store.tabLayoutAtom.tabContaining(paneId: paneId) else {
            return nil
        }
        return TargetedPaneCommandTarget(
            paneId: paneId,
            owningTabId: owningTab.id,
            drawerParentPaneId: nil
        )
    }

    func targetedPaneWorkspaceAction(
        command: AppCommand,
        paneId: UUID,
        targetType: SearchItemType
    ) -> WorkspaceActionCommand? {
        guard
            let target = targetedPaneCommandTarget(
                paneId: paneId,
                targetType: targetType
            ),
            let owningTab = store.tabLayoutAtom.tab(target.owningTabId)
        else {
            return nil
        }

        switch command {
        case .minimizePane:
            if let parentPaneId = target.drawerParentPaneId {
                guard
                    let drawerView = arrangementView.drawerView(forParent: parentPaneId),
                    drawerView.layout.contains(target.paneId),
                    !drawerView.minimizedPaneIds.contains(target.paneId)
                else {
                    return nil
                }
                return .minimizeDrawerPane(
                    parentPaneId: parentPaneId,
                    drawerPaneId: target.paneId
                )
            }
            guard owningTab.activePaneIds.contains(target.paneId) else {
                return nil
            }
            return .minimizePane(
                tabId: target.owningTabId,
                paneId: target.paneId
            )
        case .expandPane:
            if let parentPaneId = target.drawerParentPaneId {
                guard
                    let drawerView = arrangementView.drawerView(forParent: parentPaneId),
                    drawerView.minimizedPaneIds.contains(target.paneId)
                else {
                    return nil
                }
                return .expandDrawerPane(
                    parentPaneId: parentPaneId,
                    drawerPaneId: target.paneId
                )
            }
            guard owningTab.activeMinimizedPaneIds.contains(target.paneId) else {
                return nil
            }
            return .expandPane(
                tabId: target.owningTabId,
                paneId: target.paneId
            )
        case .closePane:
            return .closePane(
                tabId: target.owningTabId,
                paneId: target.paneId
            )
        case .toggleDrawer:
            guard
                target.drawerParentPaneId == nil,
                owningTab.activePaneIds.contains(target.paneId),
                store.paneAtom.pane(target.paneId)?.drawer != nil
            else {
                return nil
            }
            return .toggleDrawer(paneId: target.paneId)
        case .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge:
            guard let side = command.zoomDrawerTargetSide else { return nil }
            return zoomDrawerSideAction(side: side, ownerPaneId: target.drawerParentPaneId ?? target.paneId)
        default:
            return nil
        }
    }

    func paneTerminalCreationAction(command: AppCommand, paneId: UUID) -> WorkspaceActionCommand? {
        guard let pane = store.paneAtom.pane(paneId),
            let directory = targetedPaneLocationPath(paneId: paneId)
        else { return nil }
        if command == .openNewTerminalInTab {
            if let association = store.repositoryTopologyAtom.validatedAssociation(
                repoId: pane.repoId, worktreeId: pane.worktreeId
            ) {
                return .openNewTerminalInTab(
                    worktreeId: association.worktree.id, launchDirectory: directory, title: nil)
            }
            return .openFloatingTerminal(launchDirectory: directory, title: nil)
        }
        guard let target = targetedPaneCapabilityTarget(paneId: paneId) else { return nil }
        let insertionPaneId: UUID
        switch target {
        case .layout: insertionPaneId = paneId
        case .drawerChild(_, let parentPaneId, _, _): insertionPaneId = parentPaneId
        }
        return .insertPane(
            source: .newTerminalAtDirectory(directory), targetTabId: target.tabId,
            targetPaneId: insertionPaneId, direction: .right, sizingMode: .halveTarget
        )
    }

    private func targetedAction(
        command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) -> WorkspaceActionCommand? {
        if targetType == .pane,
            command == .openNewTerminalInTab || command == .openWorktreeInPane
        {
            return paneTerminalCreationAction(command: command, paneId: target)
        }
        if let paneAction = targetedPaneWorkspaceAction(
            command: command,
            paneId: target,
            targetType: targetType
        ) {
            return paneAction
        }
        if let repositoryAction = targetedSidebarAction(command: command, target: target, targetType: targetType) {
            return repositoryAction
        }
        if let tabAction = targetedTabAction(command: command, target: target, targetType: targetType) {
            return tabAction
        }

        switch (command, targetType) {
        case (.splitRight, .pane):
            guard let tab = store.tabLayoutAtom.tabs.first(where: { $0.activePaneIds.contains(target) }) else {
                return nil
            }
            return .insertPane(
                source: .newTerminal,
                targetTabId: tab.id,
                targetPaneId: target,
                direction: .right,
                sizingMode: .halveTarget
            )
        case (.closePane, .pane), (.closePane, .floatingTerminal):
            guard let tab = store.tabLayoutAtom.tabs.first(where: { $0.activePaneIds.contains(target) }) else {
                return nil
            }
            return .closePane(tabId: tab.id, paneId: target)
        case (.extractPaneToTab, .pane), (.extractPaneToTab, .floatingTerminal):
            guard let tab = store.tabLayoutAtom.tabs.first(where: { $0.activePaneIds.contains(target) }) else {
                return nil
            }
            return .extractPaneToTab(tabId: tab.id, paneId: target)
        case (.movePaneToTab, .tab):
            guard
                let activeTabId = store.tabLayoutAtom.activeTabId,
                let activePaneId = store.tabLayoutAtom.tab(activeTabId)?.activePaneId
            else { return nil }
            return makeMovePaneToTabAction(
                sourcePaneId: activePaneId,
                sourceTabId: activeTabId,
                targetTabId: target
            )
        case (.switchArrangement, .tab):
            guard let arrangementTarget = arrangementTarget(target) else { return nil }
            return .switchArrangement(tabId: arrangementTarget.tab.id, arrangementId: target)
        case (.deleteArrangement, .tab):
            guard let arrangementTarget = arrangementTarget(target) else { return nil }
            return .removeArrangement(tabId: arrangementTarget.tab.id, arrangementId: target)
        case (.navigateDrawerPane, .pane):
            guard let tabId = store.tabLayoutAtom.activeTabId,
                let tab = store.tabLayoutAtom.tab(tabId),
                let paneId = tab.activePaneId
            else { return nil }
            return .setActiveDrawerPane(parentPaneId: paneId, drawerPaneId: target)
        case (.detachDrawerPane, .pane):
            guard let parentPaneId = store.paneAtom.pane(target)?.parentPaneId else { return nil }
            return .detachDrawerPane(parentPaneId: parentPaneId, drawerPaneId: target)
        case (.addDrawerPane, .pane), (.addDrawerPane, .floatingTerminal):
            return .addDrawerPane(parentPaneId: target)
        case (.renameArrangement, .tab):
            return nil
        default:
            return nil
        }
    }

    private func prepareTargetedArrangementTabSelection(
        command: AppCommand,
        target: UUID,
        targetType: SearchItemType,
        execute: @MainActor (WorkspaceActionCommand) async -> Bool
    ) async -> Bool {
        guard
            targetType == .tab,
            command == .switchArrangement || command == .deleteArrangement
        else {
            return true
        }
        guard let owningTabId = arrangementTarget(target)?.tab.id else {
            return false
        }
        if store.tabLayoutAtom.activeTabId != owningTabId {
            guard await execute(.selectTab(tabId: owningTabId)) else { return false }
        }
        return store.tabLayoutAtom.activeTabId == owningTabId
    }

    private func arrangementTarget(
        _ arrangementId: UUID
    ) -> (tab: AgentStudioCore.Tab, arrangement: PaneArrangement)? {
        for tab in store.tabLayoutAtom.tabs {
            if let arrangement = tab.arrangements.first(where: { $0.id == arrangementId }) {
                return (tab: tab, arrangement: arrangement)
            }
        }
        return nil
    }

    func targetedTabAction(
        command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) -> WorkspaceActionCommand? {
        guard targetType == .tab, let tab = store.tabLayoutAtom.tab(target) else { return nil }

        switch command {
        case .selectTab:
            return .selectTab(tabId: tab.id)
        case .closeTab:
            return .closeTab(tabId: tab.id)
        case .breakUpTab:
            return .breakUpTab(tabId: tab.id)
        case .splitRight, .splitLeft, .newTerminalInTab:
            guard let targetPaneId = tab.activePaneId else { return nil }
            return .insertPane(
                source: .newTerminal,
                targetTabId: tab.id,
                targetPaneId: targetPaneId,
                direction: command == .splitLeft ? .left : .right,
                sizingMode: .halveTarget
            )
        case .equalizePanes:
            return .equalizePanes(tabId: tab.id)
        case .saveArrangement:
            let name = ArrangementDerived.nextCustomArrangementName(existing: tab.arrangements)
            return .createArrangement(tabId: tab.id, name: name)
        case .newFloatingTerminal:
            let launchDirectory = tab.activePaneId
                .flatMap { store.paneAtom.pane($0)?.metadata.facets.cwd }
            return .openFloatingTerminal(launchDirectory: launchDirectory, title: nil)
        default:
            return nil
        }
    }

    func ownsWorkspaceWindow(_ workspaceWindowId: UUID) -> Bool {
        acceptsIPCCommands && self.workspaceWindowId == workspaceWindowId
    }

    func targetedSidebarAction(
        command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) -> WorkspaceActionCommand? {
        switch (command, targetType) {
        case (.removeRepo, .repo):
            return .removeRepo(repoId: target)
        case (.pinRepo, .repo):
            return .setRepoPinned(repoId: target, isPinned: true)
        case (.unpinRepo, .repo):
            return .setRepoPinned(repoId: target, isPinned: false)
        case (.pinPane, .pane):
            return .setPanePinned(paneId: target, isPinned: true)
        case (.unpinPane, .pane):
            return .setPanePinned(paneId: target, isPinned: false)
        case (.openWorktree, .worktree):
            return .openWorktree(worktreeId: target)
        case (.openNewTerminalInTab, .worktree):
            return .openNewTerminalInTab(worktreeId: target, launchDirectory: nil, title: nil)
        case (.openWorktreeInPane, .worktree):
            return .openWorktreeInPane(worktreeId: target)
        default:
            return nil
        }
    }

    private func executeTargetedReviewCommand(
        command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) -> Bool {
        guard targetType == .worktree else {
            return false
        }
        guard store.repositoryTopologyAtom.worktree(target) != nil else {
            return false
        }
        switch command {
        case .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab:
            return submitBridgeSurfaceCommand(command, worktreeId: target)
        default:
            return false
        }
    }

    func executeExtractPaneToTab(tabId: UUID, paneId: UUID, targetTabInsertionIndex: Int?) {
        handleExtractPaneRequested(
            tabId: tabId,
            paneId: paneId,
            targetTabInsertionIndex: targetTabInsertionIndex
        )
    }

    func executeMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID) {
        dispatchMovePaneToTab(
            sourcePaneId: sourcePaneId,
            sourceTabId: sourceTabId,
            targetTabId: targetTabId
        )
    }

    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        if command == .pinPane || command == .unpinPane {
            return canPinTargetedPane(paneId: target, targetType: targetType)
        }

        if targetType == .tab {
            switch command {
            case .renameTab, .closeTab, .saveArrangement, .newFloatingTerminal:
                return store.tabLayoutAtom.containsTab(target)
            case .splitRight, .splitLeft:
                return store.tabLayoutAtom.containsTab(target)
                    && store.tabLayoutAtom.activePaneID(forTab: target) != nil
                    && store.panePresentationAtom.zoomPresentation(forTab: target) == nil
            case .breakUpTab, .equalizePanes:
                return store.tabLayoutAtom.activeArrangementIsSplit(forTab: target)
            default:
                break
            }
        }

        if let targetedPaneCapability = targetedPaneCommandCapability(
            command,
            paneId: target,
            targetType: targetType
        ) {
            return targetedPaneCapability
        }

        if command == .previousArrangement || command == .nextArrangement {
            guard
                targetType == .tab,
                let tab = store.tabLayoutAtom.tab(target)
            else {
                return false
            }
            return tab.arrangements.count > 1
        }

        if command == .zoomPane, targetType == .pane {
            return zoomCommandCapability(explicitPaneId: target) != nil
        }

        if command == .showViewer, targetType == .pane {
            guard
                let activeTabId = store.tabLayoutAtom.activeTabId,
                let zoomPresentation = store.panePresentationAtom.zoomPresentation(forTab: activeTabId),
                zoomPresentation.sourcePaneId == target,
                let sourcePaneState = store.paneAtom.graphAtom.paneState(target),
                case .terminal = sourcePaneState.paneContent
            else {
                return false
            }
            return true
        }

        if command == .reloadBridgeWebView, targetType == .pane {
            return resolvedBridgeCommandMountView(paneId: target) != nil
        }

        if isPaneInboxCommand(command), isPaneInboxTargetType(targetType) {
            return paneInboxPresentation != nil && paneInboxTarget(anchorPaneId: target) != nil
        }

        if command == .focusPane, isPaneTargetType(targetType) {
            return canFocusTargetedPane(target)
        }

        if canExecuteTargetedTerminalRuntimeCommand(command, target: target),
            isPaneTargetType(targetType)
        {
            return true
        }

        if command == .showViewer, targetType == .worktree {
            return false
        }

        if Self.isTargetedBridgeCommand(command), targetType == .worktree {
            return store.repositoryTopologyAtom.validatedAssociation(
                repoId: store.repositoryTopologyAtom.repositoryId(containing: target), worktreeId: target
            ) != nil
        }

        if isTargetedPaneExternalCommand(command) {
            guard targetType == .pane else {
                return false
            }
            return targetedPaneExternalCommandCapability(command, paneId: target)
        }

        if let action = targetedAction(command: command, target: target, targetType: targetType) {
            return canDispatchAction(action)
        }

        switch (command, targetType) {
        case (.renameTab, .tab):
            return store.tabLayoutAtom.tab(target) != nil
        case (.renameArrangement, .tab):
            guard
                let arrangementTarget = arrangementTarget(target)
            else {
                return false
            }
            return !arrangementTarget.arrangement.isDefault
        default:
            return false
        }
    }

    private func canPinTargetedPane(paneId: UUID, targetType: SearchItemType) -> Bool {
        guard targetType == .pane else { return false }
        // Pin validation needs owned-pane membership, not a workspace-wide snapshot.
        // Retain the same tab-owned layout and drawer-child membership as knownPaneIds.
        if let tabId = store.tabLayoutAtom.tabID(containingPane: paneId),
            store.tabShellAtom.orderedTabIds.contains(tabId)
        {
            return true
        }
        guard
            let parentPaneId = store.paneAtom.graphAtom.paneStructuralFacts(paneId)?.parentPaneID,
            let tabId = store.tabLayoutAtom.tabID(containingPane: parentPaneId)
        else {
            return false
        }
        return store.tabShellAtom.orderedTabIds.contains(tabId)
    }

    func repoExplorerCommandCapabilities(
        _ requests: Set<RepoExplorerCommandPresentationRequest>
    ) -> [RepoExplorerCommandPresentationRequest: Bool] {
        let state = actionStateSnapshot()
        return Dictionary(
            uniqueKeysWithValues: requests.map { request in
                guard let target = request.target, let targetType = request.targetType else {
                    return (request, false)
                }
                if request.command == .zoomPane || request.command == .editPaneNote
                    || isTargetedPaneExternalCommand(request.command)
                {
                    return (request, canExecute(request.command, target: target, targetType: targetType))
                }
                if Self.isTargetedBridgeCommand(request.command) {
                    return (request, targetType == .worktree && state.knownWorktreeIds.contains(target))
                }
                guard
                    let action = targetedAction(
                        command: request.command,
                        target: target,
                        targetType: targetType
                    )
                else {
                    return (request, false)
                }
                if case .success = WorkspaceCommandValidator.validate(action, state: state) {
                    return (request, true)
                }
                return (request, false)
            })
    }

    private static func isTargetedBridgeCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab:
            true
        default:
            false
        }
    }

    private enum TargetedPaneCapabilityTarget {
        case layout(paneId: UUID, tabId: UUID, drawerId: UUID)
        case drawerChild(paneId: UUID, parentPaneId: UUID, tabId: UUID, drawerId: UUID)

        var paneId: UUID {
            switch self {
            case .layout(let paneId, _, _), .drawerChild(let paneId, _, _, _):
                return paneId
            }
        }

        var tabId: UUID {
            switch self {
            case .layout(_, let tabId, _), .drawerChild(_, _, let tabId, _):
                return tabId
            }
        }
    }

    private func targetedPaneCommandCapability(
        _ command: AppCommand,
        paneId: UUID,
        targetType: SearchItemType
    ) -> Bool? {
        if command.zoomDrawerTargetSide != nil {
            guard targetType == .pane else { return nil }
            return targetedPaneWorkspaceAction(command: command, paneId: paneId, targetType: targetType)
                .map(canDispatchAction) ?? false
        }
        switch command {
        case .minimizePane, .expandPane, .closePane, .splitRight, .detachDrawerPane,
            .extractPaneToTab, .movePaneToTab, .toggleDrawer, .addDrawerPane, .editPaneNote:
            break
        default:
            return nil
        }

        guard targetType == .pane else {
            return nil
        }
        guard let target = targetedPaneCapabilityTarget(paneId: paneId) else {
            return false
        }

        switch (command, target) {
        case (.minimizePane, .layout):
            return activeLayoutShowsPane(target)
                && store.panePresentationAtom.zoomPresentation(forTab: target.tabId) == nil
        case (.minimizePane, .drawerChild(_, _, let tabId, let drawerId)):
            return drawerParentIsShown(target)
                && store.tabLayoutAtom.activeDrawerLayoutContainsPane(
                    target.paneId,
                    drawerID: drawerId,
                    inTab: tabId
                )
                && !store.tabLayoutAtom.activeDrawerLayoutIsMinimized(
                    target.paneId,
                    drawerID: drawerId,
                    inTab: tabId
                )
        case (.expandPane, .layout):
            return store.tabLayoutAtom.activeLayoutIsMinimized(target.paneId, inTab: target.tabId)
                && store.panePresentationAtom.zoomPresentation(forTab: target.tabId) == nil
        case (.expandPane, .drawerChild(_, _, let tabId, let drawerId)):
            return drawerParentIsShown(target)
                && store.tabLayoutAtom.activeDrawerLayoutIsMinimized(
                    target.paneId,
                    drawerID: drawerId,
                    inTab: tabId
                )
        case (.closePane, _):
            return true
        case (.splitRight, .layout):
            return activeLayoutShowsPane(target)
                && store.panePresentationAtom.zoomPresentation(forTab: target.tabId) == nil
        case (.extractPaneToTab, .layout):
            let includingMinimized = atom(\.managementLayer).isActive
            return store.tabLayoutAtom.activeLayoutShowsPane(
                target.paneId,
                inTab: target.tabId,
                includingMinimized: includingMinimized
            )
                && store.tabLayoutAtom.activeLayoutVisiblePaneCount(
                    inTab: target.tabId,
                    includingMinimized: includingMinimized
                ) > 1
        case (.movePaneToTab, .layout):
            return store.tabLayoutAtom.activeLayoutContainsPane(target.paneId, inTab: target.tabId)
                && store.tabLayoutAtom.anotherTabHasNonemptyActiveLayout(excludingTabID: target.tabId)
        case (.detachDrawerPane, .drawerChild):
            return drawerParentIsShown(target)
        case (.toggleDrawer, .layout):
            return activeLayoutShowsPane(target)
        case (.addDrawerPane, .layout):
            return activeLayoutShowsPane(target)
        case (.editPaneNote, .layout):
            return activeLayoutShowsPane(target)
        case (.editPaneNote, .drawerChild):
            return drawerParentIsShown(target)
        default:
            return false
        }
    }

    private func targetedPaneCapabilityTarget(paneId: UUID) -> TargetedPaneCapabilityTarget? {
        guard let paneState = store.paneAtom.graphAtom.paneState(paneId) else {
            return nil
        }

        if let parentPaneId = paneState.parentPaneId {
            guard
                let parentPaneState = store.paneAtom.graphAtom.paneState(parentPaneId),
                parentPaneState.ownsDrawerChild(paneId),
                let drawerId = parentPaneState.ownedDrawerId,
                let tabId = store.tabLayoutAtom.tabID(containingPane: parentPaneId)
            else {
                return nil
            }
            return .drawerChild(
                paneId: paneId,
                parentPaneId: parentPaneId,
                tabId: tabId,
                drawerId: drawerId
            )
        }

        guard
            let drawerId = paneState.ownedDrawerId,
            let tabId = store.tabLayoutAtom.tabID(containingPane: paneId)
        else {
            return nil
        }
        return .layout(paneId: paneId, tabId: tabId, drawerId: drawerId)
    }

    private func activeLayoutShowsPane(_ target: TargetedPaneCapabilityTarget) -> Bool {
        store.tabLayoutAtom.activeLayoutShowsPane(
            target.paneId,
            inTab: target.tabId,
            includingMinimized: atom(\.managementLayer).isActive
        )
    }

    private func drawerParentIsShown(_ target: TargetedPaneCapabilityTarget) -> Bool {
        guard case .drawerChild(_, let parentPaneId, let tabId, _) = target else {
            return false
        }
        return store.tabLayoutAtom.activeLayoutShowsPane(
            parentPaneId,
            inTab: tabId,
            includingMinimized: atom(\.managementLayer).isActive
        )
    }

    private func workspacePresentationCommandAvailability(_ command: AppCommand) -> Bool? {
        if Self.shellOwnedNoOpCommands.contains(command) { return false }
        switch command {
        case .focusPreviousPinnedPane, .focusNextPinnedPane:
            return pinnedPanePreferences != nil && preferredVisibleFocusPaneId() != nil
        case .toggleManagementLayer:
            return true
        case .zoomPane:
            return zoomCommandCapability(explicitPaneId: nil) != nil
        case .showViewer:
            if let activeTabId = store.tabLayoutAtom.activeTabId,
                let zoomPresentation = store.panePresentationAtom.zoomPresentation(forTab: activeTabId)
            {
                guard
                    let sourcePaneState = store.paneAtom.graphAtom.paneState(
                        zoomPresentation.sourcePaneId
                    ),
                    case .terminal = sourcePaneState.paneContent
                else {
                    return false
                }
                return true
            }
            return zoomCommandCapability(explicitPaneId: nil) != nil
        case .reloadBridgeWebView:
            return resolvedBridgeCommandMountView() != nil
        case .openPullRequest:
            return false
        case .switchArrangement:
            return store.tabLayoutAtom.activeTabId != nil
        case .previousArrangement, .nextArrangement, .cycleArrangement:
            guard
                let activeTabId = store.tabLayoutAtom.activeTabId,
                let tab = store.tabLayoutAtom.tab(activeTabId)
            else {
                return false
            }
            return tab.arrangements.count > 1
        default:
            return nil
        }
    }

    private static let shellOwnedNoOpCommands: Set<AppCommand> = [
        .watchFolder, .toggleSidebar, .filterSidebar,
        .showInboxNotifications, .toggleInboxNotificationSort,
        .clearReadInboxNotifications, .clearAllInboxNotifications,
        .showReposSidebar, .showPanesSidebar,
        .setReposGroupingRepo, .setReposGroupingActivity,
        .setReposSortFieldName, .setReposSortFieldActivity,
        .setPanesSortFieldName, .setPanesSortFieldActivity,
        .toggleReposSortDirection, .togglePanesSortDirection,
        .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
        .signInGitHub, .signInGoogle,
    ]

    func canExecute(_ command: AppCommand) -> Bool {
        if let availability = workspacePresentationCommandAvailability(command) {
            return availability
        }
        switch command {
        case .managementLayerFocusLeft, .managementLayerFocusRight, .managementLayerEnterDrawer,
            .managementLayerExitDrawer, .managementLayerOpenDrawer,
            .managementLayerCreateTerminal, .managementLayerCreateBrowser, .managementLayerExit:
            return canExecuteManagementCommand(command)
        case .enterDrawer:
            return activeMainPaneId() != nil
        case .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown, .focusDrawerPaneRight:
            return drawerFocusNeighbor(for: command) != nil
        case .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4,
            .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8,
            .focusDrawerPane9:
            return resolveDrawerPaneOrdinalTarget(for: command) != nil
        case .navigateDrawerPane:
            guard let parentPaneId = activeMainPaneId() else { return false }
            return !(store.paneAtom.pane(parentPaneId)?.drawer?.paneIds.isEmpty ?? true)
        case .detachDrawerPane:
            if case .drawerPane = normalizedWorkspaceNavigationScopeState() {
                return true
            }
            return false
        case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown, .focusNextPane, .focusPrevPane:
            return makePaneKeyboardFocusTrigger(for: command) != nil
        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            return resolveMainPaneOrdinalTarget(for: command) != nil
        case .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9:
            return resolvePaneFocusTabSelectionTarget(for: command) != nil
        case .renameTab:
            return store.tabLayoutAtom.activeTabId != nil
        case .scrollToBottom, .scrollPageUp, .jumpToPreviousPrompt, .jumpToNextPrompt:
            return focusedTerminalCommandTargetPaneId() != nil
        case .addDrawerPane, .toggleDrawer, .closeDrawerPane, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge:
            return canExecuteContextualCommand(command)
        case .newTerminalInTab:
            guard
                let activeTabId = store.tabLayoutAtom.activeTabId,
                let targetPaneId = store.tabLayoutAtom.tab(activeTabId)?.activePaneId
            else {
                return false
            }
            return canDispatchAction(
                .insertPane(
                    source: .newTerminal,
                    targetTabId: activeTabId,
                    targetPaneId: targetPaneId,
                    direction: .right,
                    sizingMode: .halveTarget
                )
            )
        case .openWebview:
            guard let activeTabId = store.tabLayoutAtom.activeTabId else {
                return true
            }
            return store.panePresentationAtom.zoomPresentation(forTab: activeTabId) == nil
        case .showPaneInboxNotifications, .clearPaneInboxNotifications:
            return paneInboxPresentation != nil && activePaneInboxTarget() != nil
        case .openPaneLocationInBookmarkedEditor,
            .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu:
            return selectedPaneManagementContext()?.targetPath != nil
        case .editPaneNote:
            return activeMainPaneCommandTarget() != nil
        case .copyCurrentPanePath:
            return activeMainPanePath() != nil
        default:
            break
        }

        // Try resolving — if it resolves, validate it
        if let action = WorkspaceCommandResolver.resolve(
            command: command,
            tabs: store.tabLayoutAtom.tabs,
            activeTabId: store.tabLayoutAtom.activeTabId,
            visiblePaneIds: { [arrangementView] tab in
                arrangementView.activeVisiblePaneIds(forTab: tab.id)
            }
        ) {
            return canDispatchAction(action)
        }
        return true
    }

    private func handlePaneLocationCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .openPaneLocationInBookmarkedEditor:
            guard let targetPath = selectedPaneManagementContext()?.targetPath else { return false }
            return openPaneLocationInBookmarkedEditor(targetPath: targetPath)
        case .openPaneLocationInFinder:
            guard let targetPath = selectedPaneManagementContext()?.targetPath else { return false }
            return openFinderHandler(targetPath)
        case .openPaneLocationInEditorMenu:
            guard let activePaneId = activePaneIdForChooserRequest() else { return false }
            if editorChooser.openForPaneId == activePaneId {
                editorChooser.setOpenEditorPane(nil)
                return true
            }
            editorChooser.setAvailableTargets(installedEditorTargetsProvider())
            editorChooser.setOpenEditorPane(activePaneId)
            return true
        case .editPaneNote:
            guard let paneId = activeMainPaneCommandTarget() else { return false }
            paneNotePresentation.present(paneId)
            return true
        case .copyCurrentPanePath:
            guard let path = activeMainPanePath() else { return false }
            copyPathHandler(path)
            return true
        default:
            return false
        }
    }

    /// Launch the bookmarked external editor for an already-resolved path. The
    /// caller owns path selection, so both keyboard focus and an explicit
    /// programmatic pane reach the same editor-resolution owner.
    func openPaneLocationInBookmarkedEditor(targetPath: URL) -> Bool {
        let installedTargets = installedEditorTargetsProvider()
        var resolution = ExternalEditorTarget.resolveBookmarkedOrDefault(
            bookmarkedEditorId: editorChooser.bookmarkedEditorId,
            installedTargets: installedTargets
        )
        if case .bookmarkedEditorNotInstalled = resolution {
            // A saved bookmark that is no longer installed should heal back to
            // the implicit default launch order on the same key press.
            editorChooser.setBookmarkedEditor(nil)
            resolution = ExternalEditorTarget.resolveBookmarkedOrDefault(
                bookmarkedEditorId: nil,
                installedTargets: installedTargets
            )
        }
        guard case .resolved(let target) = resolution else { return false }
        return openEditorHandler(target.id, targetPath, installedTargets)
    }

    private func pullRequestURL(forPaneId paneId: UUID) -> URL? {
        guard
            targetedPaneCommandTarget(
                paneId: paneId,
                targetType: .pane
            ) != nil
        else {
            return nil
        }
        return GitHubWebviewLaunchResolver.pullRequestFacts(
            for: paneId,
            store: store,
            repoCache: repoCache
        )?.exactOpenURL
    }

    private func openPullRequest(forPaneId paneId: UUID) -> Bool {
        guard let pullRequestURL = pullRequestURL(forPaneId: paneId) else {
            return false
        }
        return openExternalURLHandler(pullRequestURL)
    }

    private func isTargetedPaneExternalCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .openPaneLocationInFinder, .copyCurrentPanePath, .openPaneLocationInEditorMenu,
            .openPullRequest:
            return true
        default:
            return false
        }
    }

    func targetedPaneLocationPath(paneId: UUID) -> URL? {
        guard
            targetedPaneCommandTarget(
                paneId: paneId,
                targetType: .pane
            ) != nil
        else {
            return nil
        }
        return PaneManagementContext.project(
            paneId: paneId,
            store: store
        ).targetPath
    }

    func targetedPaneExternalCommandCapability(
        _ command: AppCommand,
        paneId: UUID
    ) -> Bool {
        switch command {
        case .openPullRequest:
            return pullRequestURL(forPaneId: paneId) != nil
        case .openPaneLocationInFinder, .copyCurrentPanePath, .openPaneLocationInEditorMenu:
            return targetedPaneLocationPath(paneId: paneId) != nil
        default:
            return false
        }
    }

    func handleTargetedPaneExternalCommand(
        _ command: AppCommand,
        paneId: UUID
    ) -> Bool {
        if command == .openPullRequest {
            return openPullRequest(forPaneId: paneId)
        }
        guard let targetPath = targetedPaneLocationPath(paneId: paneId) else {
            return false
        }

        switch command {
        case .openPaneLocationInFinder:
            return openFinderHandler(targetPath)
        case .copyCurrentPanePath:
            copyPathHandler(targetPath)
            return true
        case .openPaneLocationInEditorMenu:
            if editorChooser.openForPaneId == paneId {
                editorChooser.setOpenEditorPane(nil)
                return true
            }
            editorChooser.setAvailableTargets(installedEditorTargetsProvider())
            editorChooser.setOpenEditorPane(paneId)
            return true
        default:
            return false
        }
    }

    private func handlePaneInboxCommand(_ command: AppCommand) -> Bool {
        guard let paneInboxPresentation, let target = activePaneInboxTarget() else { return false }
        switch command {
        case .showPaneInboxNotifications:
            paneInboxPresentation.toggle(target.parentPaneId, target.paneIds)
            return true
        case .clearPaneInboxNotifications:
            paneInboxPresentation.clear(target.parentPaneId, target.paneIds)
            return true
        default:
            return false
        }
    }

    private func handleTargetedPaneInboxCommand(
        _ command: AppCommand,
        target targetId: UUID,
        targetType: SearchItemType
    ) {
        guard isPaneInboxCommand(command), isPaneInboxTargetType(targetType) else { return }
        guard let paneInboxPresentation, let target = paneInboxTarget(anchorPaneId: targetId) else { return }

        switch command {
        case .showPaneInboxNotifications:
            // fire-and-forget: UI handler; the executor serializes the gesture, no caller reads it
            _ = dispatchGesture { [self] execute in
                guard await prepareAndApplyTargetFocus(paneId: targetId, execute: execute),
                    let currentTarget = paneInboxTarget(anchorPaneId: targetId)
                else {
                    return false
                }
                paneInboxPresentation.toggle(currentTarget.parentPaneId, currentTarget.paneIds)
                return true
            }
        case .clearPaneInboxNotifications:
            paneInboxPresentation.clear(target.parentPaneId, target.paneIds)
        default:
            return
        }
    }

    private func activePaneInboxTarget() -> PaneInboxCommandTarget? {
        guard let parentPaneId = activePaneInboxParentPaneId() else { return nil }
        return paneInboxTarget(anchorPaneId: parentPaneId)
    }

    private func paneInboxTarget(anchorPaneId: UUID) -> PaneInboxCommandTarget? {
        guard store.paneAtom.pane(anchorPaneId) != nil else { return nil }
        let scope = PaneInboxScopeResolver.resolve(
            anchorPaneId: anchorPaneId,
            pane: { store.paneAtom.pane($0) }
        )
        guard store.tabLayoutAtom.tabContaining(paneId: scope.parentPaneId) != nil else {
            return nil
        }
        return PaneInboxCommandTarget(parentPaneId: scope.parentPaneId, paneIds: scope.paneIds)
    }

    private func isPaneInboxCommand(_ command: AppCommand) -> Bool {
        command == .showPaneInboxNotifications || command == .clearPaneInboxNotifications
    }

    private func isPaneInboxTargetType(_ targetType: SearchItemType) -> Bool {
        targetType == .pane || targetType == .floatingTerminal
    }

    private func activePaneInboxParentPaneId() -> UUID? {
        guard let activePaneId = activeMainPaneId(),
            let activePane = store.paneAtom.pane(activePaneId)
        else {
            return nil
        }

        return activePane.parentPaneId ?? activePane.id
    }

    private func selectedPaneManagementContext() -> PaneManagementContext? {
        guard let paneId = selectedPaneIdForLocationCommands() else {
            return nil
        }

        return PaneManagementContext.project(
            paneId: paneId,
            store: store
        )
    }

    private func activeMainPaneCommandTarget() -> UUID? {
        guard case .mainPane(let paneId) = normalizedWorkspaceNavigationScopeState(),
            let activePaneId = paneId ?? activeMainPaneId(),
            let pane = store.paneAtom.pane(activePaneId),
            pane.parentPaneId == nil
        else {
            return nil
        }

        return activePaneId
    }

    private func requestPaneNotePresentation(for paneId: UUID) {
        guard store.paneAtom.pane(paneId) != nil else {
            Self.logger.warning("editPaneNote presentation ignored: pane \(paneId) not found")
            return
        }

        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                self?.presentPaneNotePopover(for: paneId)
            }
        }
    }

    private func presentPaneNotePopover(for paneId: UUID) {
        guard let pane = store.paneAtom.pane(paneId) else {
            Self.logger.warning("editPaneNote presentation ignored after defer: pane \(paneId) not found")
            return
        }

        closePaneNotePopover()
        guard isViewLoaded else { return }

        let resolvedWindowId =
            workspaceWindowId ?? windowLifecycleStore.focusedWindowId
            ?? windowLifecycleStore.keyWindowId
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PaneNotePopover(
                currentNote: pane.metadata.note,
                onCommit: { [weak self] note in
                    guard let self else { return }
                    self.store.paneAtom.updatePaneNote(paneId, note: note)
                    self.closePaneNotePopover()
                },
                onCancel: { [weak self] in
                    self?.closePaneNotePopover()
                }
            )
            .transientKeyboardSurface(
                .paneNote(paneId: paneId),
                workspaceWindowId: resolvedWindowId,
                onDismiss: { [weak self] in
                    self?.closePaneNotePopover()
                }
            )
            .tint(AppStyles.General.Accent.primaryColor)
        )
        paneNotePopover = popover

        let anchorView = viewRegistry.view(for: paneId) ?? view
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    private func closePaneNotePopover() {
        let popover = paneNotePopover
        paneNotePopover = nil
        popover?.delegate = nil
        popover?.close()
    }

    private func activeMainPanePath() -> URL? {
        guard let paneId = activeMainPaneCommandTarget(),
            let pane = store.paneAtom.pane(paneId)
        else {
            return nil
        }

        return pane.metadata.cwd ?? pane.metadata.launchDirectory
    }

    private func activePaneIdForChooserRequest() -> UUID? {
        selectedPaneIdForLocationCommands()
    }

    private func selectedPaneIdForLocationCommands() -> UUID? {
        guard let parentPaneId = activeMainPaneId() else {
            return nil
        }

        if let drawerPaneId = visibleActiveDrawerPaneId(for: parentPaneId) {
            return drawerPaneId
        }

        return parentPaneId
    }
}

#if DEBUG
    extension PaneTabViewController {
        var splitHostingViewForTesting: NSView? { activeTabHost()?.hostingView }
        var appLifecycleStoreForTesting: AppLifecycleAtom { appLifecycleStore }
        func tabHostViewForTesting(tabId: UUID) -> NSView? {
            tabContentHosts[tabId]
        }
        func syncTabContentHostsForTesting() {
            syncTabContentHosts()
            updateVisibleTabHost()
        }
        var paneRepresentableDismantleCountForTesting: Int {
            paneRepresentableDismantleCount
        }
        var managementNavigationScopeDescriptionForTesting: String {
            switch managementNavigationScope {
            case .mainRow:
                return "mainRow"
            case .drawer(let parentPaneId):
                return "drawer:\(parentPaneId.uuidString)"
            }
        }
        func setManagementNavigationScopeToDrawerForTesting(parentPaneId: UUID) {
            managementNavigationScope = .drawer(parentPaneId: parentPaneId)
        }
    }
#endif
