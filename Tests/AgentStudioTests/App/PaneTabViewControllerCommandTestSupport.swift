import AgentStudioProgrammaticControl
import AgentStudioSessions
import AppKit
import Foundation
import GhosttyKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

typealias Harness = PaneTabViewControllerCommandHarness

@MainActor
final class PaneTabViewControllerCommandLaunchRecorder {
    var openedEditors: [(id: EditorTargetId, path: URL)] = []
    var revealedPaths: [URL] = []
    var openedExternalURLs: [URL] = []
    var copiedPaths: [URL] = []
    var paneNoteRequests: [UUID] = []

    func openFinder(_ path: URL) -> Bool {
        revealedPaths.append(path)
        return true
    }

    func openExternalURL(_ url: URL) -> Bool {
        openedExternalURLs.append(url)
        return true
    }
}

@MainActor
enum CommandHarnessWorkspaceOwner {
    case controller
    case external(any WorkspaceCommandHandling)
    case unavailable
}

@MainActor
final class PaneTabViewControllerCommandHarness {
    let atomRegistry: AtomRegistry
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let coordinator: WorkspaceSurfaceCoordinator
    let executor: WorkspaceActionExecutor
    private let buildController: @MainActor (AppCommandDispatcher) -> PaneTabViewController
    private let suppliedCommandDispatcher: AppCommandDispatcher?
    private let shellCommandOwner: (any ShellCommandHandling)?
    private let workspaceCommandOwner: CommandHarnessWorkspaceOwner
    private let commandInteractionProbe: AgentStudioInteractionPerformanceProbe?
    private let commandRefreshAccepted: @MainActor (UUID) -> Void
    private var controllerWasConstructed = false
    private lazy var ownedCommandDispatcher: AppCommandDispatcher = {
        if let suppliedCommandDispatcher { return suppliedCommandDispatcher }
        return AppCommandDispatcher(
            dependencies: .init(
                shellOwnerAccess: { [weak self] in self?.shellCommandOwner },
                workspaceOwnerAccess: { [weak self] in self?.selectedWorkspaceCommandOwner() },
                interactionProbeAccess: { [weak self] in self?.commandInteractionProbe },
                commandRefreshAccepted: { [weak self] in self?.commandRefreshAccepted($0) }
            ))
    }()
    var commandDispatcher: AppCommandDispatcher { ownedCommandDispatcher }
    private(set) lazy var controller: PaneTabViewController = {
        let controller = buildController(ownedCommandDispatcher)
        controllerWasConstructed = true
        return controller
    }()

    private func selectedWorkspaceCommandOwner() -> (any WorkspaceCommandHandling)? {
        switch workspaceCommandOwner {
        case .controller: controllerWasConstructed ? controller : nil
        case .external(let owner): owner
        case .unavailable: nil
        }
    }
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let viewRegistry: ViewRegistry
    let runtimeRegistry: RuntimeRegistry
    let surfaceManager: MockPaneTabCommandSurfaceManager
    let bridgeGitReadScheduler: BridgeGitReadScheduler
    let appLifecycleStore: AppLifecycleAtom
    let windowLifecycleStore: WindowLifecycleAtom
    let tempDir: URL
    let tabRenamePopoverState: TabRenamePopoverState
    let arrangementInlineRenameState: ArrangementInlineRenameState
    let arrangementPanelPresentation: ArrangementPanelPresentationAtom
    let launchRecorder: PaneTabViewControllerCommandLaunchRecorder

