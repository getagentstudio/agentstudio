import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

/// Typed `command.execute` delivery for the arrangement, drawer and
/// management-layer families. Each case names its tab, parent pane and drawer
/// child explicitly instead of reading the current navigation scope.
extension PaneTabViewController {
    // MARK: - Arrangements

    func executeArrangementCommand(
        _ command: AppCommand,
        arguments: IPCCommandArguments
    ) async -> AppCommandExecutionOutcome {
        switch (command, arguments) {
        case (.switchArrangement, .arrangement(let value)):
            return await applyWorkspaceAction(
                .switchArrangement(tabId: value.tabId, arrangementId: value.arrangementId), for: command)
        case (.deleteArrangement, .arrangement(let value)):
            return await applyWorkspaceAction(
                .removeArrangement(tabId: value.tabId, arrangementId: value.arrangementId), for: command)
        case (.saveArrangement, .newArrangement(let value)):
            return await applyWorkspaceAction(
                .createArrangement(tabId: value.tabId, name: value.name), for: command)
        case (.renameArrangement, .renamedArrangement(let value)):
            return await applyWorkspaceAction(
                .renameArrangement(
                    tabId: value.tabId, arrangementId: value.arrangementId, name: value.name),
                for: command
            )
        default:
            return .unsupportedCommand
        }
    }

    // MARK: - Drawer

