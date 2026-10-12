import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import SwiftUI

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
struct MainSplitViewControllerHarness {
    let atoms: AtomRegistry
    let store: WorkspaceStore
    let coordinator: WorkspaceSurfaceCoordinator
    let controller: MainSplitViewController
    let window: NSWindow
    let tempDir: URL
    let surfaceManager: MainSplitViewControllerTestSurfaceManager
}

typealias MainSplitViewControllerTestSidebarBuilder =
    @MainActor (WorkspaceSidebarState, @escaping () -> Void) -> AnyView

@MainActor
private struct MainSplitViewControllerHarnessConfiguration {
    let commandDispatcher: AppCommandDispatcher?
    let configureUIState: @MainActor (WorkspaceSidebarState) -> Void
    let configureWorkspaceWindowMemory: @MainActor (WorkspaceWindowMemoryAtom) -> Void
    let configureSidebarDependencies: @MainActor (SidebarRootViewDependencies) -> Void
}

@MainActor
private func makeMainSplitViewControllerHarness(
    withRepos: Bool,
    inboxAtom: InboxNotificationAtom,
    paneTabRegistersAsCommandHandler: Bool,
    configuration: MainSplitViewControllerHarnessConfiguration,
    sidebarRootViewBuilder: @escaping MainSplitViewControllerTestSidebarBuilder
) -> MainSplitViewControllerHarness {
    let tempDir = FileManager.default.temporaryDirectory
        .appending(path: "main-split-view-controller-tests-\(UUID().uuidString)")
    let atoms = makeTestAtomRegistry()
    configuration.configureUIState(atoms.core.workspaceSidebarState)

    let store = WorkspaceStore(
        identityAtom: atoms.core.workspaceIdentity,
        windowMemoryAtom: atoms.core.workspaceWindowMemory,
        repositoryTopologyAtom: atoms.core.workspaceRepositoryTopology,
        paneAtom: atoms.core.workspacePane,
        tabLayoutAtom: atoms.core.workspaceTabLayout,
        mutationCoordinator: atoms.core.workspaceMutationCoordinator)
    configuration.configureWorkspaceWindowMemory(atoms.core.workspaceWindowMemory)

    if withRepos {
        _ = store.addRepo(at: tempDir.appending(path: "repo"))
    }

    let viewRegistry = ViewRegistry()
    let runtime = SessionRuntime(atom: atoms.core.sessionRuntime, store: store)
    let surfaceManager = MainSplitViewControllerTestSurfaceManager()
    let coordinator = WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: viewRegistry,
        runtime: runtime,
        surfaceManager: surfaceManager,
        terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
        terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
        runtimeRegistry: RuntimeRegistry(),
        windowLifecycleStore: WindowLifecycleAtom(),
        ipcLifecycle: .testUnavailable,
        bridgePaneAttendance: atoms.bridgePaneAttendance
    )
    let workspaceActionExecutor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
    let appLifecycleStore = AppLifecycleAtom()
    let applicationLifecycleMonitor = ApplicationLifecycleMonitor(
        appLifecycleStore: appLifecycleStore,
        windowLifecycleStore: WindowLifecycleAtom()
    )
    let tabBarAdapter = TabBarAdapter(
        store: store,
        repoCache: atoms.core.repoCache
    )
    let commandDispatcher = configuration.commandDispatcher ?? CommandDispatcherFixtureConfiguration().makeDispatcher()
    let controller = MainSplitViewController(
        store: store,
        octiconLoader: makeTestOcticonLoader(),
        workspaceActionExecutor: workspaceActionExecutor,
        runtimeCommandDispatcher: coordinator,
        commandDispatcher: commandDispatcher,
        resolveCommandCapabilities: {
            commandDispatcher.repoExplorerCommandPresentationSnapshot(
                requests: $0, generation: $1)
        },
        executionOwnerIdentities: commandDispatcher.executionOwnerIdentities, synchronizeRuntimeFocus: { _ in },
        applicationLifecycleMonitor: applicationLifecycleMonitor,
        appLifecycleStore: appLifecycleStore,
        tabBarAdapter: tabBarAdapter,
        viewRegistry: viewRegistry,
        repoExplorerSidebarPrefs: atoms.repoExplorerSidebarPrefs,
        bridgeAttendanceSnapshot: { paneId in
            atoms.bridgePaneAttendance.ordinal(for: paneId)
        },
        bridgePaneAttendance: atoms.bridgePaneAttendance,
        editorChooser: atoms.editorChooser,
        sidebarRootViewBuilder: { dependencies in
            configuration.configureSidebarDependencies(dependencies)
            return sidebarRootViewBuilder(
                atoms.core.workspaceSidebarState,
                dependencies.onRefocusActivePane
            )
        },
        paneTabRegistersAsCommandHandler: paneTabRegistersAsCommandHandler
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )

    return MainSplitViewControllerHarness(
        atoms: atoms,
        store: store,
        coordinator: coordinator,
        controller: controller,
        window: window,
        tempDir: tempDir,
        surfaceManager: surfaceManager
    )
}

