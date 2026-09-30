import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

/// Typed `command.execute` delivery into the workspace owner.
///
/// Every case here adapts explicit wire identities into the owner the
/// interactive path already uses. None of them consult active or focused
/// selection, so a programmatic request cannot silently retarget, and the
/// reported boundary is the one the owner actually reached.
extension PaneTabViewController {
    func executeHeadlessIPC(_ request: AppCommandExecutionRequest) async -> AppCommandExecutionOutcome {
        guard acceptsIPCCommands else { return .stateUnavailable }
        guard let arguments = request.typedIPCArguments else { return .unsupportedCommand }
        let command = request.command
        // A pane agent reaches only own-pane commands; anything else carrying
        // its assertion is refused rather than applied without the re-check.
        let ownPaneAssertion = request.ownPaneAssertion
        guard ownPaneAssertion == nil || command.ipcSpec.agentEligibility == .ownPane else {
            return .unsupportedCommand
        }
        switch arguments {
        case .noArguments:
            return .unsupportedCommand
        case .workspaceWindow:
            return await executeWindowScopedCommand(command)
        case .tab(let value):
            return await executeTabScopedCommand(command, tabId: value.tabId)
        case .renamedTab(let value):
            guard command == .renameTab else { return .unsupportedCommand }
            return await applyWorkspaceAction(
                .renameTab(tabId: value.tabId, name: value.name), for: command)
        case .newTab(let value):
            return await executeNewTabCommand(command, launchDirectory: value.launchDirectory)
        case .tabAnchor(let value):
            return await executeTabAnchorCommand(command, anchorTabId: value.anchorTabId)
        case .pane(let value):
            return await executePaneScopedCommand(
                command, selector: value.paneSelector, ownPaneAssertion: ownPaneAssertion)
        case .sourcePane(let value):
            return await executePaneNeighborFocusCommand(command, selector: value.sourcePaneSelector)
        case .standalonePane(let value):
            return await executeStandalonePaneCommand(command, selector: value.paneSelector)
        case .movePaneToTab(let value):
            return await executeMovePaneToTabCommand(command, arguments: value)
        case .repository(let value):
            return await executeRepositoryCommand(command, repoId: value.repoId)
        case .arrangement, .newArrangement, .renamedArrangement:
            return await executeArrangementCommand(command, arguments: arguments)
        case .drawerParent, .drawerSourcePane, .drawerPane, .detachedDrawerPane:
            return await executeDrawerCommand(command, arguments: arguments, ownPaneAssertion: ownPaneAssertion)
        case .managementFromMainPane, .managementFromDrawerPane:
            return executeManagementLayerCommand(command, arguments: arguments)
        case .worktree, .worktreeInPane, .terminalFromWorktree, .terminalFromPane,
            .floatingTerminal, .webview:
            return await executeWorkspaceSurfaceCommand(command, arguments: arguments)
        case .directory:
            return .unsupportedCommand
        }
    }

    // MARK: - Shared owner boundaries

    /// Await the validated workspace pipeline. `WorkspaceActionExecutor.execute`
    /// only resolves once the coordinator applied or rejected the action, so a
    /// true result is genuine application, not enqueue acceptance.
    func applyWorkspaceAction(
        _ action: WorkspaceActionCommand,
        for command: AppCommand
    ) async -> AppCommandExecutionOutcome {
        headlessIPCOutcome(await executor.execute(action), for: command)
    }

    /// Translate an owner's success flag into the strongest boundary the
    /// projection lets this command advertise.
    func headlessIPCOutcome(_ applied: Bool, for command: AppCommand) -> AppCommandExecutionOutcome {
        if applied { return .applied }
        return command.ipcSpec.resultVariants.contains(.unavailable)
            ? .unavailable(.stateUnavailable)
            : .stateUnavailable
    }

    // MARK: - Window-scoped commands

    private func executeWindowScopedCommand(_ command: AppCommand) async -> AppCommandExecutionOutcome {
        switch command {
        case .undoCloseTab:
            return headlessIPCOutcome(await executor.submitUndoClose().value, for: command)
        case .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9:
            guard let ordinal = AppCommand.selectTabCommands.firstIndex(of: command),
                let tab = store.tabLayoutAtom.tabs.dropFirst(ordinal).first
            else { return .unavailable(.noApplicableTarget) }
            return await applyWorkspaceAction(.selectTab(tabId: tab.id), for: command)
        case .toggleManagementLayer, .managementLayerExit:
            return headlessIPCOutcome(handleManagementCommand(command), for: command)
        default:
            return .unsupportedCommand
        }
    }

