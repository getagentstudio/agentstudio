import Foundation

@MainActor
package enum AppShortcutDispatchPolicy {
    package static func shouldRouteAppOwnedKeyEvent(context: KeyboardRoutingContext) -> Bool {
        switch context.activeSurface {
        case .commandBar, .transient:
            return false
        case .stable:
            return true
        }
    }

    package static func shouldDispatchGlobalShortcut(
        _ shortcut: AppShortcut,
        context: KeyboardRoutingContext
    ) -> Bool {
        if isCommandBarActivationShortcut(shortcut) {
            return context.stableOwner != .otherWindow
        }

        return shouldDispatchFromActiveSurface(shortcut, context: context)
    }

    package static func shouldConsumeUnavailableGlobalShortcut(
        _ shortcut: AppShortcut,
        context: KeyboardRoutingContext
    ) -> Bool {
        switch context.activeSurface {
        case .transient(.arrangementPanel):
            return shouldDispatchFromArrangementPanel(shortcut)
        case .commandBar, .stable, .transient:
            return false
        }
    }

    package static func shouldDispatchTerminalAppOwnedShortcut(
        _ shortcut: AppShortcut,
        context: KeyboardRoutingContext
    ) -> Bool {
        if isCommandBarActivationShortcut(shortcut) {
            return context.stableOwner != .otherWindow
        }

        guard shouldDispatchTerminalAppOwnedShortcutFromActiveSurface(shortcut, context: context) else {
            return false
        }

        switch context.stableOwner {
        case .mainWindowChain:
            return shortcut.spec.contexts.contains(.terminalAppOwned)
        case .managementLayer:
            return shortcut != .focusSidebar && shortcut != .focusPreviousPinnedPane && shortcut != .focusNextPinnedPane
                && shortcut.spec.contexts.contains(.terminalAppOwned)
        case .sidebar, .otherWindow:
            return false
        }
    }

    package static func sourcePaneTarget(for command: AppCommand, sourcePaneId: UUID?) -> UUID? {
        guard let sourcePaneId else { return nil }
        guard isTerminalRuntimeCommand(command) else { return nil }
        return sourcePaneId
    }

    package static func shouldSuppressTerminalHostTrigger(_ trigger: ShortcutTrigger) -> Bool {
        trigger == ShortcutTrigger(key: .character(.k), modifiers: [.command])
    }

    package static func isTerminalRuntimeCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt:
            return true
        case .closeTab, .breakUpTab, .renameTab, .newTerminalInTab, .newTab, .undoCloseTab,
            .selectTab, .nextTab, .prevTab, .selectTab1, .selectTab2, .selectTab3,
            .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .extractPaneToTab, .movePaneToTab, .focusPane, .splitRight, .splitLeft,
            .equalizePanes, .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane, .focusPane1, .focusPane2,
            .focusPane3, .focusPane4,
            .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9, .zoomPane,
            .minimizePane, .expandPane, .switchArrangement, .previousArrangement, .nextArrangement,
            .cycleArrangement, .saveArrangement, .deleteArrangement, .renameArrangement,
            .enterDrawer, .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown,
            .focusDrawerPaneRight, .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3,
            .focusDrawerPane4, .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7,
            .focusDrawerPane8, .focusDrawerPane9, .detachDrawerPane, .addDrawerPane,
            .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .editPaneNote, .copyCurrentPanePath, .openPullRequest,
            .watchFolder, .updateRepositoryFacts, .removeRepo, .pinRepo, .unpinRepo, .pinPane, .unpinPane,
            .openWorktree, .openWorktreeInPane, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch,
            .forkWorktree,
            .toggleManagementLayer,
            .managementLayerFocusLeft,
            .managementLayerFocusRight, .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal,
            .managementLayerCreateBrowser, .managementLayerExit, .toggleSidebar, .focusSidebar,
            .showInboxNotifications, .toggleInboxNotificationSort, .clearReadInboxNotifications,
            .clearAllInboxNotifications, .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane, .setInboxGroupingNone,
            .setInboxRowStateFilter, .setInboxContentMode,
            .newFloatingTerminal, .newWindow, .closeWindow,
            .showCommandBarEverything, .showCommandBarQuickOpen, .showCommandBarCommands,
            .showCommandBarPanes, .showCommandBarRepos, .openWebview, .reloadBridgeWebView,
            .showViewer,
            .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab, .signInGitHub, .signInGoogle, .copyAgentSetupPrompt,
            .filterSidebar, .openNewTerminalInTab:
            return false
        }
    }

    package static func isCommandBarActivationShortcut(_ shortcut: AppShortcut) -> Bool {
        switch shortcut {
        case .newTab, .showCommandBarEverything, .showCommandBarCommands, .showCommandBarPanes:
            return true
        case .undoCloseTab, .nextTab, .prevTab, .showArrangementPanel,
            .focusPreviousPinnedPane, .focusNextPinnedPane,
            .previousArrangement, .nextArrangement, .zoomPane, .showViewer,
            .addDrawerPane, .toggleDrawer, .scrollToBottom,
            .scrollPageUp, .scrollPageDown, .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .openPaneLocationInBookmarkedEditor,
            .openPaneLocationInFinder, .openPaneLocationInEditorMenu, .editPaneNote,
            .copyCurrentPanePath, .toggleManagementLayer, .toggleSidebar, .focusSidebar, .filterSidebar,
            .showInboxNotifications, .showPaneInboxNotifications, .showReposSidebar, .showPanesSidebar,
            .togglePanesShowsDrawers,
            .newWindow, .selectTab1, .selectTab2, .selectTab3, .selectTab4,
            .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9, .focusPane1,
            .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7,
            .focusPane8, .focusPane9, .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer, .managementLayerOpenDrawer,
            .managementLayerCreateTerminal, .managementLayerCreateBrowser, .managementLayerExit:
            return false
        }
    }

    static func shouldDispatchGlobalShortcut(
        _ shortcut: AppShortcut,
        keyboardOwner: KeyboardOwner
    ) -> Bool {
        switch keyboardOwner {
        case .otherWindow:
            return false
        case .managementLayer:
            return shortcut != .focusSidebar && shortcut != .focusPreviousPinnedPane && shortcut != .focusNextPinnedPane
                && shouldDispatchFromMainWindowChain(shortcut)
        case .mainWindowChain:
            return shouldDispatchFromMainWindowChain(shortcut)
        case .sidebar(let surface):
            return shouldDispatchFromSidebar(shortcut, surface: surface)
        }
    }

    private static func shouldDispatchFromActiveSurface(
        _ shortcut: AppShortcut,
        context: KeyboardRoutingContext
    ) -> Bool {
        switch context.activeSurface {
        case .commandBar:
            return false
        case .transient(let surface):
            guard shouldDispatchFromTransientSurface(shortcut, surface: surface) else {
                return false
            }
            return shouldDispatchGlobalShortcut(shortcut, keyboardOwner: context.stableOwner)
        case .stable:
            return shouldDispatchGlobalShortcut(shortcut, keyboardOwner: context.stableOwner)
        }
    }

    private static func shouldDispatchTerminalAppOwnedShortcutFromActiveSurface(
        _ shortcut: AppShortcut,
        context: KeyboardRoutingContext
    ) -> Bool {
        switch context.activeSurface {
        case .commandBar:
            return false
        case .transient(let surface):
            return shouldDispatchFromTransientSurface(shortcut, surface: surface)
        case .stable:
            return true
        }
    }

    private static func shouldDispatchFromTransientSurface(
        _ shortcut: AppShortcut,
        surface: TransientKeyboardSurfaceKind
    ) -> Bool {
        switch surface {
        case .arrangementPanel:
            return shouldDispatchFromArrangementPanel(shortcut)
        case .tabRename, .arrangementRename, .paneInbox, .editorChooser, .paneNote:
            return false
        }
    }

    private static func shouldDispatchFromArrangementPanel(_ shortcut: AppShortcut) -> Bool {
        switch shortcut {
        case .previousArrangement, .nextArrangement, .prevTab, .nextTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9:
            return true
        case .undoCloseTab, .newTab, .showArrangementPanel,
            .focusPreviousPinnedPane, .focusNextPinnedPane, .addDrawerPane,
            .toggleDrawer, .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown, .jumpToPreviousPrompt, .jumpToNextPrompt,
            .zoomPane, .showViewer,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .editPaneNote, .copyCurrentPanePath,
            .toggleManagementLayer, .toggleSidebar, .focusSidebar, .filterSidebar, .showInboxNotifications,
            .showPaneInboxNotifications, .showReposSidebar, .showPanesSidebar, .showCommandBarEverything,
            .togglePanesShowsDrawers,
            .showCommandBarCommands, .showCommandBarPanes, .newWindow,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6,
            .focusPane7, .focusPane8, .focusPane9, .managementLayerFocusLeft,
            .managementLayerFocusRight, .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal,
            .managementLayerCreateBrowser, .managementLayerExit:
            return false
        }
    }

    private static func shouldDispatchFromMainWindowChain(_ shortcut: AppShortcut) -> Bool {
        switch shortcut {
        case .filterSidebar, .showReposSidebar, .showPanesSidebar, .togglePanesShowsDrawers,
            .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown, .jumpToPreviousPrompt, .jumpToNextPrompt:
            return false
        case .toggleSidebar, .focusSidebar, .focusPreviousPinnedPane, .focusNextPinnedPane, .newTab,
            .undoCloseTab, .nextTab, .prevTab,
            .showArrangementPanel, .previousArrangement, .nextArrangement,
            .zoomPane, .showViewer, .addDrawerPane, .toggleDrawer, .openPaneLocationInBookmarkedEditor,
            .openPaneLocationInFinder, .openPaneLocationInEditorMenu, .editPaneNote,
            .copyCurrentPanePath, .toggleManagementLayer, .showInboxNotifications,
            .showPaneInboxNotifications, .newWindow,
            .showCommandBarEverything, .showCommandBarCommands, .showCommandBarPanes,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6,
            .selectTab7, .selectTab8, .selectTab9, .focusPane1, .focusPane2, .focusPane3,
            .focusPane4, .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .managementLayerFocusLeft, .managementLayerFocusRight, .managementLayerEnterDrawer,
            .managementLayerExitDrawer, .managementLayerOpenDrawer, .managementLayerCreateTerminal,
            .managementLayerCreateBrowser, .managementLayerExit:
            return true
        }
    }

    private static func shouldDispatchFromSidebar(
        _ shortcut: AppShortcut,
        surface: SidebarSurface
    ) -> Bool {
        switch shortcut {
        case .filterSidebar:
            return surface == .repos || surface == .panes
        case .togglePanesShowsDrawers:
            return surface == .panes
        case .toggleSidebar, .focusSidebar, .showInboxNotifications, .showReposSidebar, .showPanesSidebar,
            .showCommandBarEverything, .showCommandBarCommands, .showCommandBarPanes:
            return true
        case .newTab, .undoCloseTab, .nextTab, .prevTab, .showArrangementPanel,
            .focusPreviousPinnedPane, .focusNextPinnedPane,
            .previousArrangement, .nextArrangement, .addDrawerPane, .toggleDrawer, .scrollToBottom,
            .scrollPageUp, .scrollPageDown, .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .zoomPane, .showViewer,
            .openPaneLocationInBookmarkedEditor,
            .openPaneLocationInFinder, .openPaneLocationInEditorMenu, .editPaneNote,
            .copyCurrentPanePath, .toggleManagementLayer, .showPaneInboxNotifications,
            .newWindow, .selectTab1, .selectTab2, .selectTab3, .selectTab4,
            .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9, .focusPane1,
            .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7,
            .focusPane8, .focusPane9, .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer, .managementLayerOpenDrawer,
            .managementLayerCreateTerminal, .managementLayerCreateBrowser, .managementLayerExit:
            return false
        }
    }
}