    init(
        atomRegistry: AtomRegistry,
        store: WorkspaceStore,
        repoCache: RepoCacheAtom,
        coordinator: WorkspaceSurfaceCoordinator,
        executor: WorkspaceActionExecutor,
        closeTransitionCoordinator: PaneCloseTransitionCoordinator,
        viewRegistry: ViewRegistry,
        runtimeRegistry: RuntimeRegistry,
        surfaceManager: MockPaneTabCommandSurfaceManager,
        bridgeGitReadScheduler: BridgeGitReadScheduler,
        appLifecycleStore: AppLifecycleAtom,
        windowLifecycleStore: WindowLifecycleAtom,
        tempDir: URL,
        tabRenamePopoverState: TabRenamePopoverState,
        arrangementInlineRenameState: ArrangementInlineRenameState,
        arrangementPanelPresentation: ArrangementPanelPresentationAtom,
        launchRecorder: PaneTabViewControllerCommandLaunchRecorder,
        buildController: @escaping @MainActor (AppCommandDispatcher) -> PaneTabViewController,
        commandDispatcher: AppCommandDispatcher?,
        shellCommandOwner: (any ShellCommandHandling)?,
        workspaceCommandOwner: CommandHarnessWorkspaceOwner,
        commandInteractionProbe: AgentStudioInteractionPerformanceProbe?,
        commandRefreshAccepted: @escaping @MainActor (UUID) -> Void
    ) {
        self.atomRegistry = atomRegistry
        self.store = store
        self.repoCache = repoCache
        self.coordinator = coordinator
        self.executor = executor
        self.closeTransitionCoordinator = closeTransitionCoordinator
        self.viewRegistry = viewRegistry
        self.runtimeRegistry = runtimeRegistry
        self.surfaceManager = surfaceManager
        self.bridgeGitReadScheduler = bridgeGitReadScheduler
        self.appLifecycleStore = appLifecycleStore
        self.windowLifecycleStore = windowLifecycleStore
        self.tempDir = tempDir
        self.tabRenamePopoverState = tabRenamePopoverState
        self.arrangementInlineRenameState = arrangementInlineRenameState
        self.arrangementPanelPresentation = arrangementPanelPresentation
        self.launchRecorder = launchRecorder
        self.buildController = buildController
        self.suppliedCommandDispatcher = commandDispatcher
        self.shellCommandOwner = shellCommandOwner
        self.workspaceCommandOwner = workspaceCommandOwner
        self.commandInteractionProbe = commandInteractionProbe
        self.commandRefreshAccepted = commandRefreshAccepted
    }

    /// Await submitted work before observing UI state; this is not a command success result.
    func executeCommand(_ command: AppCommand) async {
        controller.execute(command)
        _ = await executor.submitGesture { _ in true }.value
    }

    func executeCommand(_ command: AppCommand, target: UUID, targetType: SearchItemType) async {
        controller.execute(command, target: target, targetType: targetType)
        _ = await executor.submitGesture { _ in true }.value
    }

    func executeHeadlessPaneCommand(
        _ command: AppCommand,
        paneId: UUID
    ) async throws -> AppCommandExecutionOutcome {
        let paneSelector = try IPCPaneSelector(rawValue: paneId.uuidString)
        return await controller.executeHeadlessIPC(
            AppCommandExecutionRequest(
                command: command,
                arguments: .typedIPC(
                    .pane(
                        .init(
                            workspaceWindowId: UUIDv7.generate(),
                            paneSelector: paneSelector
                        )
                    )
                ),
                executionContext: .headlessIPC(admitsDebugTestingCommands: true)
            )
        )
    }
}

@MainActor
func makeHarness(
    commandDispatcher: AppCommandDispatcher? = nil,
    shellCommandOwner: (any ShellCommandHandling)? = nil,
    workspaceCommandOwner: CommandHarnessWorkspaceOwner = .controller,
    commandRefreshAccepted: @escaping @MainActor (UUID) -> Void = { _ in },
    store injectedStore: WorkspaceStore? = nil,
    createSurfaceResult: Result<ManagedSurface, SurfaceError> = .failure(.ghosttyNotInitialized),
    closeTransitionCoordinator: PaneCloseTransitionCoordinator = PaneCloseTransitionCoordinator(),
    arrangementPanelPresentation: ArrangementPanelPresentationAtom = ArrangementPanelPresentationAtom(),
    windowLifecycleStore: WindowLifecycleAtom? = nil,
    workspaceWindowId: UUID? = nil,
    bridgeGitReadScheduler: BridgeGitReadScheduler = BridgeGitReadScheduler(topology: .recoveryBaseline),
    paneEventBus: EventBus<RuntimeEnvelope> = makeTestPaneRuntimeEventBus(),
    traceRuntime: AgentStudioTraceRuntime? = nil,
    bridgeViewerSurfaceRequestHandler: (@MainActor (BridgeProductSurface, UUID) -> Bool)? = nil,
    bridgeViewerOpenTelemetryAnchorFactory: @escaping @MainActor () -> BridgeViewerOpenTelemetryAnchor = {
        .live()
    },
    interactionProbe: AgentStudioInteractionPerformanceProbe? = nil,
    sessionsPaneViewedMailbox: SessionsPaneViewedMailbox? = nil
) -> Harness {
    makePaneTabViewControllerCommandHarness(
        commandDispatcher: commandDispatcher,
        shellCommandOwner: shellCommandOwner,
        workspaceCommandOwner: workspaceCommandOwner,
        commandRefreshAccepted: commandRefreshAccepted,
        store: injectedStore,
        createSurfaceResult: createSurfaceResult,
        closeTransitionCoordinator: closeTransitionCoordinator,
        arrangementPanelPresentation: arrangementPanelPresentation,
        windowLifecycleStore: windowLifecycleStore,
        workspaceWindowId: workspaceWindowId,
        bridgeGitReadScheduler: bridgeGitReadScheduler,
        paneEventBus: paneEventBus,
        traceRuntime: traceRuntime,
        bridgeViewerSurfaceRequestHandler: bridgeViewerSurfaceRequestHandler,
        bridgeViewerOpenTelemetryAnchorFactory: bridgeViewerOpenTelemetryAnchorFactory,
        interactionProbe: interactionProbe,
        sessionsPaneViewedMailbox: sessionsPaneViewedMailbox
    )
}

