import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

struct AppCommandIPCSpec: Sendable {
    let exposure: IPCMethodExposure
    let executionMode: IPCCommandExecutionMode
    let argumentVariants: [IPCCommandArgumentVariant]
    let requiredPrivilege: IPCPrivilegeClass
    let allowedTargetKinds: Set<IPCHandleKind>
    let resultVariants: [IPCCommandResultVariant]
    let agentEligibility: IPCAgentEligibility

    func descriptorInput(
        definition: AppCommandSpec,
        examples: [IPCCommandExample]
    ) -> IPCCommandDescriptorInput {
        IPCCommandDescriptorInput(
            id: IPCCommandIdentifier(rawValue: definition.command.rawValue),
            title: definition.label,
            description: definition.helpText,
            exposure: exposure,
            executionMode: executionMode,
            argumentVariants: argumentVariants,
            requiredPrivileges: [.appCommandExecute, requiredPrivilege],
            dataScope: Self.dataScope(for: requiredPrivilege),
            allowedTargetKinds: allowedTargetKinds,
            resultVariants: resultVariants,
            examples: examples,
            agentEligibility: agentEligibility
        )
    }

    private static func dataScope(for privilege: IPCPrivilegeClass) -> IPCDataScope {
        switch privilege {
        case .systemRead, .workspaceRead, .appCommandExecute, .debugUnsafe:
            .unspecified
        case .paneContextRead, .layoutMutate:
            .paneContext
        case .bridgeRead, .bridgeControl:
            .bridgeReviewPackage
        case .bridgeContentRead:
            .bridgeContent
        case .bridgeTelemetryRead, .bridgeTelemetryFlush:
            .bridgeTelemetry
        case .uiPresent:
            .uiSurface
        case .terminalRead, .terminalSnapshotRead:
            .terminalSnapshot
        case .terminalWrite, .terminalInputWrite:
            .terminalInput
        case .terminalStatusRead:
            .terminalStatus
        case .terminalWait:
            .terminalWait
        case .eventsRead, .permissionRequest, .permissionRead, .grantApprove:
            .permissionState
        case .sidebarStateMutate:
            .sidebarState
        case .sessionReportWrite:
            .sessionReport
        case .sessionStateRead:
            .sessionState
        }
    }
}

