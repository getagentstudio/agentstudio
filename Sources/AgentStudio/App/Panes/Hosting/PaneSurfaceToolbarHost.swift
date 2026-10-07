import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AppKit
import SwiftUI

@MainActor
struct DrawerToolbarCommandPresentation {
    let toggleDrawer: TargetedCommandControlAction?
    let addDrawerPane: TargetedCommandControlAction?
    let pinPane: TargetedCommandControlAction?
    let editPaneNote: TargetedCommandControlAction?
    let openEditorMenu: TargetedCommandControlAction?
    let openFinder: TargetedCommandControlAction?
    let copyPath: TargetedCommandControlAction?
    let openPullRequest: TargetedCommandControlAction?
    let showPaneInbox: TargetedCommandControlAction?

    static func resolve(
        anchorPaneId: UUID,
        locationTargetPaneId: UUID,
        toolbarSurface: AppCommandToolbarSurface,
        actionResolver: TargetedCommandControlActionResolver,
        isOwnerPinned: Bool = false
    ) -> Self {
        let commandSurface = AppCommandSurface.toolbar(toolbarSurface)
        return Self(
            toggleDrawer: actionResolver(
                .toggleDrawer,
                commandSurface,
                anchorPaneId,
                .pane
            ),
            addDrawerPane: actionResolver(
                .addDrawerPane,
                commandSurface,
                anchorPaneId,
                .pane
            ),
            pinPane: actionResolver(
                isOwnerPinned ? .unpinPane : .pinPane, commandSurface, anchorPaneId, .pane
            ),
            editPaneNote: actionResolver(
                .editPaneNote,
                commandSurface,
                locationTargetPaneId,
                .pane
            ),
            openEditorMenu: actionResolver(
                .openPaneLocationInEditorMenu,
                commandSurface,
                locationTargetPaneId,
                .pane
            ),
            openFinder: actionResolver(
                .openPaneLocationInFinder,
                commandSurface,
                locationTargetPaneId,
                .pane
            ),
            copyPath: actionResolver(
                .copyCurrentPanePath,
                commandSurface,
                locationTargetPaneId,
                .pane
            ),
            openPullRequest: actionResolver(
                .openPullRequest,
                commandSurface,
                locationTargetPaneId,
                .pane
            ),
            showPaneInbox: actionResolver(
                .showPaneInboxNotifications,
                commandSurface,
                anchorPaneId,
                .pane
            )
        )
    }
}

@MainActor
struct PaneSurfaceToolbarHost: View {
    @Environment(\.paneContextUIReaders) private var paneContextReaders
    let anchorPaneId: UUID
    let locationTargetPaneId: UUID
    let toolbarSurface: AppCommandToolbarSurface
    let drawer: Drawer?
    let leadingToolbarActions: [PaneSurfaceToolbarAction]
    let contextToolbarActions: [PaneSurfaceToolbarAction]
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let octiconLoader: OcticonLoader
    let editorChooser: EditorChooserState
    let paneInboxPresentation: PaneInboxPresentation?
    let paneNotePresentation: PaneNotePresentation?
    let workspaceWindowId: UUID?
    let owningPaneSize: CGSize?
    let actionDispatcher: PaneActionDispatching
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let targetedCommandActionResolver: TargetedCommandControlActionResolver

    @State private var paneInboxPopoverOpen = false
    @State private var paneNotePopoverOpen = false
    @State private var presentedNotePaneId: UUID?

    @MainActor
    static func resolveTargetedCommandAction(
        command: AppCommand,
        surface: AppCommandSurface,
        target: UUID,
        targetType: SearchItemType
    ) -> TargetedCommandControlAction? {
        TargetedCommandControlAction.resolve(
            command: command,
            surface: surface,
            target: target,
            targetType: targetType,
            dispatcher: AppCommandDispatcher.shared
        )
    }

