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
struct PaneTabViewControllerCommandHarness {
    let atomRegistry: AtomRegistry
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let coordinator: WorkspaceSurfaceCoordinator
    let executor: WorkspaceActionExecutor
    let controller: PaneTabViewController
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
    let controller = PaneTabViewController(
        store: store,
        octiconLoader: makeTestOcticonLoader(),
        repoCache: repoCache,
        applicationLifecycleMonitor: ApplicationLifecycleMonitor(
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore
        ),
        appLifecycleStore: appLifecycleStore,
        windowLifecycleStore: windowLifecycleStore,
        workspaceWindowId: workspaceWindowId,
        executor: executor,
        runtimeCommandDispatcher: coordinator,
        tabBarAdapter: makeCommandHarnessTabBarAdapter(
            store: store,
        ),
        viewRegistry: viewRegistry,
        bridgePaneAttendance: atomRegistry.bridgePaneAttendance,
        editorChooser: atomRegistry.editorChooser,
        sessionsPaneViewedMailbox: sessionsPaneViewedMailbox,
        paneInboxPresentation: nil,
        pinnedPanePreferences: RepoExplorerSidebarPrefsAtom(sidebarState: CoreAtomScope.store.workspaceSidebarState),
        installedEditorTargetsProvider: { [.cursor, .vscode] },
        openEditorHandler: { editorId, path, _ in
            launchRecorder.openedEditors.append((id: editorId, path: path))
            return true
        },
        openFinderHandler: launchRecorder.openFinder,
        openExternalURLHandler: launchRecorder.openExternalURL,
        copyPathHandler: { path in
            launchRecorder.copiedPaths.append(path)
        },
        paneNotePresentation: makeCommandHarnessPaneNotePresentation(
            launchRecorder: launchRecorder
        ),
        closeTransitionCoordinator: closeTransitionCoordinator,
        heldPanePreviewState: HeldPanePreviewState(),
        tabRenamePopoverState: tabRenamePopoverState,
        arrangementInlineRenameState: arrangementInlineRenameState,
        arrangementPanelPresentation: arrangementPanelPresentation,
        bridgeViewerSurfaceRequestHandler: bridgeViewerSurfaceRequestHandler,
        bridgeViewerOpenTelemetryAnchorFactory: bridgeViewerOpenTelemetryAnchorFactory,
        interactionProbe: interactionProbe,
        registersAsCommandHandler: false
    )
    return PaneTabViewControllerCommandHarness(
        atomRegistry: atomRegistry,
        store: store,
        repoCache: repoCache,
        coordinator: coordinator,
        executor: executor,
        controller: controller,
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
        launchRecorder: launchRecorder
    )
}

@MainActor
private func makeCommandHarnessPaneNotePresentation(
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
private func makeCommandHarnessTabBarAdapter(
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
) -> NSWindow {
    let window = NSWindow(
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
