@MainActor
package final class CoreAtoms {
    package let activeWorkspaceSelection: ActiveWorkspaceSelectionAtom
    package let workspaceIdentity: WorkspaceIdentityAtom
    package let workspaceWindowMemory: WorkspaceWindowMemoryAtom
    package let workspaceRepositoryTopology: RepositoryTopologyAtom
    package let workspacePaneGraph: WorkspacePaneGraphAtom
    package let workspaceDrawerCursor: WorkspaceDrawerCursorAtom
    package let workspacePane: WorkspacePaneAtom
    package let workspaceTabCursor: WorkspaceTabCursorAtom
    package let workspaceTabShell: WorkspaceTabShellAtom
    package let workspaceTabGraph: WorkspaceTabGraphAtom
    package let workspaceArrangementCursor: WorkspaceArrangementCursorAtom
    package let workspacePanePresentation: WorkspacePanePresentationAtom
    package let workspaceTabArrangement: WorkspaceTabArrangementAtom
    package let workspaceTabLayout: WorkspaceTabLayoutAtom
    package let workspaceMutationCoordinator: WorkspaceMutationCoordinator
    package let windowLifecycle: WindowLifecycleAtom
    package let repoEnrichmentCache: RepoEnrichmentCacheAtom
    package let applicationEntityRecency: ApplicationEntityRecencyAtom
    package let repositoryLocalActivity: RepositoryLocalActivityAtom
    package let workspaceEntityRecency: WorkspaceEntityRecencyAtom
    package let repoCache: RepoCacheAtom
    package let sidebarCollapsedGroup: SidebarCollapsedGroupAtom
    package let sidebarCache: SidebarCacheState
    package let arrangementPanelPresentation: ArrangementPanelPresentationAtom
    package let workspaceSidebarMemory: WorkspaceSidebarMemoryAtom
    package let sidebarFocusRuntime: SidebarFocusRuntimeAtom
    package let sidebarVisibleWorktreesRuntime: SidebarVisibleWorktreesRuntimeAtom
    package let workspaceSidebarState: WorkspaceSidebarState
    package let managementLayer: ManagementLayerAtom
    package let commandBarSurface: CommandBarSurfaceAtom
    package let transientKeyboardSurface: TransientKeyboardSurfaceAtom
    package let workspaceFocusOwner: WorkspaceFocusOwnerAtom
    package let sessionRuntime: SessionRuntimeAtom
    package let paneActivityStatus: PaneActivityStatusAtom
    package let paneActivityTime: PaneActivityTimeAtom
    package let paneContextPresentation: PaneContextPresentationAtom
    package let welcome: WelcomeAtom

    package init(
        activeWorkspaceSelection: ActiveWorkspaceSelectionAtom = .init(),
        workspaceIdentity: WorkspaceIdentityAtom = .init(installationState: .awaitingCanonicalComposition),
        workspaceWindowMemory: WorkspaceWindowMemoryAtom = .init(),
        workspaceRepositoryTopology: RepositoryTopologyAtom = .init(),
        workspacePaneGraph: WorkspacePaneGraphAtom? = nil,
        workspaceDrawerCursor: WorkspaceDrawerCursorAtom? = nil,
        workspacePane: WorkspacePaneAtom? = nil,
        workspaceTabCursor: WorkspaceTabCursorAtom? = nil,
        workspaceTabShell: WorkspaceTabShellAtom? = nil,
        workspaceTabGraph: WorkspaceTabGraphAtom? = nil,
        workspaceArrangementCursor: WorkspaceArrangementCursorAtom? = nil,
        workspacePanePresentation: WorkspacePanePresentationAtom? = nil,
        workspaceTabArrangement: WorkspaceTabArrangementAtom? = nil,
        workspaceMutationCoordinator: WorkspaceMutationCoordinator? = nil,
        windowLifecycle: WindowLifecycleAtom = .init(),
        repoEnrichmentCache: RepoEnrichmentCacheAtom = .init(),
        applicationEntityRecency: ApplicationEntityRecencyAtom = .init(),
        repositoryLocalActivity: RepositoryLocalActivityAtom = .init(),
        workspaceEntityRecency: WorkspaceEntityRecencyAtom = .init(),
        sidebarCollapsedGroup: SidebarCollapsedGroupAtom = .init(),
        arrangementPanelPresentation: ArrangementPanelPresentationAtom = .init(),
        workspaceSidebarMemory: WorkspaceSidebarMemoryAtom = .init(),
        sidebarFocusRuntime: SidebarFocusRuntimeAtom = .init(),
        sidebarVisibleWorktreesRuntime: SidebarVisibleWorktreesRuntimeAtom = .init(),
        managementLayer: ManagementLayerAtom = .init(),
        commandBarSurface: CommandBarSurfaceAtom = .init(),
        transientKeyboardSurface: TransientKeyboardSurfaceAtom = .init(),
        workspaceFocusOwner: WorkspaceFocusOwnerAtom = .init(),
        sessionRuntime: SessionRuntimeAtom = .init(),
        paneActivityStatus: PaneActivityStatusAtom = .init(),
        paneActivityTime: PaneActivityTimeAtom = .init(),
        paneContextPresentation: PaneContextPresentationAtom = .init(),
        welcome: WelcomeAtom = .init()
    ) {
        self.activeWorkspaceSelection = activeWorkspaceSelection
        self.workspaceIdentity = workspaceIdentity
        self.workspaceWindowMemory = workspaceWindowMemory
        self.workspaceRepositoryTopology = workspaceRepositoryTopology

        let resolvedWorkspacePane = Self.resolveWorkspacePane(
            workspacePane: workspacePane,
            graphAtom: workspacePaneGraph,
            drawerCursorAtom: workspaceDrawerCursor,
            repositoryTopologyAtom: workspaceRepositoryTopology,
            repoEnrichmentCacheAtom: repoEnrichmentCache
        )
        self.workspacePane = resolvedWorkspacePane
        self.workspacePaneGraph = resolvedWorkspacePane.graphAtom
        self.workspaceDrawerCursor = resolvedWorkspacePane.drawerCursorAtom

        let resolvedWorkspaceTabShell = Self.resolveWorkspaceTabShell(
            workspaceTabShell: workspaceTabShell,
            cursorAtom: workspaceTabCursor
        )
        self.workspaceTabShell = resolvedWorkspaceTabShell
        self.workspaceTabCursor = resolvedWorkspaceTabShell.cursorAtom

        let resolvedWorkspaceTabArrangement = Self.resolveWorkspaceTabArrangement(
            workspaceTabArrangement: workspaceTabArrangement,
            graphAtom: workspaceTabGraph,
            cursorAtom: workspaceArrangementCursor,
            presentationAtom: workspacePanePresentation
        )
        self.workspaceTabArrangement = resolvedWorkspaceTabArrangement
        self.workspaceTabGraph = resolvedWorkspaceTabArrangement.graphAtom
        self.workspaceArrangementCursor = resolvedWorkspaceTabArrangement.cursorAtom
        self.workspacePanePresentation = resolvedWorkspaceTabArrangement.presentationAtom
        self.workspaceTabLayout = WorkspaceTabLayoutAtom(
            shellAtom: self.workspaceTabShell,
            arrangementAtom: self.workspaceTabArrangement
        )
        self.workspaceMutationCoordinator =
            workspaceMutationCoordinator
            ?? WorkspaceMutationCoordinator(
                repositoryTopologyAtom: workspaceRepositoryTopology,
                workspacePaneAtom: self.workspacePane,
                workspaceTabShellAtom: self.workspaceTabShell,
                workspaceTabArrangementAtom: self.workspaceTabArrangement
            )
        self.windowLifecycle = windowLifecycle
        self.repoEnrichmentCache = repoEnrichmentCache
        self.applicationEntityRecency = applicationEntityRecency
        self.repositoryLocalActivity = repositoryLocalActivity
        self.workspaceEntityRecency = workspaceEntityRecency
        self.repoCache = RepoCacheAtom(enrichmentCacheAtom: repoEnrichmentCache)
        self.sidebarCollapsedGroup = sidebarCollapsedGroup
        self.sidebarCache = SidebarCacheState(
            collapsedGroupAtom: sidebarCollapsedGroup
        )
        self.arrangementPanelPresentation = arrangementPanelPresentation
        self.workspaceSidebarMemory = workspaceSidebarMemory
        self.sidebarFocusRuntime = sidebarFocusRuntime
        self.sidebarVisibleWorktreesRuntime = sidebarVisibleWorktreesRuntime
        self.workspaceSidebarState = WorkspaceSidebarState(
            memoryAtom: workspaceSidebarMemory,
            focusAtom: sidebarFocusRuntime
        )
        self.managementLayer = managementLayer
        self.commandBarSurface = commandBarSurface
        self.transientKeyboardSurface = transientKeyboardSurface
        self.workspaceFocusOwner = workspaceFocusOwner
        self.sessionRuntime = sessionRuntime
        self.paneActivityStatus = paneActivityStatus
        self.paneActivityTime = paneActivityTime
        self.paneContextPresentation = paneContextPresentation
        self.welcome = welcome
    }

    private static func resolveWorkspacePane(
        workspacePane: WorkspacePaneAtom?,
        graphAtom: WorkspacePaneGraphAtom?,
        drawerCursorAtom: WorkspaceDrawerCursorAtom?,
        repositoryTopologyAtom: RepositoryTopologyAtom,
        repoEnrichmentCacheAtom: RepoEnrichmentCacheAtom
    ) -> WorkspacePaneAtom {
        let resolved =
            workspacePane
            ?? WorkspacePaneAtom(
                graphAtom: graphAtom ?? WorkspacePaneGraphAtom(),
                drawerCursorAtom: drawerCursorAtom ?? WorkspaceDrawerCursorAtom(),
                repositoryTopologyAtom: repositoryTopologyAtom,
                repoEnrichmentCacheAtom: repoEnrichmentCacheAtom
            )
        if let graphAtom {
            precondition(
                resolved.graphAtom === graphAtom,
                "workspacePane and workspacePaneGraph must reference the same backing owner"
            )
        }
        if let drawerCursorAtom {
            precondition(
                resolved.drawerCursorAtom === drawerCursorAtom,
                "workspacePane and workspaceDrawerCursor must reference the same backing owner"
            )
        }
        return resolved
    }

    private static func resolveWorkspaceTabShell(
        workspaceTabShell: WorkspaceTabShellAtom?,
        cursorAtom: WorkspaceTabCursorAtom?
    ) -> WorkspaceTabShellAtom {
        let resolved = workspaceTabShell ?? WorkspaceTabShellAtom(cursorAtom: cursorAtom ?? WorkspaceTabCursorAtom())
        if let cursorAtom {
            precondition(
                resolved.cursorAtom === cursorAtom,
                "workspaceTabShell and workspaceTabCursor must reference the same backing owner"
            )
        }
        return resolved
    }

    private static func resolveWorkspaceTabArrangement(
        workspaceTabArrangement: WorkspaceTabArrangementAtom?,
        graphAtom: WorkspaceTabGraphAtom?,
        cursorAtom: WorkspaceArrangementCursorAtom?,
        presentationAtom: WorkspacePanePresentationAtom?
    ) -> WorkspaceTabArrangementAtom {
        let resolved =
            workspaceTabArrangement
            ?? WorkspaceTabArrangementAtom(
                graphAtom: graphAtom ?? WorkspaceTabGraphAtom(),
                cursorAtom: cursorAtom ?? WorkspaceArrangementCursorAtom(),
                presentationAtom: presentationAtom ?? WorkspacePanePresentationAtom()
            )
        if let graphAtom {
            precondition(
                resolved.graphAtom === graphAtom,
                "workspaceTabArrangement and workspaceTabGraph must reference the same backing owner"
            )
        }
        if let cursorAtom {
            precondition(
                resolved.cursorAtom === cursorAtom,
                "workspaceTabArrangement and workspaceArrangementCursor must reference the same backing owner"
            )
        }
        if let presentationAtom {
            precondition(
                resolved.presentationAtom === presentationAtom,
                "workspaceTabArrangement and workspacePanePresentation must reference the same backing owner"
            )
        }
        return resolved
    }

    package var paneDisplay: PaneDisplayDerived {
        PaneDisplayDerived()
    }

    package var workspacePaneDerived: WorkspacePaneDerived {
        WorkspacePaneDerived(
            graphAtom: workspacePaneGraph,
            drawerCursorAtom: workspaceDrawerCursor,
            repositoryTopologyAtom: workspaceRepositoryTopology,
            repoEnrichmentCacheAtom: repoEnrichmentCache
        )
    }

    package var workspaceLookup: WorkspaceLookupDerived {
        WorkspaceLookupDerived()
    }

    package var workspaceFocusedPane: WorkspaceFocusedPaneResolver {
        WorkspaceFocusedPaneResolver()
    }

    package var commandContext: CommandContextDerived {
        CommandContextDerived()
    }

    package private(set) lazy var attendedPane = AttendedPaneDerived(
        tabLayout: workspaceTabLayout,
        windowLifecycle: windowLifecycle,
        managementLayer: managementLayer
    )

    package var tabDisplay: TabDisplayDerived {
        TabDisplayDerived()
    }

    package var arrangement: ArrangementDerived {
        ArrangementDerived()
    }

    package var arrangementView: WorkspaceArrangementViewDerived {
        WorkspaceArrangementViewDerived(
            tabLayoutAtom: workspaceTabLayout,
            paneAtom: workspacePane,
            managementLayerAtom: managementLayer
        )
    }

    package var workspaceTab: WorkspaceTabLayoutDerived {
        WorkspaceTabLayoutDerived(
            shellAtom: workspaceTabShell,
            arrangementAtom: workspaceTabArrangement
        )
    }

    package var dynamicView: DynamicViewDerived {
        DynamicViewDerived()
    }
}