@MainActor
func withMainSplitViewControllerHarness<T>(
    withRepos: Bool = true,
    inboxAtom: InboxNotificationAtom = InboxNotificationAtom(),
    paneTabRegistersAsCommandHandler: Bool = false,
    commandDispatcher: AppCommandDispatcher? = nil,
    configureUIState: @escaping @MainActor (WorkspaceSidebarState) -> Void = { _ in },
    configureWorkspaceWindowMemory:
        @escaping @MainActor (WorkspaceWindowMemoryAtom) -> Void = { _ in },
    configureSidebarDependencies: @escaping @MainActor (SidebarRootViewDependencies) -> Void = { _ in },
    sidebarRootViewBuilder: @escaping MainSplitViewControllerTestSidebarBuilder = { uiState, onEscape in
        AnyView(MainSplitViewControllerTestSidebarView(uiState: uiState, onEscape: onEscape))
    },
    body: @MainActor (MainSplitViewControllerHarness) async throws -> T
) async rethrows -> T {
    let harness = makeMainSplitViewControllerHarness(
        withRepos: withRepos,
        inboxAtom: inboxAtom,
        paneTabRegistersAsCommandHandler: paneTabRegistersAsCommandHandler,
        configuration: MainSplitViewControllerHarnessConfiguration(
            commandDispatcher: commandDispatcher,
            configureUIState: configureUIState,
            configureWorkspaceWindowMemory: configureWorkspaceWindowMemory,
            configureSidebarDependencies: configureSidebarDependencies
        ),
        sidebarRootViewBuilder: sidebarRootViewBuilder
    )

    let result = try await withAsyncTestCoreAtoms(using: harness.atoms.core) { _ in
        harness.window.contentViewController = harness.controller
        _ = harness.controller.view
        harness.window.makeKeyAndOrderFront(nil)
        return try await body(harness)
    }

    harness.controller.shutdown()
    harness.window.contentViewController = nil
    harness.window.orderOut(nil)
    await Task.yield()
    await harness.coordinator.shutdown()
    try? FileManager.default.removeItem(at: harness.tempDir)
    return result
}

@MainActor
func withUnloadedMainSplitViewControllerHarness<T>(
    withRepos: Bool = true,
    inboxAtom: InboxNotificationAtom = InboxNotificationAtom(),
    commandDispatcher: AppCommandDispatcher? = nil,
    configureUIState: @escaping @MainActor (WorkspaceSidebarState) -> Void = { _ in },
    configureWorkspaceWindowMemory:
        @escaping @MainActor (WorkspaceWindowMemoryAtom) -> Void = { _ in },
    configureSidebarDependencies: @escaping @MainActor (SidebarRootViewDependencies) -> Void = { _ in },
    sidebarRootViewBuilder: @escaping MainSplitViewControllerTestSidebarBuilder = { uiState, onEscape in
        AnyView(MainSplitViewControllerTestSidebarView(uiState: uiState, onEscape: onEscape))
    },
    body: @MainActor (MainSplitViewControllerHarness) async throws -> T
) async rethrows -> T {
    let harness = makeMainSplitViewControllerHarness(
        withRepos: withRepos,
        inboxAtom: inboxAtom,
        paneTabRegistersAsCommandHandler: false,
        configuration: MainSplitViewControllerHarnessConfiguration(
            commandDispatcher: commandDispatcher,
            configureUIState: configureUIState,
            configureWorkspaceWindowMemory: configureWorkspaceWindowMemory,
            configureSidebarDependencies: configureSidebarDependencies
        ),
        sidebarRootViewBuilder: sidebarRootViewBuilder
    )

    let result = try await withAsyncTestCoreAtoms(using: harness.atoms.core) { _ in
        try await body(harness)
    }

    harness.controller.shutdown()
    await harness.coordinator.shutdown()
    try? FileManager.default.removeItem(at: harness.tempDir)
    return result
}

