import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AppKit
import Foundation

extension AppDelegate: ShellCommandHandling {
    func ownsWorkspaceWindow(_ workspaceWindowId: UUID) -> Bool {
        guard let controller = mainWindowController, controller.acceptsIPCCommands else {
            return false
        }
        return controller.workspaceWindowId == workspaceWindowId
    }

    func canExecute(_ request: AppCommandExecutionRequest) -> Bool {
        guard request.arguments == .noArguments else { return false }
        return canExecute(request.command)
    }

    func canExecute(_ command: AppCommand) -> Bool {
        if command == .focusSidebar {
            guard let atomStore else { return false }
            return !atomStore.core.managementLayer.isActive
        }
        if let sidebarCapability = sidebarCommandCapability(command) {
            return sidebarCapability
        }
        return switch command {
        case .watchFolder, .toggleSidebar, .focusSidebar, .filterSidebar,
            .showReposSidebar, .showPanesSidebar,
            .signInGitHub, .signInGoogle, .copyAgentSetupPrompt, .newWindow, .closeWindow,
            .showCommandBarEverything, .showCommandBarQuickOpen, .showCommandBarCommands,
            .showCommandBarPanes, .showCommandBarRepos:
            true
        case .closeTab, .breakUpTab, .renameTab, .newTerminalInTab, .newTab, .undoCloseTab,
            .selectTab, .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .extractPaneToTab, .movePaneToTab, .focusPane, .scrollToBottom,
            .scrollPageUp, .scrollPageDown, .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt,
            .splitRight, .splitLeft, .equalizePanes,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane, .zoomPane, .minimizePane,
            .expandPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .switchArrangement, .previousArrangement, .nextArrangement, .cycleArrangement,
            .saveArrangement, .deleteArrangement, .renameArrangement,
            .enterDrawer, .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown,
            .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4,
            .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8,
            .focusDrawerPane9,
            .detachDrawerPane, .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder, .openPaneLocationInEditorMenu,
            .editPaneNote, .copyCurrentPanePath, .openPullRequest,
            .updateRepositoryFacts, .removeRepo, .pinRepo, .unpinRepo, .pinPane, .unpinPane,
            .openWorktree, .openWorktreeInPane, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch,
            .forkWorktree,
            .toggleManagementLayer,
            .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal, .managementLayerCreateBrowser,
            .managementLayerExit,
            .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
            .setInboxGroupingNone,
            .newFloatingTerminal, .openWebview, .reloadBridgeWebView, .showViewer,
            .showBridgeReview, .showBridgeFiles,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .setInboxRowStateFilter, .setInboxContentMode,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab, .openNewTerminalInTab:
            false
        }
    }

    func execute(_ command: AppCommand) -> Bool {
        if sidebarSettingSurface(for: command) != nil {
            return executeSidebarSettingCommand(command) == .applied
        }
        return executeShellAction(command)
    }