    init(
        anchorPaneId: UUID,
        locationTargetPaneId: UUID,
        toolbarSurface: AppCommandToolbarSurface,
        drawer: Drawer?,
        leadingToolbarActions: [PaneSurfaceToolbarAction],
        contextToolbarActions: [PaneSurfaceToolbarAction],
        store: WorkspaceStore,
        repoCache: RepoCacheAtom,
        octiconLoader: OcticonLoader,
        editorChooser: EditorChooserState,
        paneInboxPresentation: PaneInboxPresentation?,
        paneNotePresentation: PaneNotePresentation? = nil,
        workspaceWindowId: UUID?,
        owningPaneSize: CGSize? = nil,
        actionDispatcher: PaneActionDispatching,
        onPaneFocusTrigger: @escaping PaneFocusTriggerHandler,
        targetedCommandActionResolver: @escaping TargetedCommandControlActionResolver =
            Self.resolveTargetedCommandAction
    ) {
        self.anchorPaneId = anchorPaneId
        self.locationTargetPaneId = locationTargetPaneId
        self.toolbarSurface = toolbarSurface
        self.drawer = drawer
        self.leadingToolbarActions = leadingToolbarActions
        self.contextToolbarActions = contextToolbarActions
        self.store = store
        self.repoCache = repoCache
        self.octiconLoader = octiconLoader
        self.editorChooser = editorChooser
        self.paneInboxPresentation = paneInboxPresentation
        self.paneNotePresentation = paneNotePresentation
        self.workspaceWindowId = workspaceWindowId
        self.owningPaneSize = owningPaneSize
        self.actionDispatcher = actionDispatcher
        self.onPaneFocusTrigger = onPaneFocusTrigger
        self.targetedCommandActionResolver = targetedCommandActionResolver
    }