struct MainSplitViewControllerTestSidebarView: View {
    let uiState: WorkspaceSidebarState
    let onEscape: () -> Void

    var body: some View {
        Group {
            switch uiState.sidebarSurface {
            case .repos, .panes:
                MainSplitViewControllerTestRepoFocusableView(
                    uiState: uiState,
                    onEscape: onEscape
                )
            case .inbox:
                MainSplitViewControllerTestInboxView(
                    uiState: uiState,
                    onEscape: onEscape
                )
            }
        }
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainSplitViewControllerTestRepoFocusableView: NSViewRepresentable {
    let uiState: WorkspaceSidebarState
    let onEscape: () -> Void

    func makeCoordinator() -> RepoExplorerKeyboardInteraction {
        RepoExplorerKeyboardInteraction()
    }

    func makeNSView(context: Context) -> RepoExplorerMaterializationHost {
        let view = RepoExplorerMaterializationHost(
            lifetimeID: RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate()),
            initialDemandEpoch: 1,
            initialPresentation: .noRepositories,
            makeContentChild: { preconditionFailure("Shell focus fixture remains rowless") },
            onFeedback: { _ in }
        )
        view.identifier = RepoExplorerView.focusTargetIdentifier
        configure(context.coordinator)
        view.installKeyboardInteraction(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: RepoExplorerMaterializationHost, context: Context) {
        configure(context.coordinator)
    }

    static func dismantleNSView(
        _ nsView: RepoExplorerMaterializationHost,
        coordinator: RepoExplorerKeyboardInteraction
    ) {
        MainActor.assumeIsolated {
            nsView.detach()
        }
    }

    private func configure(_ interaction: RepoExplorerKeyboardInteraction) {
        interaction.configure(
            RepoExplorerKeyboardCallbacks(
                canInterpretListInput: { true },
                onReturnFocusRequest: onEscape,
                onSidebarFocusChange: { uiState.setSidebarHasFocus($0) }
            )
        )
    }
}

final class MainSplitViewControllerTestInboxFocusableView: NSView {
    var onFocusChange: @MainActor (Bool) -> Void = { _ in }
    var onEscape: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            onFocusChange(true)
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            onFocusChange(false)
        }
        return didResign
    }

    override func cancelOperation(_ sender: Any?) {
        _ = sender
        onEscape()
    }
}

struct MainSplitViewControllerTestInboxView: NSViewRepresentable {
    let uiState: WorkspaceSidebarState
    let onEscape: () -> Void

    func makeNSView(context: Context) -> MainSplitViewControllerTestInboxFocusableView {
        let view = MainSplitViewControllerTestInboxFocusableView()
        view.identifier = InboxNotificationSidebarView.focusTargetIdentifier
        view.onFocusChange = { uiState.setSidebarHasFocus($0) }
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: MainSplitViewControllerTestInboxFocusableView, context: Context) {
        nsView.onFocusChange = { uiState.setSidebarHasFocus($0) }
        nsView.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: MainSplitViewControllerTestInboxFocusableView, coordinator: ()) {
        MainActor.assumeIsolated {
            nsView.onFocusChange(false)
        }
    }
}

final class MainSplitViewControllerTestSurfaceManager: WorkspaceSurfaceManaging {
    private var bindings: [UUID: UUID] = [:]
    private var bindingsChangeHandler: (() -> Void)?

    func setAttachedBindingsChangeHandler(_ handler: (() -> Void)?) {
        bindingsChangeHandler = handler
    }

    func attachPreviewBinding(surfaceID: UUID, paneID: UUID) {
        bindings[surfaceID] = paneID
        bindingsChangeHandler?()
    }

    func reconcileAttachedVisibility(
        _ visibilityForPaneID: (UUID) -> Bool
    ) -> SurfaceVisibilityReconciliationResult {
        _ = bindings.mapValues(visibilityForPaneID)
        return SurfaceVisibilityReconciliationResult(applied: bindings.count, equal: 0, missing: 0)
    }
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {}
}