    private func executeShellAction(_ command: AppCommand) -> Bool {
        switch command {
        case .copyAgentSetupPrompt:
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(AgentSetupPrompt.text, forType: .string)
        case .watchFolder:
            Task { await handleWatchFolderRequested() }
            return true
        case .updateRepositoryFacts:
            return false
        case .toggleSidebar:
            mainWindowController?.toggleSidebar()
            return true
        case .focusSidebar:
            guard let atomStore, !atomStore.core.managementLayer.isActive else { return false }
            mainWindowController?.focusSidebarFromCommand()
            return true
        case .filterSidebar:
            mainWindowController?.showSidebarFilter()
            return true
        case .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications:
            return false
        case .showReposSidebar:
            return executeSidebarScreenCommand(.repos) == .applied
        case .showPanesSidebar:
            return executeSidebarScreenCommand(.panes) == .applied
        case .setInboxRowStateFilter, .setInboxContentMode:
            return false
        case .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
            .setInboxGroupingNone:
            return false
        case .newWindow:
            newWindow()
            return true
        case .closeWindow:
            closeWindow()
            return true
        case .showCommandBarEverything:
            showCommandBar(prefix: nil, context: "command bar")
            return true
        case .showCommandBarQuickOpen:
            showCommandBar(defaultRootScope: .quickOpen, context: "command bar (quick open)")
            return true
        case .showCommandBarCommands:
            showCommandBar(prefix: ">", context: "command bar (commands)")
            return true
        case .showCommandBarPanes:
            showCommandBar(prefix: "$", context: "command bar (panes)")
            return true
        case .showCommandBarRepos:
            showCommandBar(prefix: "#", context: "command bar (repos)")
            return true
        case .signInGitHub:
            handleSignInRequested(provider: .github)
            return true
        case .signInGoogle:
            handleSignInRequested(provider: .google)
            return true
        case .closeTab, .breakUpTab, .renameTab, .newTerminalInTab, .newTab, .undoCloseTab,
            .selectTab, .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .extractPaneToTab, .movePaneToTab, .focusPane, .scrollToBottom,
            .scrollPageUp, .scrollPageDown, .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt,
            .splitRight, .splitLeft, .equalizePanes,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane, .zoomPane, .minimizePane,
            .expandPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .switchArrangement, .previousArrangement, .nextArrangement, .cycleArrangement,
            .saveArrangement, .deleteArrangement, .renameArrangement,
            .enterDrawer, .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown,
            .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4,
            .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8,
            .focusDrawerPane9,
            .detachDrawerPane, .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder, .openPaneLocationInEditorMenu,
            .editPaneNote, .copyCurrentPanePath, .openPullRequest,
            .removeRepo, .pinRepo, .unpinRepo, .pinPane, .unpinPane, .openWorktree, .openWorktreeInPane,
            .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch, .forkWorktree,
            .toggleManagementLayer,
            .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal, .managementLayerCreateBrowser,
            .managementLayerExit,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .newFloatingTerminal, .openWebview, .reloadBridgeWebView, .showViewer,
            .showBridgeReview, .showBridgeFiles,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab, .openNewTerminalInTab:
            return false
        }
    }

    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        switch command {
        case .updateRepositoryFacts:
            return executeRepositoryFactUpdate(repoId: target, targetType: targetType)
        case .closeTab, .breakUpTab, .renameTab, .newTerminalInTab, .newTab, .undoCloseTab,
            .selectTab, .nextTab, .prevTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            .closePane, .extractPaneToTab, .movePaneToTab, .focusPane, .scrollToBottom,
            .scrollPageUp, .scrollPageDown, .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt,
            .splitRight, .splitLeft, .equalizePanes,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .focusNextPane, .focusPrevPane, .focusPreviousPinnedPane, .focusNextPinnedPane, .zoomPane, .minimizePane,
            .expandPane,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
            .switchArrangement, .previousArrangement, .nextArrangement, .cycleArrangement,
            .saveArrangement, .deleteArrangement, .renameArrangement,
            .enterDrawer, .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown,
            .focusDrawerPaneRight,
            .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4,
            .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8,
            .focusDrawerPane9,
            .detachDrawerPane, .addDrawerPane, .toggleDrawer, .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge,
            .navigateDrawerPane, .closeDrawerPane,
            .openPaneLocationInBookmarkedEditor, .openPaneLocationInFinder, .openPaneLocationInEditorMenu,
            .editPaneNote, .copyCurrentPanePath, .openPullRequest,
            .watchFolder, .removeRepo, .pinRepo, .unpinRepo, .pinPane, .unpinPane,
            .openWorktree, .openWorktreeInPane, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch,
            .forkWorktree,
            .toggleManagementLayer,
            .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer,
            .managementLayerOpenDrawer, .managementLayerCreateTerminal, .managementLayerCreateBrowser,
            .managementLayerExit,
            .toggleSidebar, .focusSidebar, .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications, .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .setPanesSortFieldName, .setPanesSortFieldActivity,
            .toggleReposSortDirection, .togglePanesSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned, .togglePanesShowsDrawers,
            .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane, .setInboxGroupingNone,
            .setInboxRowStateFilter, .setInboxContentMode,
            .newFloatingTerminal, .newWindow, .closeWindow,
            .showCommandBarEverything, .showCommandBarQuickOpen, .showCommandBarCommands,
            .showCommandBarPanes, .showCommandBarRepos,
            .openWebview, .reloadBridgeWebView, .showViewer, .showBridgeReview, .showBridgeFiles,
            .openBridgeReviewInNewTab, .openBridgeFilesInNewTab, .signInGitHub, .signInGoogle, .copyAgentSetupPrompt,
            .filterSidebar, .openNewTerminalInTab:
            return false
        }
    }

    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        if command == .newWorktreeFromBranch || WorktreeCreationKind(command: command) != nil {
            return canExecuteWorktreeCreation(command, targetId: target, targetType: targetType)
        }
        guard command == .updateRepositoryFacts else {
            return canExecute(command)
        }
        guard
            targetType == .repo,
            repositoryFactUpdateSource != nil,
            store?.repositoryTopologyAtom.repo(target) != nil
        else {
            return false
        }
        return repositoryFactUpdateTasksByRepoId[target] == nil
    }

    func cancelRepositoryFactUpdate(repoId: UUID) {
        repositoryFactUpdateTasksByRepoId[repoId]?.cancel()
        repoCache?.removeRepositoryFactUpdateProgress(for: repoId)
    }

    func cancelAllRepositoryFactUpdates() {
        for task in repositoryFactUpdateTasksByRepoId.values {
            task.cancel()
        }
        guard let repoCache else { return }
        for repoId in repositoryFactUpdateTasksByRepoId.keys {
            repoCache.removeRepositoryFactUpdateProgress(for: repoId)
        }
    }

    func waitForRepositoryFactUpdatesToSettle() async {
        let tasks = Array(repositoryFactUpdateTasksByRepoId.values)
        for task in tasks {
            await task.value
        }
    }

    func acknowledgePresentedRepositoryFactUpdate(repoId: UUID, attemptId: UUID) {
        guard
            repositoryFactUpdateTasksByRepoId[repoId] == nil,
            let progress = repoCache?.repositoryFactUpdateProgress(for: repoId),
            progress.attemptId == attemptId,
            progress.phase == .settled
        else { return }
        repoCache.removeRepositoryFactUpdateProgress(for: repoId)
    }

    private func executeRepositoryFactUpdate(repoId: UUID, targetType: SearchItemType) -> Bool {
        guard
            canExecute(.updateRepositoryFacts, target: repoId, targetType: targetType),
            store.repositoryTopologyAtom.repo(repoId) != nil,
            let repositoryFactUpdateSource
        else {
            return false
        }

        let attemptId = UUIDv7.generate()
        repoCache.setRepositoryFactUpdateProgress(
            .captured(repoId: repoId, attemptId: attemptId)
        )
        recordRepositoryFactUpdateProgress(
            .captured(repoId: repoId, attemptId: attemptId),
            stage: "captured"
        )
        repositoryFactUpdateTasksByRepoId[repoId] = Task { @MainActor [weak self, repositoryFactUpdateSource] in
            let admission = await repositoryFactUpdateSource.startRepositoryFactUpdate(
                repoId: repoId,
                attemptId: attemptId
            )
            guard self?.isCurrentRepositoryFactUpdate(repoId: repoId, attemptId: attemptId) == true else {
                _ = await admission.settlement()
                self?.finishRepositoryFactUpdateTask(repoId: repoId, attemptId: attemptId)
                return
            }

            let admittedProgress = RepositoryFactUpdateProgress.admitted(
                repoId: repoId,
                attemptId: attemptId,
                applicableSources: admission.acceptedSources,
                terminalResultsBySource: admission.terminalResultsBySource
            )
            if !admission.acceptedSources.isEmpty {
                self?.repoCache.setRepositoryFactUpdateProgress(admittedProgress)
            }
            self?.recordRepositoryFactUpdateProgress(admittedProgress, stage: "admitted")
            let outcomesBySource = await admission.settlement()
            guard let self else { return }
            if self.isCurrentRepositoryFactUpdate(repoId: repoId, attemptId: attemptId) {
                self.finishRepositoryFactUpdateTask(repoId: repoId, attemptId: attemptId)
                let settledProgress = admittedProgress.settled(outcomesBySource)
                self.repoCache.setRepositoryFactUpdateProgress(settledProgress)
                self.recordRepositoryFactUpdateProgress(settledProgress, stage: "settled")
                return
            }
            self.finishRepositoryFactUpdateTask(repoId: repoId, attemptId: attemptId)
        }
        return true
    }

    private func recordRepositoryFactUpdateProgress(
        _ progress: RepositoryFactUpdateProgress,
        stage: String
    ) {
        let outcome: String
        switch progress.phase {
        case .captured: outcome = "captured"
        case .inProgress: outcome = "loading"
        case .settled: outcome = Self.repositoryFactUpdateSettlementOutcome(progress)
        }
        performanceTraceRecorder?.record(
            .repositoryFactUpdate,
            attributes: [
                "agentstudio.performance.repository_update.stage": .string(stage),
                "agentstudio.performance.repository_update.outcome": .string(outcome),
                "agentstudio.performance.repository_update.applicable_source.count": .int(
                    progress.applicableSources.count),
                "agentstudio.performance.repository_update.unsettled_source.count": .int(
                    progress.unsettledSources.count),
                "agentstudio.performance.repository_update.terminal_source.count": .int(
                    progress.settledResultsBySource.count),
            ]
        )
    }

    static func repositoryFactUpdateSettlementOutcome(
        _ progress: RepositoryFactUpdateProgress
    ) -> String {
        guard !progress.applicableSources.isEmpty else { return "no_applicable" }
        let applicableResults = progress.applicableSources.compactMap {
            progress.settledResultsBySource[$0]
        }
        guard applicableResults.count == progress.applicableSources.count else {
            return "incomplete"
        }
        let completedCount = applicableResults.count { $0 == .completed }
        if completedCount == applicableResults.count { return "complete" }
        if completedCount > 0 { return "partial_failure" }
        if applicableResults.contains(.failed) { return "failed" }
        if applicableResults.allSatisfy({ $0 == .cancelled }) { return "cancelled" }
        if applicableResults.allSatisfy({ $0 == .obsolete }) { return "obsolete" }
        return "mixed_terminal"
    }

    private func isCurrentRepositoryFactUpdate(repoId: UUID, attemptId: UUID) -> Bool {
        repoCache.repositoryFactUpdateProgress(for: repoId)?.attemptId == attemptId
    }

    private func finishRepositoryFactUpdateTask(repoId: UUID, attemptId: UUID) {
        guard
            repositoryFactUpdateTasksByRepoId[repoId] != nil,
            repoCache.repositoryFactUpdateProgress(for: repoId)?.attemptId == attemptId
                || repoCache.repositoryFactUpdateProgress(for: repoId) == nil
        else {
            return
        }
        repositoryFactUpdateTasksByRepoId.removeValue(forKey: repoId)
    }

    func execute(_ request: AppCommandExecutionRequest) -> AppCommandExecutionOutcome {
        if let typedArguments = request.typedIPCArguments {
            return executeTypedIPCShellCommand(request.command, arguments: typedArguments)
        }
        switch request.command {
        case .showInboxNotifications, .toggleInboxNotificationSort,
            .clearReadInboxNotifications, .clearAllInboxNotifications,
            .showPaneInboxNotifications, .clearPaneInboxNotifications,
            .setInboxGroupingTab, .setInboxGroupingRepo,
            .setInboxGroupingPane, .setInboxGroupingNone,
            .setInboxRowStateFilter, .setInboxContentMode:
            return .unsupportedCommand
        default:
            return execute(request.command) ? .applied : .unsupportedCommand
        }
    }

    private func sidebarSettingSurface(for command: AppCommand) -> SidebarSurface? {
        switch command {
        case .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .toggleReposSortDirection, .toggleReposShowsPinned:
            .repos
        case .togglePanesShowsPinned, .togglePanesShowsDrawers:
            .panes
        default:
            nil
        }
    }

    private func sidebarCommandCapability(_ command: AppCommand) -> Bool? {
        switch command {
        case .setPanesSortFieldName, .setPanesSortFieldActivity, .togglePanesSortDirection:
            return false
        default:
            break
        }
        if command == .showReposSidebar || command == .showPanesSidebar {
            return atomStore != nil
        }
        guard let requiredSurface = sidebarSettingSurface(for: command) else { return nil }
        guard let atomStore else { return false }
        guard atomStore.core.workspaceSidebarState.sidebarSurface == requiredSurface else {
            return false
        }
        return true
    }

    private func executeSidebarSettingCommand(_ command: AppCommand) -> AppCommandExecutionOutcome {
        guard let atomStore else { return .stateUnavailable }
        guard let surface = sidebarSettingSurface(for: command) else { return .unsupportedCommand }
        guard atomStore.core.workspaceSidebarState.sidebarSurface == surface else {
            return .unsupportedCommand
        }
        let prefs = atomStore.repoExplorerSidebarPrefs
        switch command {
        case .setReposGroupingRepo:
            prefs.setGroupingMode(.repo, for: surface)
        case .setReposGroupingActivity:
            prefs.setGroupingMode(.activity, for: surface)
        case .setReposSortFieldName:
            prefs.setSortField(.name, for: surface)
        case .setReposSortFieldActivity:
            prefs.setSortField(.activity, for: surface)
        case .toggleReposSortDirection:
            prefs.setSortDirection(prefs.sortDirection(for: surface).toggled, for: surface)
        case .toggleReposShowsPinned, .togglePanesShowsPinned:
            prefs.setShowsPinned(!prefs.showsPinned(for: surface), for: surface)
        case .togglePanesShowsDrawers:
            prefs.setShowsDrawerPanes(!prefs.showsDrawerPanes)
        default:
            return .unsupportedCommand
        }
        return .applied
    }

    private func executeSidebarScreenCommand(_ surface: SidebarSurface) -> AppCommandExecutionOutcome {
        guard let atomStore else { return .stateUnavailable }
        atomStore.core.workspaceSidebarState.setSidebarSurface(surface)
        mainWindowController?.expandSidebar()
        guard
            atomStore.core.workspaceSidebarState.sidebarSurface == surface,
            atomStore.core.workspaceSidebarState.sidebarCollapsed == false
        else {
            return .stateUnavailable
        }
        return .applied
    }
}