@MainActor
func makePaneTabViewControllerCommandHarness(
    commandDispatcher: AppCommandDispatcher? = nil,
    shellCommandOwner: (any ShellCommandHandling)? = nil,
    workspaceCommandOwner: CommandHarnessWorkspaceOwner = .controller,
    commandRefreshAccepted: @escaping @MainActor (UUID) -> Void = { _ in },
    store injectedStore: WorkspaceStore? = nil,
    createSurfaceResult: Result<ManagedSurface, SurfaceError> = .failure(.ghosttyNotInitialized),
    closeTransitionCoordinator: PaneCloseTransitionCoordinator = PaneCloseTransitionCoordinator(),
    arrangementPanelPresentation: ArrangementPanelPresentationAtom = ArrangementPanelPresentationAtom(),
    windowLifecycleStore injectedWindowLifecycleStore: WindowLifecycleAtom? = nil,
    workspaceWindowId: UUID? = nil,
    bridgeGitReadScheduler: BridgeGitReadScheduler = BridgeGitReadScheduler(topology: .recoveryBaseline),
    paneEventBus: EventBus<RuntimeEnvelope> = makeTestPaneRuntimeEventBus(),
    traceRuntime: AgentStudioTraceRuntime? = nil,
    bridgeViewerSurfaceRequestHandler: (@MainActor (BridgeProductSurface, UUID) -> Bool)? = nil,
    bridgeViewerOpenTelemetryAnchorFactory: @escaping @MainActor () -> BridgeViewerOpenTelemetryAnchor = {
        .live()
    },
    interactionProbe: AgentStudioInteractionPerformanceProbe? = nil,
    sessionsPaneViewedMailbox: SessionsPaneViewedMailbox? = nil
) -> PaneTabViewControllerCommandHarness {
    // Command execution still reads the app-global management-layer atom for
    // visibility and shortcut policy. Reset it so parallel suites cannot leak
    // management mode into a fresh command harness.
    atom(\.managementLayer).deactivate()

    let atomRegistry = AtomRegistry(core: CoreAtomScope.store)
    let tempDir = makePaneTabCommandHarnessTempDir()
    let store = injectedStore ?? makeRequiredCommandHarnessStore()
    let viewRegistry = ViewRegistry()
    let runtime = SessionRuntime(store: store)
    let surfaceManager = MockPaneTabCommandSurfaceManager(createSurfaceResult: createSurfaceResult)
    let runtimeRegistry = RuntimeRegistry()
    let appLifecycleStore = AppLifecycleAtom()
    let windowLifecycleStore = injectedWindowLifecycleStore ?? WindowLifecycleAtom()
    let tabRenamePopoverState = TabRenamePopoverState()
    let arrangementInlineRenameState = ArrangementInlineRenameState()
    let launchRecorder = PaneTabViewControllerCommandLaunchRecorder()
    let repoCache = RepoCacheAtom()
    let coordinator = WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: viewRegistry,
        runtime: runtime,
        surfaceManager: surfaceManager,
        terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
        terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
        runtimeRegistry: runtimeRegistry,
        paneEventBus: paneEventBus,
        closeTransitionCoordinator: closeTransitionCoordinator,
        bridgeGitReadScheduler: bridgeGitReadScheduler,
        windowLifecycleStore: windowLifecycleStore,
        appLifecycleStore: appLifecycleStore,
        ipcLifecycle: .testUnavailable,
        bridgePaneAttendance: atomRegistry.bridgePaneAttendance,
        traceRuntime: traceRuntime
    )
    let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
    let buildController = makePaneTabCommandControllerBuilder(
        composition: .init(
            store: store,
            repoCache: repoCache,
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore,
            workspaceWindowId: workspaceWindowId,
            executor: executor,
            coordinator: coordinator,
            surfaceManager: surfaceManager,
            viewRegistry: viewRegistry,
            atomRegistry: atomRegistry,
            sessionsPaneViewedMailbox: sessionsPaneViewedMailbox,
            launchRecorder: launchRecorder,
            closeTransitionCoordinator: closeTransitionCoordinator,
            tabRenamePopoverState: tabRenamePopoverState,
            arrangementInlineRenameState: arrangementInlineRenameState,
            arrangementPanelPresentation: arrangementPanelPresentation,
            bridgeViewerSurfaceRequestHandler: bridgeViewerSurfaceRequestHandler,
            bridgeViewerOpenTelemetryAnchorFactory: bridgeViewerOpenTelemetryAnchorFactory,
            interactionProbe: interactionProbe
        ))
    let harness = PaneTabViewControllerCommandHarness(
        atomRegistry: atomRegistry,
        store: store,
        repoCache: repoCache,
        coordinator: coordinator,
        executor: executor,
        closeTransitionCoordinator: closeTransitionCoordinator,
        viewRegistry: viewRegistry,
        runtimeRegistry: runtimeRegistry,
        surfaceManager: surfaceManager,
        bridgeGitReadScheduler: bridgeGitReadScheduler,
        appLifecycleStore: appLifecycleStore,
        windowLifecycleStore: windowLifecycleStore,
        tempDir: tempDir,
        tabRenamePopoverState: tabRenamePopoverState,
        arrangementInlineRenameState: arrangementInlineRenameState,
        arrangementPanelPresentation: arrangementPanelPresentation,
        launchRecorder: launchRecorder,
        buildController: buildController,
        commandDispatcher: commandDispatcher,
        shellCommandOwner: shellCommandOwner,
        workspaceCommandOwner: workspaceCommandOwner,
        commandInteractionProbe: interactionProbe,
        commandRefreshAccepted: commandRefreshAccepted
    )
    _ = harness.controller
    return harness
}

