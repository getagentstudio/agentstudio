import AgentStudioInfrastructure
// swiftlint:disable cyclomatic_complexity function_body_length
import Foundation

/// Resolves workspace commands into fully-specified pane actions.
/// Uses live state to resolve structural tab/pane mutations into concrete IDs.
/// Pane focus navigation commands no longer resolve here; they route through
/// the Pane Focus System in PaneTabViewController.
///
/// Generic over `ResolvableTab` so resolution logic can be tested
/// with lightweight mocks (pure UUIDs, no NSViews).
///
/// Returns nil if the intent cannot be meaningfully resolved.
package enum WorkspaceCommandResolver {

    // MARK: - From AppCommand

    package static func resolve<T: ResolvableTab>(
        command: AppCommand,
        tabs: [T],
        activeTabId: UUID?,
        visiblePaneIds: (T) -> [UUID] = { $0.visiblePaneIds }
    ) -> WorkspaceActionCommand? {
        if isNonPaneCommand(command) {
            return nil
        }

        switch command {
        // Tab lifecycle
        case .selectTab:
            return nil
        case .closeTab:
            guard let tabId = activeTabId else { return nil }
            return .closeTab(tabId: tabId)

        case .renameTab:
            return nil

        case .breakUpTab:
            guard let tabId = activeTabId else { return nil }
            return .breakUpTab(tabId: tabId)

        case .nextTab:
            guard let tabId = activeTabId,
                let nextId = nextTabId(after: tabId, in: tabs)
            else { return nil }
            return .selectTab(tabId: nextId)

        case .prevTab:
            guard let tabId = activeTabId,
                let prevId = previousTabId(before: tabId, in: tabs)
            else { return nil }
            return .selectTab(tabId: prevId)

        case .selectTab1: return selectTabByIndex(0, tabs: tabs)
        case .selectTab2: return selectTabByIndex(1, tabs: tabs)
        case .selectTab3: return selectTabByIndex(2, tabs: tabs)
        case .selectTab4: return selectTabByIndex(3, tabs: tabs)
        case .selectTab5: return selectTabByIndex(4, tabs: tabs)
        case .selectTab6: return selectTabByIndex(5, tabs: tabs)
        case .selectTab7: return selectTabByIndex(6, tabs: tabs)
        case .selectTab8: return selectTabByIndex(7, tabs: tabs)
        case .selectTab9: return selectTabByIndex(8, tabs: tabs)

        // Pane lifecycle
        case .closePane:
            guard let (tab, paneId) = activeTabAndPane(tabs: tabs, activeTabId: activeTabId)
            else { return nil }
            if visiblePaneIds(tab).count <= 1 {
                return .closeTab(tabId: tab.id)
            }
            return .closePane(tabId: tab.id, paneId: paneId)

        case .focusPane:
            return nil
        case .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt:
            return nil
        case .extractPaneToTab:
            guard let (tab, paneId) = activeTabAndPane(tabs: tabs, activeTabId: activeTabId)
            else { return nil }
            return .extractPaneToTab(tabId: tab.id, paneId: paneId)

        case .movePaneToTab:
            return nil

        case .equalizePanes:
            guard let tabId = activeTabId else { return nil }
            return .equalizePanes(tabId: tabId)

        // Pane focus now routes through PaneFocusTrigger / PaneFocusDecision in PaneTabViewController.
        case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane:
            return nil

        // Split directions (horizontal only — vertical splits disabled for drawers)
        case .splitRight:
            return resolveSplit(.right, tabs: tabs, activeTabId: activeTabId)
        case .splitLeft:
            return resolveSplit(.left, tabs: tabs, activeTabId: activeTabId)

        case .zoomPane:
            return nil

        case .minimizePane:
            guard let (tab, paneId) = activeTabAndPane(tabs: tabs, activeTabId: activeTabId)
            else { return nil }
            return .minimizePane(tabId: tab.id, paneId: paneId)

        case .expandPane:
            guard let (tab, paneId) = activeTabAndPane(tabs: tabs, activeTabId: activeTabId)
            else { return nil }
            return .expandPane(tabId: tab.id, paneId: paneId)

        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            return nil

        case .watchFolder, .updateRepositoryFacts, .removeRepo, .pinRepo, .unpinRepo, .pinPane, .unpinPane,
            .toggleSidebar, .focusSidebar, .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications, .showPaneInboxNotifications,
            .clearPaneInboxNotifications,
            .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane, .setInboxGroupingNone,
            .setInboxRowStateFilter, .setInboxContentMode,
            .newFloatingTerminal,
            .newTerminalInTab, .newTab, .undoCloseTab,
            .newWindow, .closeWindow,
            .showCommandBarEverything, .showCommandBarQuickOpen, .showCommandBarCommands,
            .showCommandBarPanes, .showCommandBarRepos,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .editPaneNote, .copyCurrentPanePath, .openPullRequest,
            .openWebview, .reloadBridgeWebView, .showViewer, .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab, .signInGitHub, .signInGoogle, .copyAgentSetupPrompt,
            .filterSidebar, .openNewTerminalInTab, .openWorktree, .openWorktreeInPane,
            .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree,
            .switchArrangement, .previousArrangement, .nextArrangement, .cycleArrangement, .saveArrangement,
            .deleteArrangement, .renameArrangement,
            .enterDrawer, .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown,
            .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4,
            .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8,
            .focusDrawerPane9,
            .detachDrawerPane,
            .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .toggleManagementLayer,
            .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal, .managementLayerCreateBrowser,
            .managementLayerExit:
            return nil
        }
    }

    private static func isNonPaneCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .watchFolder, .updateRepositoryFacts, .removeRepo, .pinRepo, .unpinRepo, .pinPane, .unpinPane,
            .toggleSidebar, .focusSidebar, .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications, .showPaneInboxNotifications,
            .clearPaneInboxNotifications,
            .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane, .setInboxGroupingNone,
            .setInboxRowStateFilter, .setInboxContentMode,
            .newFloatingTerminal,
            .newTerminalInTab, .newTab, .undoCloseTab, .renameTab,
            .newWindow, .closeWindow,
            .showCommandBarEverything, .showCommandBarQuickOpen, .showCommandBarCommands,
            .showCommandBarPanes, .showCommandBarRepos,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder,
            .openPaneLocationInEditorMenu, .editPaneNote, .copyCurrentPanePath, .openPullRequest,
            .openWebview, .reloadBridgeWebView, .showViewer, .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab, .signInGitHub, .signInGoogle, .copyAgentSetupPrompt,
            .filterSidebar, .openNewTerminalInTab, .openWorktree, .openWorktreeInPane,
            .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree,
            .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt,
            .switchArrangement, .previousArrangement, .nextArrangement, .cycleArrangement, .saveArrangement,
            .deleteArrangement, .renameArrangement,
            .enterDrawer, .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown,
            .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4,
            .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8,
            .focusDrawerPane9,
            .detachDrawerPane,
            .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .toggleManagementLayer,
            .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal, .managementLayerCreateBrowser,
            .managementLayerExit:
            return true
        case .closeTab, .breakUpTab,
            .selectTab, .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .focusPane,
            .extractPaneToTab, .movePaneToTab,
            .equalizePanes,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .splitRight, .splitLeft,
            .zoomPane, .minimizePane, .expandPane:
            return false
        }
    }

    // MARK: - From Drop Event

    static func resolveDrop(
        payload: SplitDropPayload,
        destinationPaneId: UUID,
        destinationTabId: UUID,
        zone: DropZoneSide,
        sizingMode: DropSizingMode,
        state: ActionStateSnapshot
    ) -> WorkspaceActionCommand? {
        let direction = splitNewDirection(for: zone)

        switch payload.kind {
        case .existingTab(let tabId):
            RestoreTrace.log("WorkspaceCommandResolver rejected tab payload for split drop tab=\(tabId)")
            return nil

        case .existingPane(let paneId, let sourceTabId):
            if sourceTabId != destinationTabId {
                return .movePaneAcrossTabs(
                    CrossTabPaneMoveRequest(
                        paneId: paneId,
                        sourceTabId: sourceTabId,
                        destTabId: destinationTabId,
                        targetPaneId: destinationPaneId,
                        direction: layoutDirection(for: direction),
                        position: layoutPosition(for: direction)
                    )
                )
            }
            return .insertPane(
                source: .existingPane(paneId: paneId, sourceTabId: sourceTabId),
                targetTabId: destinationTabId,
                targetPaneId: destinationPaneId,
                direction: direction,
                sizingMode: sizingMode
            )

        case .newTerminal:
            return .insertPane(
                source: .newTerminal,
                targetTabId: destinationTabId,
                targetPaneId: destinationPaneId,
                direction: direction,
                sizingMode: sizingMode
            )
        }
    }

    // MARK: - Snapshot Factory

    /// Build a validation snapshot from live tab state.
    package static func snapshot<T: ResolvableTab>(
        from tabs: [T],
        activeTabId: UUID?,
        isManagementLayerActive: Bool,
        zoomSourcePaneIdByTabId: [UUID: UUID] = [:],
        knownRepoIds: Set<UUID> = [],
        knownWorktreeIds: Set<UUID> = [],
        knownPaneIds: Set<UUID>? = nil,
        drawerParentByPaneId: [UUID: UUID] = [:],
        drawerLayoutByParentPaneId: [UUID: DrawerGridLayout] = [:],
        visiblePaneIds: (T) -> [UUID] = { $0.visiblePaneIds }
    ) -> ActionStateSnapshot {
        ActionStateSnapshot(
            tabs: tabs.map { tab in
                TabSnapshot(
                    id: tab.id,
                    visiblePaneIds: visiblePaneIds(tab),
                    layoutPaneIds: tab.visiblePaneIds,
                    ownedPaneIds: tab.ownedPaneIds,
                    minimizedPaneIds: tab.minimizedPaneIdsForValidation,
                    activePaneId: tab.activePaneId,
                    isLayoutSplit: tab.isSplit,
                    activeArrangementId: tab.validationActiveArrangementId,
                    arrangements: tab.arrangementSnapshots
                )
            },
            activeTabId: activeTabId,
            isManagementLayerActive: isManagementLayerActive,
            zoomSourcePaneIdByTabId: zoomSourcePaneIdByTabId,
            knownRepoIds: knownRepoIds,
            knownWorktreeIds: knownWorktreeIds,
            knownPaneIds: knownPaneIds,
            drawerParentByPaneId: drawerParentByPaneId,
            drawerLayoutByParentPaneId: drawerLayoutByParentPaneId
        )
    }

    // MARK: - Private Helpers

    private static func activeTabAndPane<T: ResolvableTab>(
        tabs: [T], activeTabId: UUID?
    ) -> (T, UUID)? {
        guard let tabId = activeTabId,
            let tab = tabs.first(where: { $0.id == tabId }),
            let paneId = tab.activePaneId
        else { return nil }
        return (tab, paneId)
    }

    private static func selectTabByIndex<T: ResolvableTab>(
        _ index: Int, tabs: [T]
    ) -> WorkspaceActionCommand? {
        guard index >= 0, index < tabs.count else { return nil }
        return .selectTab(tabId: tabs[index].id)
    }

    private static func nextTabId<T: ResolvableTab>(
        after tabId: UUID, in tabs: [T]
    ) -> UUID? {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }),
            tabs.count > 1
        else { return nil }
        return tabs[(idx + 1) % tabs.count].id
    }

    private static func previousTabId<T: ResolvableTab>(
        before tabId: UUID, in tabs: [T]
    ) -> UUID? {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }),
            tabs.count > 1
        else { return nil }
        return tabs[(idx - 1 + tabs.count) % tabs.count].id
    }

    private static func resolveSplit<T: ResolvableTab>(
        _ direction: SplitNewDirection,
        tabs: [T], activeTabId: UUID?
    ) -> WorkspaceActionCommand? {
        guard let (tab, paneId) = activeTabAndPane(tabs: tabs, activeTabId: activeTabId)
        else { return nil }
        return .insertPane(
            source: .newTerminal,
            targetTabId: tab.id,
            targetPaneId: paneId,
            direction: direction,
            sizingMode: .halveTarget
        )
    }

    private static func splitNewDirection(for zone: DropZoneSide) -> SplitNewDirection {
        switch zone {
        case .left: return .left
        case .right: return .right
        }
    }

    private static func layoutDirection(for direction: SplitNewDirection) -> Layout.SplitDirection {
        switch direction {
        case .left, .right:
            return .horizontal
        case .up, .down:
            return .vertical
        }
    }

    private static func layoutPosition(for direction: SplitNewDirection) -> Layout.Position {
        switch direction {
        case .left, .up:
            return .before
        case .right, .down:
            return .after
        }
    }
}