extension AppCommand {
    private var ipcArgumentVariants: [IPCCommandArgumentVariant] {
        switch self {
        case .newWindow,
            .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
            .setInboxGroupingNone, .setInboxRowStateFilter, .setInboxContentMode,
            .focusSidebar, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree:
            // Worktree creation has no parameterized IPC contract yet (v1 is interactive only).
            [.noArguments]

        case .undoCloseTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .toggleManagementLayer, .managementLayerExit,
            .toggleSidebar, .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .closeWindow,
            .showCommandBarEverything, .showCommandBarQuickOpen,
            .showCommandBarCommands, .showCommandBarPanes, .showCommandBarRepos,
            .filterSidebar, .signInGitHub, .signInGoogle:
            [.workspaceWindow]

        case .closeTab, .breakUpTab, .equalizePanes, .newTerminalInTab, .selectTab,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .previousArrangement, .nextArrangement, .cycleArrangement:
            [.tab]

        case .renameTab:
            [.renamedTab]
        case .newTab:
            [.newTab]
        case .nextTab, .prevTab:
            [.tabAnchor]

        case .closePane, .extractPaneToTab, .splitRight, .splitLeft,
            .minimizePane, .expandPane, .focusPane, .zoomPane,
            .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown,
            .focusPreviousPinnedPane, .focusNextPinnedPane,
            .jumpToPreviousPrompt, .jumpToNextPrompt,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .editPaneNote, .copyCurrentPanePath,
            .openPullRequest, .reloadBridgeWebView, .showViewer:
            [.pane]

        case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane:
            [.sourcePane]
        case .movePaneToTab:
            [.movePaneToTab]
        case .switchArrangement, .deleteArrangement:
            [.arrangement]
        case .saveArrangement:
            [.newArrangement]
        case .renameArrangement:
            [.renamedArrangement]

        case .enterDrawer,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3,
            .focusDrawerPane4, .focusDrawerPane5, .focusDrawerPane6,
            .focusDrawerPane7, .focusDrawerPane8, .focusDrawerPane9,
            .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge:
            [.drawerParent]
        case .focusDrawerPaneUp, .focusDrawerPaneLeft,
            .focusDrawerPaneDown, .focusDrawerPaneRight:
            [.drawerSourcePane]
        case .navigateDrawerPane, .closeDrawerPane:
            [.drawerPane]
        case .detachDrawerPane:
            [.detachedDrawerPane]

        case .watchFolder:
            [.directory]
        case .updateRepositoryFacts, .removeRepo, .pinRepo, .unpinRepo:
            [.repository]
        case .pinPane, .unpinPane:
            [.standalonePane]
        case .openWorktree,
            .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab:
            [.worktree]
        case .openWorktreeInPane:
            [.worktreeInPane]
        case .openNewTerminalInTab:
            [.terminalFromWorktree, .terminalFromPane]

        case .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal,
            .managementLayerCreateBrowser:
            [.managementFromMainPane, .managementFromDrawerPane]

        case .newFloatingTerminal:
            [.floatingTerminal]
        case .openWebview:
            [.webview]
        }
    }
    private var ipcExposure: IPCMethodExposure {
        switch self {
        case .focusSidebar:
            .allChannels
        // Own-pane commands reach pane agents on every channel.
        case .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .closeDrawerPane:
            .allChannels
        case .zoomPane, .reloadBridgeWebView,
            .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .toggleReposSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned,
            .pinRepo, .unpinRepo, .pinPane, .unpinPane:
            .allChannels

        case .closeTab, .breakUpTab, .renameTab, .newTerminalInTab, .newTab,
            .undoCloseTab, .selectTab, .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .extractPaneToTab, .movePaneToTab, .focusPane,
            .splitRight, .splitLeft, .equalizePanes,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .minimizePane, .expandPane,
            .switchArrangement, .previousArrangement, .nextArrangement,
            .cycleArrangement, .saveArrangement, .deleteArrangement,
            .renameArrangement, .enterDrawer,
            .focusDrawerPaneUp, .focusDrawerPaneLeft,
            .focusDrawerPaneDown, .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3,
            .focusDrawerPane4, .focusDrawerPane5, .focusDrawerPane6,
            .focusDrawerPane7, .focusDrawerPane8, .focusDrawerPane9,
            .detachDrawerPane, .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .editPaneNote, .copyCurrentPanePath,
            .openPullRequest, .watchFolder, .updateRepositoryFacts, .removeRepo,
            .openWorktree, .openWorktreeInPane,
            .toggleManagementLayer, .managementLayerFocusLeft,
            .managementLayerFocusRight, .managementLayerEnterDrawer,
            .managementLayerExitDrawer, .managementLayerOpenDrawer,
            .managementLayerCreateTerminal, .managementLayerCreateBrowser,
            .managementLayerExit, .toggleSidebar,
            .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
            .setInboxGroupingNone, .setInboxRowStateFilter, .setInboxContentMode,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .togglePanesSortDirection,
            .togglePanesShowsDrawers,
            .newFloatingTerminal, .newWindow, .closeWindow,
            .showCommandBarEverything, .showCommandBarQuickOpen,
            .showCommandBarCommands, .showCommandBarPanes, .showCommandBarRepos,
            .openWebview, .showViewer,
            .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab,
            .signInGitHub, .signInGoogle, .filterSidebar,
            .openNewTerminalInTab, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree:
            .debugTesting
        }
    }
    private var ipcExecutionMode: IPCCommandExecutionMode {
        switch self {
        case .focusSidebar:
            .uiPresentation
        case .openPaneLocationInEditorMenu, .editPaneNote,
            .showCommandBarEverything, .showCommandBarQuickOpen,
            .showCommandBarCommands, .showCommandBarPanes, .showCommandBarRepos,
            .signInGitHub, .signInGoogle, .filterSidebar:
            .uiPresentation

        case .closeTab, .breakUpTab, .renameTab, .newTerminalInTab, .newTab,
            .undoCloseTab, .selectTab, .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .extractPaneToTab, .movePaneToTab, .focusPane,
            .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown, .jumpToPreviousPrompt, .jumpToNextPrompt,
            .splitRight, .splitLeft, .equalizePanes,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .zoomPane, .minimizePane, .expandPane,
            .switchArrangement, .previousArrangement, .nextArrangement,
            .cycleArrangement, .saveArrangement, .deleteArrangement,
            .renameArrangement, .enterDrawer,
            .focusDrawerPaneUp, .focusDrawerPaneLeft,
            .focusDrawerPaneDown, .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3,
            .focusDrawerPane4, .focusDrawerPane5, .focusDrawerPane6,
            .focusDrawerPane7, .focusDrawerPane8, .focusDrawerPane9,
            .detachDrawerPane, .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .copyCurrentPanePath, .openPullRequest,
            .watchFolder, .updateRepositoryFacts, .removeRepo,
            .pinRepo, .unpinRepo, .pinPane, .unpinPane,
            .openWorktree, .openWorktreeInPane,
            .toggleManagementLayer, .managementLayerFocusLeft,
            .managementLayerFocusRight, .managementLayerEnterDrawer,
            .managementLayerExitDrawer, .managementLayerOpenDrawer,
            .managementLayerCreateTerminal, .managementLayerCreateBrowser,
            .managementLayerExit, .toggleSidebar,
            .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
            .setInboxGroupingNone, .setInboxRowStateFilter, .setInboxContentMode,
            .newFloatingTerminal, .newWindow, .closeWindow,
            .openWebview, .reloadBridgeWebView, .showViewer,
            .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab,
            .openNewTerminalInTab, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree:
            .headless
        }
    }
    private var ipcRequiredPrivilege: IPCPrivilegeClass {
        switch self {
        case .focusSidebar:
            .uiPresent
        case .showCommandBarEverything, .showCommandBarCommands,
            .showCommandBarPanes, .showCommandBarRepos:
            .uiPresent

        case .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown,
            .focusPreviousPinnedPane, .focusNextPinnedPane,
            .jumpToPreviousPrompt, .jumpToNextPrompt:
            .terminalInputWrite

        case .showInboxNotifications, .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .setInboxGroupingTab, .setInboxGroupingRepo,
            .setInboxGroupingPane, .setInboxGroupingNone,
            .setInboxRowStateFilter, .setInboxContentMode,
            .pinRepo, .unpinRepo, .pinPane, .unpinPane:
            .sidebarStateMutate

        case .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .copyCurrentPanePath, .openPullRequest,
            .reloadBridgeWebView, .showCommandBarQuickOpen,
            .signInGitHub, .signInGoogle, .filterSidebar:
            .workspaceRead

        case .closeTab, .breakUpTab, .renameTab, .newTerminalInTab, .newTab,
            .undoCloseTab, .selectTab, .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .extractPaneToTab, .movePaneToTab, .focusPane,
            .splitRight, .splitLeft, .equalizePanes,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .zoomPane, .minimizePane, .expandPane,
            .switchArrangement, .previousArrangement, .nextArrangement,
            .cycleArrangement, .saveArrangement, .deleteArrangement,
            .renameArrangement, .enterDrawer,
            .focusDrawerPaneUp, .focusDrawerPaneLeft,
            .focusDrawerPaneDown, .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3,
            .focusDrawerPane4, .focusDrawerPane5, .focusDrawerPane6,
            .focusDrawerPane7, .focusDrawerPane8, .focusDrawerPane9,
            .detachDrawerPane, .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane, .editPaneNote,
            .watchFolder, .updateRepositoryFacts, .removeRepo,
            .openWorktree, .openWorktreeInPane,
            .toggleManagementLayer, .managementLayerFocusLeft,
            .managementLayerFocusRight, .managementLayerEnterDrawer,
            .managementLayerExitDrawer, .managementLayerOpenDrawer,
            .managementLayerCreateTerminal, .managementLayerCreateBrowser,
            .managementLayerExit, .toggleSidebar,
            .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .newFloatingTerminal, .newWindow, .closeWindow,
            .openWebview, .showViewer,
            .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab,
            .openNewTerminalInTab, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree:
            .layoutMutate
        }
    }
    private var ipcAllowedTargetKinds: Set<IPCHandleKind> {
        switch self {
        case .focusSidebar:
            []
        case .newWindow,
            .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
            .setInboxGroupingNone, .setInboxRowStateFilter, .setInboxContentMode,
            .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree:
            []

        case .undoCloseTab, .newTab,
            .toggleManagementLayer, .managementLayerExit,
            .toggleSidebar, .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .closeWindow,
            .showCommandBarEverything, .showCommandBarQuickOpen,
            .showCommandBarCommands, .showCommandBarPanes, .showCommandBarRepos,
            .filterSidebar, .signInGitHub, .signInGoogle,
            .watchFolder, .openWorktree,
            .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab,
            .newFloatingTerminal, .openWebview:
            [.window]

        case .closeTab, .breakUpTab, .equalizePanes, .newTerminalInTab, .selectTab,
            .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .switchArrangement, .previousArrangement, .nextArrangement,
            .cycleArrangement, .saveArrangement, .deleteArrangement,
            .renameArrangement, .renameTab:
            [.window, .tab]

        case .closePane, .extractPaneToTab, .focusPane,
            .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown, .jumpToPreviousPrompt, .jumpToNextPrompt,
            .splitRight, .splitLeft, .minimizePane, .expandPane, .zoomPane,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane,
            .enterDrawer,
            .focusDrawerPaneUp, .focusDrawerPaneLeft,
            .focusDrawerPaneDown, .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3,
            .focusDrawerPane4, .focusDrawerPane5, .focusDrawerPane6,
            .focusDrawerPane7, .focusDrawerPane8, .focusDrawerPane9,
            .detachDrawerPane, .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .editPaneNote, .copyCurrentPanePath,
            .openPullRequest, .reloadBridgeWebView, .showViewer,
            .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal,
            .managementLayerCreateBrowser, .openWorktreeInPane,
            .openNewTerminalInTab:
            [.window, .pane]

        case .movePaneToTab:
            [.window, .tab, .pane]
        case .updateRepositoryFacts, .removeRepo, .pinRepo, .unpinRepo:
            [.repo]
        case .pinPane, .unpinPane:
            [.pane]
        }
    }
    private var ipcResultVariants: [IPCCommandResultVariant] {
        switch self {
        case .focusSidebar:
            [.presented]
        case .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
            .setInboxGroupingNone, .setInboxRowStateFilter, .setInboxContentMode,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .togglePanesSortDirection, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree:
            [.unavailable]

        case .openPaneLocationInEditorMenu, .editPaneNote,
            .showCommandBarEverything, .showCommandBarQuickOpen,
            .showCommandBarCommands, .showCommandBarPanes, .showCommandBarRepos,
            .signInGitHub, .signInGoogle, .filterSidebar:
            [.presented]

        case .watchFolder, .updateRepositoryFacts, .reloadBridgeWebView,
            .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab:
            [.accepted]

        case .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown, .jumpToPreviousPrompt, .jumpToNextPrompt,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .previousArrangement, .nextArrangement, .cycleArrangement,
            .deleteArrangement,
            .focusDrawerPaneUp, .focusDrawerPaneLeft,
            .focusDrawerPaneDown, .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3,
            .focusDrawerPane4, .focusDrawerPane5, .focusDrawerPane6,
            .focusDrawerPane7, .focusDrawerPane8, .focusDrawerPane9,
            .openPaneLocationInBookmarkedEditor,
            .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal,
            .managementLayerCreateBrowser, .showViewer:
            [.applied, .unavailable]

        case .closeTab, .breakUpTab, .renameTab, .newTerminalInTab, .newTab,
            .undoCloseTab, .selectTab, .nextTab, .prevTab,
            .closePane, .extractPaneToTab, .movePaneToTab, .focusPane,
            .splitRight, .splitLeft, .equalizePanes,
            .zoomPane, .minimizePane, .expandPane,
            .switchArrangement, .saveArrangement, .renameArrangement,
            .enterDrawer, .detachDrawerPane, .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal,
            .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .openPaneLocationInFinder, .copyCurrentPanePath, .openPullRequest,
            .removeRepo, .pinRepo, .unpinRepo, .pinPane, .unpinPane,
            .openWorktree, .openWorktreeInPane,
            .toggleManagementLayer, .managementLayerExit,
            .toggleSidebar, .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .toggleReposSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .newFloatingTerminal, .newWindow, .closeWindow,
            .openWebview, .openNewTerminalInTab:
            [.applied]
        }
    }
    /// A1 own-pane set: the pane agent's own terminal navigation and closing
    /// its own drawer child. Every other command is not yet allowed.
    private var ipcAgentEligibility: IPCAgentEligibility {
        switch self {
        case .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .closeDrawerPane:
            .ownPane
        case .newWindow, .closeWindow, .undoCloseTab, .newTab, .closeTab, .breakUpTab,
            .renameTab, .newTerminalInTab, .selectTab, .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .extractPaneToTab, .movePaneToTab, .splitRight, .splitLeft,
            .equalizePanes, .minimizePane, .expandPane, .focusPane, .zoomPane,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .switchArrangement, .previousArrangement, .nextArrangement, .cycleArrangement,
            .saveArrangement, .deleteArrangement, .renameArrangement,
            .enterDrawer, .focusDrawerPaneUp, .focusDrawerPaneLeft,
            .focusDrawerPaneDown, .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3,
            .focusDrawerPane4, .focusDrawerPane5, .focusDrawerPane6,
            .focusDrawerPane7, .focusDrawerPane8, .focusDrawerPane9,
            .detachDrawerPane, .addDrawerPane, .toggleDrawer,
            .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge, .navigateDrawerPane,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .editPaneNote, .copyCurrentPanePath,
            .openPullRequest, .reloadBridgeWebView, .showViewer,
            .watchFolder, .updateRepositoryFacts, .removeRepo, .pinRepo, .unpinRepo,
            .pinPane, .unpinPane, .openWorktree, .openWorktreeInPane, .openNewTerminalInTab,
            .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree,
            .toggleManagementLayer, .managementLayerExit,
            .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal,
            .managementLayerCreateBrowser,
            .toggleSidebar, .focusSidebar, .filterSidebar,
            .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
            .setInboxGroupingNone, .setInboxRowStateFilter, .setInboxContentMode,
            .showCommandBarEverything, .showCommandBarQuickOpen,
            .showCommandBarCommands, .showCommandBarPanes, .showCommandBarRepos,
            .newFloatingTerminal, .openWebview,
            .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab,
            .signInGitHub, .signInGoogle:
            .notYetAllowed
        }
    }
    var ipcSpec: AppCommandIPCSpec {
        AppCommandIPCSpec(
            exposure: ipcExposure,
            executionMode: ipcExecutionMode,
            argumentVariants: ipcArgumentVariants,
            requiredPrivilege: ipcRequiredPrivilege,
            allowedTargetKinds: ipcAllowedTargetKinds,
            resultVariants: ipcResultVariants,
            agentEligibility: ipcAgentEligibility
        )
    }
}