@MainActor
func makeCommandHarnessPaneNotePresentation(
    launchRecorder: PaneTabViewControllerCommandLaunchRecorder
) -> PaneNotePresentation {
    PaneNotePresentation(
        present: { paneId in
            launchRecorder.paneNoteRequests.append(paneId)
        },
        editorContent: { _, _ in AnyView(EmptyView()) }
    )
}

@MainActor
private func makeRequiredCommandHarnessStore() -> WorkspaceStore {
    do { return try makeWorkspaceJournalTestStore() } catch {
        preconditionFailure("Could not prepare the command harness SQLite store: \(error)")
    }
}

@MainActor
func makeCommandHarnessTabBarAdapter(
    store: WorkspaceStore
) -> TabBarAdapter {
    TabBarAdapter(
        store: store,
        repoCache: RepoCacheAtom()
    )
}

private func makePaneTabCommandHarnessTempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "agentstudio-pane-tab-command-\(UUID().uuidString)")
}

@MainActor
func configureMainWindowKeyboardOwner(_ coreAtoms: CoreAtoms) {
    configureMainWindowKeyboardOwner(
        windowLifecycleStore: coreAtoms.windowLifecycle,
        coreAtoms: coreAtoms
    )
}

@MainActor
func configureMainWindowKeyboardOwner(
    windowLifecycleStore: WindowLifecycleAtom,
    coreAtoms: CoreAtoms = CoreAtomScope.store
) {
    let windowId = UUID()
    windowLifecycleStore.recordWindowRegistered(windowId)
    windowLifecycleStore.recordWindowBecameKey(windowId)
    coreAtoms.workspaceSidebarState.setSidebarCollapsed(false)
    coreAtoms.workspaceSidebarState.setSidebarHasFocus(false)
    coreAtoms.managementLayer.deactivate()
}

