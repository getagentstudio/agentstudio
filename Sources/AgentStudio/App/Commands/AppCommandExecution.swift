import AgentStudioCommandBar
import AgentStudioCore
import AgentStudioProgrammaticControl
import AgentStudioRepoExplorer
import Foundation

/// Protocol for objects that execute commands against the active workspace.
@MainActor
protocol WorkspaceCommandHandling: AnyObject {
    func ownsWorkspaceWindow(_ workspaceWindowId: UUID) -> Bool
    func execute(_ command: AppCommand)
    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType)
    func executeHeadlessIPC(_ request: AppCommandExecutionRequest) async -> AppCommandExecutionOutcome
    func canExecute(_ command: AppCommand) -> Bool
    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool
    func bridgePaneCommandTarget(worktreeId: UUID) -> BridgePaneCommandTarget?
    func executeExtractPaneToTab(tabId: UUID, paneId: UUID, targetTabInsertionIndex: Int?)
    func executeMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID)
    func executeQuickOpenDirectory(_ directory: URL, placement: QuickOpenDirectoryPlacement)
    func repoExplorerCommandCapabilities(
        _ requests: Set<RepoExplorerCommandPresentationRequest>
    ) -> [RepoExplorerCommandPresentationRequest: Bool]
}

/// Routes app-level commands that do not belong to the workspace command handler.
@MainActor
protocol ShellCommandHandling: AnyObject {
    func ownsWorkspaceWindow(_ workspaceWindowId: UUID) -> Bool
    func canExecute(_ command: AppCommand) -> Bool
    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool
    func canExecute(_ request: AppCommandExecutionRequest) -> Bool
    func execute(_ command: AppCommand) -> Bool
    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool
    func execute(_ request: AppCommandExecutionRequest) -> AppCommandExecutionOutcome
    /// Argument-bearing interactive creation. Acceptance means the creation owner
    /// took the request; publication in topology follows only after the SDK returns.
    func executeWorktreeCreation(_ request: WorktreeCreationRequest) -> AppCommandExecutionOutcome
    func showRepoCommandBar()
    func refreshWorktrees()
    func refocusActivePane()
}

extension ShellCommandHandling {
    func canExecute(_ request: AppCommandExecutionRequest) -> Bool {
        guard request.arguments == .noArguments else { return false }
        return canExecute(request.command)
    }
}

struct AppCommandExecutionRequest: Equatable, Sendable {
    let command: AppCommand
    let arguments: AppCommandExecutionArguments
    let executionContext: AppCommandExecutionContext
    /// Set when a pane agent requested the command, so the owner re-checks at
    /// effect time that every pane it touches is still in the agent's own pane.
    let ownPaneAssertion: WorkspaceOwnPaneAssertion?

    init(
        command: AppCommand,
        arguments: AppCommandExecutionArguments = .noArguments,
        executionContext: AppCommandExecutionContext = .interactive,
        ownPaneAssertion: WorkspaceOwnPaneAssertion? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.executionContext = executionContext
        self.ownPaneAssertion = ownPaneAssertion
    }
}

enum AppCommandExecutionContext: Equatable, Sendable {
    case interactive
    /// Typed `command.execute` delivery. `admitsDebugTestingCommands` is true
    /// only on the debug server channel; stable and beta keep the admitted
    /// headless commands the projection marks `.allChannels`.
    case headlessIPC(admitsDebugTestingCommands: Bool)
}

enum AppCommandExecutionArguments: Equatable, Sendable {
    case noArguments
    /// Canonical typed IPC arguments. Pane selectors are already resolved to
    /// stored canonical UUIDs before an owner sees them.
    case typedIPC(IPCCommandArguments)
}

/// The truthful boundary a command owner reached. Owners never report a
/// stronger boundary than they observed: presentation is not completion and a
/// scheduled workspace effect is acceptance, not application.
enum AppCommandExecutionOutcome: Equatable, Sendable {
    case applied
    case accepted(operationId: UUID?)
    case presented
    case unavailable(IPCCommandUnavailableReason)
    case stateUnavailable
    case unsupportedCommand
    /// A pane agent's target left its own pane before the effect applied.
    case outsideOwnPane
}

@MainActor
extension WorkspaceCommandHandling {
    func ownsWorkspaceWindow(_: UUID) -> Bool { false }

    /// Fail closed. An owner opts in per command family; it never inherits a
    /// silent success from this protocol.
    func executeHeadlessIPC(_: AppCommandExecutionRequest) async -> AppCommandExecutionOutcome {
        .unsupportedCommand
    }

    func repoExplorerCommandCapabilities(
        _ requests: Set<RepoExplorerCommandPresentationRequest>
    ) -> [RepoExplorerCommandPresentationRequest: Bool] {
        Dictionary(
            uniqueKeysWithValues: requests.map { request in
                let isEnabled: Bool
                if let target = request.target, let targetType = request.targetType {
                    isEnabled = canExecute(request.command, target: target, targetType: targetType)
                } else {
                    isEnabled = canExecute(request.command)
                }
                return (request, isEnabled)
            })
    }

    func canExecute(_ command: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool {
        canExecute(command)
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func executeQuickOpenDirectory(_: URL, placement _: QuickOpenDirectoryPlacement) {}
}

@MainActor
extension ShellCommandHandling {
    func ownsWorkspaceWindow(_: UUID) -> Bool { false }

    /// Fail closed. Only an owner that installs a creation coordinator accepts.
    func executeWorktreeCreation(_: WorktreeCreationRequest) -> AppCommandExecutionOutcome {
        .unsupportedCommand
    }

    func canExecute(_ command: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool {
        canExecute(command)
    }

    func execute(_ request: AppCommandExecutionRequest) -> AppCommandExecutionOutcome {
        switch request.arguments {
        case .noArguments:
            return execute(request.command) ? .applied : .unsupportedCommand
        case .typedIPC:
            return .unsupportedCommand
        }
    }
}
