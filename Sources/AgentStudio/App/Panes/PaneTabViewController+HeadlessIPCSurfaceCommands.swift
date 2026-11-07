import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

/// Typed `command.execute` delivery for the worktree, terminal-creation,
/// floating-terminal, webview and Bridge surface families. Picker-backed
/// commands take the selection the wire named; none of them open a picker and
/// assume a choice.
extension PaneTabViewController {
    func executeWorkspaceSurfaceCommand(
        _ command: AppCommand,
        arguments: IPCCommandArguments
    ) async -> AppCommandExecutionOutcome {
        switch arguments {
        case .worktree(let value):
            return await executeWorktreeCommand(command, worktreeId: value.worktreeId)
        case .worktreeInPane(let value):
            return await executeWorktreeInPaneCommand(command, arguments: value)
        case .terminalFromWorktree(let value):
            guard command == .openNewTerminalInTab else { return .unsupportedCommand }
            return await applyWorkspaceAction(
                .openNewTerminalInTab(
                    worktreeId: value.worktreeId,
                    launchDirectory: AppCommandTypedIPCPane.launchDirectory(value.launchDirectory),
                    title: value.title
                ),
                for: command
            )
        case .terminalFromPane(let value):
            return await executeTerminalFromPaneCommand(command, arguments: value)
        case .floatingTerminal(let value):
            guard command == .newFloatingTerminal else { return .unsupportedCommand }
            return await applyWorkspaceAction(
                .openFloatingTerminal(
                    launchDirectory: AppCommandTypedIPCPane.launchDirectory(value.launchDirectory),
                    title: value.title
                ),
                for: command
            )
        case .webview(let value):
            return await executeWebviewCommand(command, url: value.url)
        default:
            return .unsupportedCommand
        }
    }

    private func executeWorktreeCommand(
        _ command: AppCommand,
        worktreeId: UUID
    ) async -> AppCommandExecutionOutcome {
        switch command {
        case .openWorktree:
            return await applyWorkspaceAction(.openWorktree(worktreeId: worktreeId), for: command)
        case .showBridgeReview, .showBridgeFiles, .openBridgeReviewInNewTab, .openBridgeFilesInNewTab:
            let applied = await dispatchGesture { [self] execute in
                await executeBridgeSurfaceCommandAfterAdmission(
                    command,
                    worktreeId: worktreeId,
                    execute: execute
                )
            }.value
            guard applied else {
                return .stateUnavailable
            }
            // The Bridge surface mount starts here and finishes once the web
            // product reports its content, so this receipt is acceptance.
            return .accepted(operationId: nil)
        default:
            return .unsupportedCommand
        }
    }

    private func executeWorktreeInPaneCommand(
        _ command: AppCommand,
        arguments: IPCWorktreeInPaneCommandArguments
    ) async -> AppCommandExecutionOutcome {
        guard command == .openWorktreeInPane,
            let paneId = AppCommandTypedIPCPane.canonicalId(arguments.targetPaneSelector)
        else { return .unsupportedCommand }
        guard let action = paneTerminalCreationAction(command: command, paneId: paneId) else {
            return .stateUnavailable
        }
        return await applyWorkspaceAction(action, for: command)
    }

    private func executeTerminalFromPaneCommand(
        _ command: AppCommand,
        arguments: IPCTerminalFromPaneCommandArguments
    ) async -> AppCommandExecutionOutcome {
        guard command == .openNewTerminalInTab,
            let paneId = AppCommandTypedIPCPane.canonicalId(arguments.sourcePaneSelector)
        else { return .unsupportedCommand }
        let overrideDirectory = AppCommandTypedIPCPane.launchDirectory(arguments.launchDirectory)
        guard
            let action = paneTerminalCreationAction(command: command, paneId: paneId)
        else { return .stateUnavailable }
        return await applyWorkspaceAction(
            Self.terminalCreationAction(action, launchDirectory: overrideDirectory, title: arguments.title),
            for: command
        )
    }

    /// Apply the explicit launch directory and title the wire supplied, keeping
    /// the owner's derived worktree association intact.
    private static func terminalCreationAction(
        _ action: WorkspaceActionCommand,
        launchDirectory: URL?,
        title: String?
    ) -> WorkspaceActionCommand {
        switch action {
        case .openNewTerminalInTab(let worktreeId, let derivedDirectory, let derivedTitle):
            return .openNewTerminalInTab(
                worktreeId: worktreeId,
                launchDirectory: launchDirectory ?? derivedDirectory,
                title: title ?? derivedTitle
            )
        case .openFloatingTerminal(let derivedDirectory, let derivedTitle):
            return .openFloatingTerminal(
                launchDirectory: launchDirectory ?? derivedDirectory,
                title: title ?? derivedTitle
            )
        default:
            return action
        }
    }

    private func executeWebviewCommand(
        _ command: AppCommand,
        url: String
    ) async -> AppCommandExecutionOutcome {
        guard command == .openWebview else { return .unsupportedCommand }
        guard let webviewURL = URL(string: url), webviewURL.scheme != nil else {
            return .stateUnavailable
        }
        guard canExecute(.openWebview) else { return .stateUnavailable }
        guard case .opened = await executor.openWebview(url: webviewURL, afterOpen: focusBrowserOpenedByPerson).value
        else {
            return headlessIPCOutcome(false, for: command)
        }
        return headlessIPCOutcome(true, for: command)
    }
}