    // MARK: - Tab-scoped commands

    private func executeTabScopedCommand(
        _ command: AppCommand,
        tabId: UUID
    ) async -> AppCommandExecutionOutcome {
        switch command {
        case .closeTab, .breakUpTab, .equalizePanes, .newTerminalInTab, .selectTab:
            guard let action = targetedTabAction(command: command, target: tabId, targetType: .tab) else {
                return .stateUnavailable
            }
            return await applyWorkspaceAction(action, for: command)
        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            return await executeMainPaneOrdinalFocus(command, tabId: tabId)
        case .previousArrangement, .nextArrangement, .cycleArrangement:
            return await executeArrangementCycle(command, tabId: tabId)
        default:
            return .unsupportedCommand
        }
    }

    private func executeMainPaneOrdinalFocus(
        _ command: AppCommand,
        tabId: UUID
    ) async -> AppCommandExecutionOutcome {
        guard let ordinal = AppCommand.focusPaneCommands.firstIndex(of: command).map({ $0 + 1 }),
            let tab = store.tabLayoutAtom.tab(tabId),
            let paneId = PaneOrdinalMap(
                orderedPaneIds: tab.activePaneIds.filter { !tab.activeMinimizedPaneIds.contains($0) }
            ).paneId(forOrdinal: ordinal)
        else {
            return .unavailable(.noApplicableTarget)
        }
        guard canFocusTargetedPane(paneId) else { return .unavailable(.stateUnavailable) }
        return headlessIPCOutcome(await submitTargetedPaneFocus(paneId).value, for: command)
    }

    private func executeArrangementCycle(
        _ command: AppCommand,
        tabId: UUID
    ) async -> AppCommandExecutionOutcome {
        guard let tab = store.tabLayoutAtom.tab(tabId),
            tab.arrangements.count > 1,
            let activeIndex = tab.arrangements.firstIndex(where: { $0.id == tab.activeArrangementId })
        else {
            return .unavailable(.noApplicableTarget)
        }
        let delta = command == .previousArrangement ? -1 : 1
        let nextIndex = (activeIndex + delta + tab.arrangements.count) % tab.arrangements.count
        return await applyWorkspaceAction(
            .switchArrangement(tabId: tabId, arrangementId: tab.arrangements[nextIndex].id),
            for: command
        )
    }

    private func executeNewTabCommand(
        _ command: AppCommand,
        launchDirectory: String?
    ) async -> AppCommandExecutionOutcome {
        guard command == .newTab else { return .unsupportedCommand }
        let directory =
            AppCommandTypedIPCPane.launchDirectory(launchDirectory)
            ?? store.repositoryTopologyAtom.watchedPaths.first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser
        return await applyWorkspaceAction(
            .openFloatingTerminal(launchDirectory: directory, title: nil), for: command)
    }