@MainActor
func configureMainWindowKeyboardOwner() {
    configureMainWindowKeyboardOwner(CoreAtomScope.store)
}

@MainActor
func makeRepoAndWorktree(_ store: WorkspaceStore, root: URL) -> (Repo, Worktree) {
    makePaneTabViewControllerCommandRepoAndWorktree(store, root: root)
}

@MainActor
func makePaneTabViewControllerCommandRepoAndWorktree(
    _ store: WorkspaceStore,
    root: URL
) -> (Repo, Worktree) {
    let repoPath = root.appending(path: "repo-\(UUID().uuidString)")
    let worktreePath = repoPath.appending(path: "wt-main")
    try? FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)

    let repo = store.addRepo(at: repoPath)
    let worktree = Worktree(repoId: repo.id, name: "wt-main", path: worktreePath)
    store.reconcileDiscoveredWorktrees(repo.id, worktrees: repo.worktrees + [worktree])
    return store.repositoryTopologyAtom.repoAndWorktree(containing: worktreePath) ?? (repo, worktree)
}

@MainActor
func expectWebviewContent(_ pane: Pane, issuePrefix: String) {
    expectPaneTabViewControllerCommandWebviewContent(pane, issuePrefix: issuePrefix)
}

@MainActor
func expectPaneTabViewControllerCommandWebviewContent(_ pane: Pane, issuePrefix: String) {
    if case .webview = pane.content {
    } else {
        Issue.record("\(issuePrefix): expected created pane to be a webview")
    }
}

@MainActor
func makePaneTabViewControllerCommandWindow(
    for controller: PaneTabViewController
) -> PaneResponderTrackingWindow {
    let window = PaneResponderTrackingWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 1200, height: 800),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    window.contentViewController = controller
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

@MainActor
@discardableResult
func attachPaneHost(
    paneId: UUID,
    in harness: PaneTabViewControllerCommandHarness,
    to window: NSWindow,
    mountedContent: (NSView & PaneMountedContent)? = nil
) throws -> PaneHostView {
    let host = PaneHostView(paneId: paneId)
    if let mountedContent {
        host.mountContentView(mountedContent)
    }
    harness.viewRegistry.register(host, for: paneId)
    let contentView = try #require(window.contentView)
    host.frame = contentView.bounds
    contentView.addSubview(host)
    return host
}

@MainActor
final class FocusablePaneTabCommandMountedContentView: NSView, PaneMountedContent {
    private let focusEvents: AsyncStream<Void>
    private let focusEventContinuation: AsyncStream<Void>.Continuation

    override init(frame frameRect: NSRect) {
        (focusEvents, focusEventContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            focusEventContinuation.yield()
        }
        return accepted
    }

    func makeFocusEventIterator() -> AsyncStream<Void>.AsyncIterator {
        focusEvents.makeAsyncIterator()
    }

    func setContentInteractionEnabled(_: Bool) {}

    deinit {
        focusEventContinuation.finish()
    }
}

final class MockPaneTabCommandSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    private let createSurfaceResult: Result<ManagedSurface, SurfaceError>

    private(set) var createSurfaceCallCount = 0
    private(set) var lastCreatedSurfaceMetadata: SurfaceMetadata?
    private(set) var attachedSurfaceRequests: [(surfaceId: UUID, paneId: UUID)] = []
    private(set) var detachedSurfaceRequests: [(surfaceId: UUID, reason: SurfaceDetachReason)] = []

    init(createSurfaceResult: Result<ManagedSurface, SurfaceError>) {
        self.createSurfaceResult = createSurfaceResult
    }

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        createSurfaceCallCount += 1
        lastCreatedSurfaceMetadata = metadata
        return createSurfaceResult
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        attachedSurfaceRequests.append((surfaceId: surfaceId, paneId: paneId))
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        detachedSurfaceRequests.append((surfaceId: surfaceId, reason: reason))
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {}
}

@MainActor
func withWorkspaceCommandHarness(
    _ harness: PaneTabViewControllerCommandHarness,
    operation: @MainActor () async throws -> Void
) async rethrows {
    do { try await operation() } catch {
        await harness.executor.stopAcceptingCommandsAndDrain()
        await harness.coordinator.shutdown()
        throw error
    }
    await harness.executor.stopAcceptingCommandsAndDrain()
    await harness.coordinator.shutdown()
}
