import AgentStudioSessions
import AppKit
import Foundation

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioRepoExplorer

@MainActor
struct PaneTabCommandControllerComposition {
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let appLifecycleStore: AppLifecycleAtom
    let windowLifecycleStore: WindowLifecycleAtom
    let workspaceWindowId: UUID?
    let executor: WorkspaceActionExecutor
    let coordinator: WorkspaceSurfaceCoordinator
    let surfaceManager: MockPaneTabCommandSurfaceManager
    let viewRegistry: ViewRegistry
    let atomRegistry: AtomRegistry
    let sessionsPaneViewedMailbox: SessionsPaneViewedMailbox?
    let launchRecorder: PaneTabViewControllerCommandLaunchRecorder
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let tabRenamePopoverState: TabRenamePopoverState
    let arrangementInlineRenameState: ArrangementInlineRenameState
    let arrangementPanelPresentation: ArrangementPanelPresentationAtom
    let bridgeViewerSurfaceRequestHandler: (@MainActor (BridgeProductSurface, UUID) -> Bool)?
    let bridgeViewerOpenTelemetryAnchorFactory: @MainActor () -> BridgeViewerOpenTelemetryAnchor
    let interactionProbe: AgentStudioInteractionPerformanceProbe?
}

@MainActor
func makePaneTabCommandControllerBuilder(
    composition: PaneTabCommandControllerComposition
) -> @MainActor (AppCommandDispatcher) -> PaneTabViewController {
    { commandDispatcher in

        PaneTabViewController(
            store: composition.store,
            octiconLoader: makeTestOcticonLoader(),
            repoCache: composition.repoCache,
            applicationLifecycleMonitor: ApplicationLifecycleMonitor(
                appLifecycleStore: composition.appLifecycleStore,
                windowLifecycleStore: composition.windowLifecycleStore
            ),
            appLifecycleStore: composition.appLifecycleStore,
            windowLifecycleStore: composition.windowLifecycleStore,
            workspaceWindowId: composition.workspaceWindowId,
            executor: composition.executor,
            runtimeCommandDispatcher: composition.coordinator,
            commandDispatcher: commandDispatcher,
            synchronizeRuntimeFocus: composition.surfaceManager.syncFocus,
            tabBarAdapter: makeCommandHarnessTabBarAdapter(
                store: composition.store,
            ),
            viewRegistry: composition.viewRegistry,
            bridgePaneAttendance: composition.atomRegistry.bridgePaneAttendance,
            editorChooser: composition.atomRegistry.editorChooser,
            sessionsPaneViewedMailbox: composition.sessionsPaneViewedMailbox,
            paneInboxPresentation: nil,
            pinnedPanePreferences: RepoExplorerSidebarPrefsAtom(
                sidebarState: CoreAtomScope.store.workspaceSidebarState),
            installedEditorTargetsProvider: { [.cursor, .vscode] },
            openEditorHandler: { editorId, path, _ in
                composition.launchRecorder.openedEditors.append((id: editorId, path: path))
                return true
            },
            openFinderHandler: composition.launchRecorder.openFinder,
            openExternalURLHandler: composition.launchRecorder.openExternalURL,
            copyPathHandler: { path in
                composition.launchRecorder.copiedPaths.append(path)
            },
            paneNotePresentation: makeCommandHarnessPaneNotePresentation(
                launchRecorder: composition.launchRecorder
            ),
            closeTransitionCoordinator: composition.closeTransitionCoordinator,
            heldPanePreviewState: HeldPanePreviewState(),
            tabRenamePopoverState: composition.tabRenamePopoverState,
            arrangementInlineRenameState: composition.arrangementInlineRenameState,
            arrangementPanelPresentation: composition.arrangementPanelPresentation,
            bridgeViewerSurfaceRequestHandler: composition.bridgeViewerSurfaceRequestHandler,
            bridgeViewerOpenTelemetryAnchorFactory: composition.bridgeViewerOpenTelemetryAnchorFactory,
            interactionProbe: composition.interactionProbe,
            registersAsCommandHandler: false
        )

    }
}