    private func executeTabAnchorCommand(
        _ command: AppCommand,
        anchorTabId: UUID
    ) async -> AppCommandExecutionOutcome {
        let tabs = store.tabLayoutAtom.tabs
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }), tabs.count > 1 else {
            return .stateUnavailable
        }
        let delta: Int
        switch command {
        case .nextTab: delta = 1
        case .prevTab: delta = -1
        default: return .unsupportedCommand
        }
        let nextIndex = (anchorIndex + delta + tabs.count) % tabs.count
        return await applyWorkspaceAction(.selectTab(tabId: tabs[nextIndex].id), for: command)
    }

    // MARK: - Pane-scoped commands

    private func executePaneScopedCommand(
        _ command: AppCommand,
        selector: IPCPaneSelector,
        ownPaneAssertion: WorkspaceOwnPaneAssertion?
    ) async -> AppCommandExecutionOutcome {
        guard let paneId = AppCommandTypedIPCPane.canonicalId(selector) else { return .stateUnavailable }
        switch command {
        case .minimizePane, .expandPane, .closePane, .toggleDrawer:
            guard
                let action = targetedPaneWorkspaceAction(
                    command: command, paneId: paneId, targetType: .pane)
            else { return .stateUnavailable }
            return await applyWorkspaceAction(action, for: command)
        case .extractPaneToTab:
            guard let tab = store.tabLayoutAtom.tabContaining(paneId: paneId) else {
                return .stateUnavailable
            }
            return await applyWorkspaceAction(
                .extractPaneToTab(tabId: tab.id, paneId: paneId), for: command)
        case .splitRight, .splitLeft:
            guard let tab = store.tabLayoutAtom.tabContaining(paneId: paneId) else {
                return .stateUnavailable
            }
            return await applyWorkspaceAction(
                .insertPane(
                    source: .newTerminal,
                    targetTabId: tab.id,
                    targetPaneId: paneId,
                    direction: command == .splitLeft ? .left : .right,
                    sizingMode: .halveTarget
                ),
                for: command
            )
        case .focusPane:
            guard canFocusTargetedPane(paneId) else { return .stateUnavailable }
            return headlessIPCOutcome(await submitTargetedPaneFocus(paneId).value, for: command)
        case .zoomPane:
            return headlessIPCOutcome(
                await dispatchGesture { [self] execute in
                    await executeZoomCommandAfterAdmission(explicitPaneId: paneId, execute: execute)
                }.value,
                for: command
            )
        case .showViewer:
            return await executeViewerCommand(command, paneId: paneId)
        case .scrollToBottom, .scrollPageUp, .scrollPageDown, .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt:
            return await executeTerminalRuntimeCommand(command, paneId: paneId, ownPaneAssertion: ownPaneAssertion)
        case .focusPreviousPinnedPane, .focusNextPinnedPane:
            return .stateUnavailable
        case .reloadBridgeWebView:
            guard let mountView = resolvedBridgeCommandMountView(paneId: paneId),
                mountView.controller.reloadWebView()
            else { return .stateUnavailable }
            // The webview reload is initiated here and completes in WebKit, so
            // the receipt is acceptance rather than application.
            return .accepted(operationId: nil)
        case .openPaneLocationInBookmarkedEditor:
            guard let targetPath = targetedPaneLocationPath(paneId: paneId) else {
                return .unavailable(.noApplicableTarget)
            }
            return headlessIPCOutcome(
                openPaneLocationInBookmarkedEditor(targetPath: targetPath), for: command)
        case .openPaneLocationInFinder, .copyCurrentPanePath, .openPullRequest:
            guard targetedPaneExternalCommandCapability(command, paneId: paneId) else {
                return .stateUnavailable
            }
            return headlessIPCOutcome(
                handleTargetedPaneExternalCommand(command, paneId: paneId), for: command)
        case .openPaneLocationInEditorMenu:
            guard targetedPaneExternalCommandCapability(command, paneId: paneId),
                handleTargetedPaneExternalCommand(command, paneId: paneId)
            else { return .stateUnavailable }
            return .presented
        case .editPaneNote:
            guard store.paneAtom.pane(paneId) != nil else { return .stateUnavailable }
            guard await submitTargetedPaneFocus(paneId).value else {
                return .unavailable(.stateUnavailable)
            }
            paneNotePresentation.present(paneId)
            // Presentation only. The note the user later writes is not this
            // command's completion.
            return .presented
        default:
            return .unsupportedCommand
        }
    }

    private func executeViewerCommand(
        _ command: AppCommand,
        paneId: UUID
    ) async -> AppCommandExecutionOutcome {
        let applied = await dispatchGesture { [self] execute in
            switch executeZoomLocalViewerCommand(explicitPaneId: paneId) {
            case .notZoomLocal:
                return await enterZoomAndShowViewerAfterAdmission(
                    explicitPaneId: paneId,
                    execute: execute
                )
            case .toggled(let didToggle):
                return didToggle
            }
        }.value
        return headlessIPCOutcome(applied, for: command)
    }

    /// Await the runtime owner. The interactive shortcut path schedules an
    /// unstructured task and returns immediately; a programmatic receipt must
    /// not inherit that scheduling bool as application.
    private func executeTerminalRuntimeCommand(
        _ command: AppCommand,
        paneId: UUID,
        ownPaneAssertion: WorkspaceOwnPaneAssertion?
    ) async -> AppCommandExecutionOutcome {
        let runtimeCommand: PaneRuntimeCommand
        switch command {
        case .scrollToBottom: runtimeCommand = .terminal(.scrollToBottom)
        case .scrollPageUp: runtimeCommand = .terminal(.scrollPageFractional(fraction: -1))
        // The interactive shortcuts' fractions, so an agent scrolls exactly as
        // the keys do.
        case .scrollPageDown:
            runtimeCommand = .terminal(
                .scrollPageFractional(fraction: AppPolicies.TerminalNavigation.pageFraction))
        case .scrollSmallStepUp:
            runtimeCommand = .terminal(
                .scrollPageFractional(fraction: -AppPolicies.TerminalNavigation.smallStepFraction))
        case .scrollSmallStepDown:
            runtimeCommand = .terminal(
                .scrollPageFractional(fraction: AppPolicies.TerminalNavigation.smallStepFraction))
        case .jumpToPreviousPrompt: runtimeCommand = .terminal(.jumpToPrompt(delta: -1))
        case .jumpToNextPrompt: runtimeCommand = .terminal(.jumpToPrompt(delta: 1))
        default: return .unsupportedCommand
        }
        // Checked in the same main-actor step that hands the command to the
        // runtime.
        if let ownPaneAssertion, !store.ownPaneAssertionHolds(ownPaneAssertion, for: paneId) {
            return .outsideOwnPane
        }
        let result = await runtimeCommandDispatcher.dispatchRuntimeCommand(
            runtimeCommand,
            target: .pane(PaneId(existingUUID: paneId)),
            correlationId: nil
        )
        switch result {
        case .success, .queued:
            return .applied
        case .failure:
            return .unavailable(.stateUnavailable)
        }
    }

    private func executePaneNeighborFocusCommand(
        _ command: AppCommand,
        selector: IPCPaneSelector
    ) async -> AppCommandExecutionOutcome {
        guard let sourcePaneId = AppCommandTypedIPCPane.canonicalId(selector),
            let tab = store.tabLayoutAtom.tabContaining(paneId: sourcePaneId)
        else { return .stateUnavailable }

        let targetPaneId: UUID?
        switch command {
        case .focusPaneLeft: targetPaneId = tab.neighborPaneId(of: sourcePaneId, direction: .left)
        case .focusPaneRight: targetPaneId = tab.neighborPaneId(of: sourcePaneId, direction: .right)
        case .focusPaneUp: targetPaneId = tab.neighborPaneId(of: sourcePaneId, direction: .up)
        case .focusPaneDown: targetPaneId = tab.neighborPaneId(of: sourcePaneId, direction: .down)
        case .focusNextPane: targetPaneId = tab.nextPaneId(after: sourcePaneId)
        case .focusPrevPane: targetPaneId = tab.previousPaneId(before: sourcePaneId)
        default: return .unsupportedCommand
        }
        guard let targetPaneId, canFocusTargetedPane(targetPaneId) else {
            return .unavailable(.noApplicableTarget)
        }
        handlePaneFocusTrigger(
            .keyboard(
                .moveToPane(
                    tabId: tab.id,
                    paneId: targetPaneId,
                    paneKind: PaneFocusContext.PaneKind(content: store.paneAtom.pane(targetPaneId)?.content)
                )))
        return .applied
    }

    private func executeStandalonePaneCommand(
        _ command: AppCommand,
        selector: IPCPaneSelector
    ) async -> AppCommandExecutionOutcome {
        guard let paneId = AppCommandTypedIPCPane.canonicalId(selector) else { return .stateUnavailable }
        guard
            let action = targetedSidebarAction(command: command, target: paneId, targetType: .pane)
        else { return .unsupportedCommand }
        return await applyWorkspaceAction(action, for: command)
    }

    private func executeMovePaneToTabCommand(
        _ command: AppCommand,
        arguments: IPCMovePaneToTabCommandArguments
    ) async -> AppCommandExecutionOutcome {
        guard command == .movePaneToTab,
            let sourcePaneId = AppCommandTypedIPCPane.canonicalId(arguments.sourcePaneSelector)
        else { return .unsupportedCommand }
        guard
            let action = makeMovePaneToTabAction(
                sourcePaneId: sourcePaneId,
                sourceTabId: store.tabLayoutAtom.tabContaining(paneId: sourcePaneId)?.id,
                targetTabId: arguments.destinationTabId
            )
        else { return .stateUnavailable }
        return await applyWorkspaceAction(action, for: command)
    }

    private func executeRepositoryCommand(
        _ command: AppCommand,
        repoId: UUID
    ) async -> AppCommandExecutionOutcome {
        guard
            let action = targetedSidebarAction(command: command, target: repoId, targetType: .repo)
        else { return .unsupportedCommand }
        return await applyWorkspaceAction(action, for: command)
    }
}