    var body: some View {
        let commandPresentation = DrawerToolbarCommandPresentation.resolve(
            anchorPaneId: anchorPaneId,
            locationTargetPaneId: locationTargetPaneId,
            toolbarSurface: toolbarSurface,
            actionResolver: targetedCommandActionResolver,
            isOwnerPinned: store.paneAtom.pane(anchorPaneId)?.metadata.isPinned ?? false
        )
        let locationTargetPath = store.paneAtom.graphAtom.paneStructuralFacts(locationTargetPaneId)?.cwd
        let pullRequestPresentation = PanePullRequestToolbarActionFactory.make(
            paneId: locationTargetPaneId,
            store: store,
            repoCache: repoCache,
            commandAction: commandPresentation.openPullRequest
        )
        let gitStatusPresentation = PaneGitStatusToolbarResolver.resolve(
            paneId: locationTargetPaneId,
            store: store,
            repoCache: repoCache
        )
        let noteTargetPaneId = presentedNotePaneId ?? locationTargetPaneId
        let paneNotePopoverContent = store.paneAtom.pane(noteTargetPaneId).map { pane in
            AnyView(
                PaneNotePopover(
                    currentNote: pane.metadata.note,
                    owningPaneSize: owningPaneSize,
                    onCommit: { note in
                        store.paneAtom.updatePaneNote(noteTargetPaneId, note: note)
                        paneNotePopoverOpen = false
                    },
                    onCancel: {
                        paneNotePopoverOpen = false
                    }
                )
                .transientKeyboardSurface(
                    .paneNote(paneId: noteTargetPaneId),
                    workspaceWindowId: workspaceWindowId,
                    onDismiss: {
                        paneNotePopoverOpen = false
                    }
                )
                .tint(AppStyles.General.Accent.primaryColor)
            )
        }
        let trailingActions = DrawerEditorChooserFactory.makeTrailingActions(
            editorChooser: editorChooser,
            paneId: locationTargetPaneId,
            workspaceWindowId: workspaceWindowId,
            commandPresentation: commandPresentation,
            notePopoverPresented: $paneNotePopoverOpen,
            notePopoverContent: paneNotePopoverContent,
            refreshInstalledTargets: {
                ExternalEditorTarget.refreshInstalledTargets()
            },
            onOpenEditor: { editorId in
                guard let targetPath = locationTargetPath else { return }
                _ = ExternalWorkspaceOpener.openInEditor(id: editorId, path: targetPath)
            },
            gitStatusPresentation: gitStatusPresentation,
            pullRequestBlockerIndicator: pullRequestPresentation?.blockerIndicator,
            openPullRequestAction: pullRequestPresentation?.openAction
        )
        let paneInboxScope = PaneInboxScopeResolver.resolve(
            anchorPaneId: anchorPaneId,
            pane: { store.paneAtom.pane($0) }
        )
        let hostedActions =
            paneInboxPresentation?.trailingActions(
                parentPaneId: paneInboxScope.parentPaneId,
                paneIds: paneInboxScope.paneIds,
                baseTrailingActions: trailingActions,
                showPaneInboxAction: commandPresentation.showPaneInbox,
                inboxPopoverPresented: $paneInboxPopoverOpen
            ) ?? trailingActions

        DrawerOverlay(
            octiconLoader: octiconLoader,
            drawer: drawer,
            isIconBarVisible: true,
            toggleDrawerAction: commandPresentation.toggleDrawer,
            addDrawerPaneAction: commandPresentation.addDrawerPane,
            pinPaneAction: commandPresentation.pinPane,
            trailingActions: hostedActions.withPaneContextContent(paneContextContent),
            paneSurfaceActions: leadingToolbarActions,
            paneContextActions: contextToolbarActions
        )
        .onAppear {
            consumePendingPaneInboxRequest(in: paneInboxScope)
        }
        .onChange(of: paneInboxPresentation?.pendingRequest()?.id) { _, _ in
            consumePendingPaneInboxRequest(in: paneInboxScope)
        }
        .onChange(of: paneInboxPopoverOpen) { _, isPresented in
            paneInboxPresentation?.setPresented(
                paneInboxScope.parentPaneId,
                paneInboxScope.paneIds,
                isPresented
            )
        }
        .onChange(of: paneNotePopoverOpen) { _, isPresented in
            if !isPresented { presentedNotePaneId = nil }
        }
        .onAppear {
            consumePendingPaneNoteRequest()
        }
        .onChange(of: paneNotePresentation?.pendingRequest()?.id) { _, _ in
            consumePendingPaneNoteRequest()
        }
    }

    private var paneContextContent: AnyView? {
        guard let paneContextReaders else { return nil }
        return AnyView(
            PaneContextToolbarControls(
                paneId: PaneId(existingUUID: anchorPaneId), readers: paneContextReaders, octiconLoader: octiconLoader,
                onGoToPane: { AppCommandDispatcher.shared.dispatch(.focusPane, target: $0, targetType: .pane) }))
    }

    private func consumePendingPaneInboxRequest(in scope: PaneInboxScope) {
        guard let request = paneInboxPresentation?.pendingRequest() else { return }
        guard request.matches(parentPaneId: scope.parentPaneId, paneIds: scope.paneIds) else { return }

        switch request.intent {
        case .open:
            paneInboxPopoverOpen = true
            paneInboxPresentation?.setPresented(scope.parentPaneId, scope.paneIds, true)
        case .close:
            paneInboxPopoverOpen = false
            paneInboxPresentation?.setPresented(scope.parentPaneId, scope.paneIds, false)
        }
        paneInboxPresentation?.clearRequest(request)
    }

    private func consumePendingPaneNoteRequest() {
        guard let request = paneNotePresentation?.pendingRequest() else { return }
        guard
            request.paneId == anchorPaneId
                || store.paneAtom.pane(request.paneId)?.parentPaneId == anchorPaneId
        else { return }
        presentedNotePaneId = request.paneId
        paneNotePopoverOpen = true
        paneNotePresentation?.clearRequest(request)
    }

}