    func executeDrawerCommand(
        _ command: AppCommand,
        arguments: IPCCommandArguments,
        ownPaneAssertion: WorkspaceOwnPaneAssertion?
    ) async -> AppCommandExecutionOutcome {
        switch arguments {
        case .drawerParent(let value):
            guard let parentPaneId = AppCommandTypedIPCPane.canonicalId(value.parentPaneSelector) else {
                return .stateUnavailable
            }
            return await executeDrawerParentCommand(command, parentPaneId: parentPaneId)
        case .drawerSourcePane(let value):
            guard let parentPaneId = AppCommandTypedIPCPane.canonicalId(value.parentPaneSelector),
                let sourceDrawerPaneId = AppCommandTypedIPCPane.canonicalId(
                    value.sourceDrawerPaneSelector)
            else { return .stateUnavailable }
            return await executeDrawerNeighborFocusCommand(
                command, parentPaneId: parentPaneId, sourceDrawerPaneId: sourceDrawerPaneId)
        case .drawerPane(let value):
            guard let parentPaneId = AppCommandTypedIPCPane.canonicalId(value.parentPaneSelector),
                let drawerPaneId = AppCommandTypedIPCPane.canonicalId(value.drawerPaneSelector)
            else { return .stateUnavailable }
            return await executeDrawerChildCommand(
                command, parentPaneId: parentPaneId, drawerPaneId: drawerPaneId, ownPaneAssertion: ownPaneAssertion)
        case .detachedDrawerPane(let value):
            guard command == .detachDrawerPane,
                let drawerPaneId = AppCommandTypedIPCPane.canonicalId(value.drawerPaneSelector),
                let parentPaneId = store.paneAtom.pane(drawerPaneId)?.parentPaneId
            else { return .stateUnavailable }
            return await applyWorkspaceAction(
                .detachDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId), for: command)
        default:
            return .unsupportedCommand
        }
    }

    private func executeDrawerParentCommand(
        _ command: AppCommand,
        parentPaneId: UUID
    ) async -> AppCommandExecutionOutcome {
        switch command {
        case .enterDrawer:
            return await applyWorkspaceAction(.enterDrawer(parentPaneId: parentPaneId), for: command)
        case .addDrawerPane:
            return await applyWorkspaceAction(.addDrawerPane(parentPaneId: parentPaneId), for: command)
        case .toggleDrawer:
            return await applyWorkspaceAction(.toggleDrawer(paneId: parentPaneId), for: command)
        case .moveZoomDrawerToTerminal, .moveZoomDrawerToBridge:
            guard let side = command.zoomDrawerTargetSide,
                let action = zoomDrawerSideAction(side: side, ownerPaneId: parentPaneId)
            else { return .unavailable(.noApplicableTarget) }
            return await applyWorkspaceAction(action, for: command)
        case .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4,
            .focusDrawerPane5, .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8,
            .focusDrawerPane9:
            guard let ordinal = AppCommand.focusDrawerPaneCommands.firstIndex(of: command).map({ $0 + 1 }),
                let drawerView = arrangementView.drawerView(forParent: parentPaneId),
                let drawerPaneId = PaneOrdinalMap(orderedPaneIds: drawerView.layout.paneIds)
                    .paneId(forOrdinal: ordinal)
            else { return .unavailable(.noApplicableTarget) }
            return await applyWorkspaceAction(
                .setActiveDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId),
                for: command
            )
        default:
            return .unsupportedCommand
        }
    }

    private func executeDrawerNeighborFocusCommand(
        _ command: AppCommand,
        parentPaneId: UUID,
        sourceDrawerPaneId: UUID
    ) async -> AppCommandExecutionOutcome {
        let action: WorkspaceActionCommand
        switch command {
        case .focusDrawerPaneUp:
            action = .focusDrawerPaneUp(parentPaneId: parentPaneId, drawerPaneId: sourceDrawerPaneId)
        case .focusDrawerPaneLeft:
            action = .focusDrawerPaneLeft(parentPaneId: parentPaneId, drawerPaneId: sourceDrawerPaneId)
        case .focusDrawerPaneDown:
            action = .focusDrawerPaneDown(parentPaneId: parentPaneId, drawerPaneId: sourceDrawerPaneId)
        case .focusDrawerPaneRight:
            action = .focusDrawerPaneRight(parentPaneId: parentPaneId, drawerPaneId: sourceDrawerPaneId)
        default:
            return .unsupportedCommand
        }
        return await applyWorkspaceAction(action, for: command)
    }

    private func executeDrawerChildCommand(
        _ command: AppCommand,
        parentPaneId: UUID,
        drawerPaneId: UUID,
        ownPaneAssertion: WorkspaceOwnPaneAssertion?
    ) async -> AppCommandExecutionOutcome {
        switch command {
        case .navigateDrawerPane:
            return await applyWorkspaceAction(
                .setActiveDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId),
                for: command
            )
        case .closeDrawerPane:
            let action = WorkspaceActionCommand.removeDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId)
            guard let ownPaneAssertion else { return await applyWorkspaceAction(action, for: command) }
            switch await executor.execute(action, ownPaneAssertion: ownPaneAssertion) {
            case .applied: return .applied
            case .outsideOwnPane: return .outsideOwnPane
            case .rejected: return headlessIPCOutcome(false, for: command)
            }
        default:
            return .unsupportedCommand
        }
    }

    // MARK: - Management layer

    /// The management-layer owner operates on the layer's current navigation
    /// scope. A typed request names that scope explicitly, so it is admitted
    /// only when the layer is active and already scoped to the named pane;
    /// otherwise the owner is honestly reported as unavailable rather than
    /// silently retargeted.
    func executeManagementLayerCommand(
        _ command: AppCommand,
        arguments: IPCCommandArguments
    ) -> AppCommandExecutionOutcome {
        let requestedPaneId: UUID?
        switch arguments {
        case .managementFromMainPane(let value):
            requestedPaneId = AppCommandTypedIPCPane.canonicalId(value.mainPaneSelector)
        case .managementFromDrawerPane(let value):
            requestedPaneId = AppCommandTypedIPCPane.canonicalId(value.drawerPaneSelector)
        default:
            return .unsupportedCommand
        }
        guard let requestedPaneId else { return .stateUnavailable }
        let scopedPaneId: UUID? =
            switch normalizedWorkspaceNavigationScopeState() {
            case .mainPane(let paneId): paneId
            case .emptyDrawer(let parentPaneId): parentPaneId
            case .drawerPane(_, let paneId): paneId
            }
        guard canExecuteManagementCommand(command), scopedPaneId == requestedPaneId else {
            return .unavailable(.stateUnavailable)
        }
        return headlessIPCOutcome(handleManagementCommand(command), for: command)
    }
}
