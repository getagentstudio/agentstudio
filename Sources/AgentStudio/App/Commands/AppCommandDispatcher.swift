import AgentStudioCommandBar
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioRepoExplorer
import Foundation
import Observation
import os

/// App-owned execution point for keyboard, menu, command-bar, and management commands.
@Observable
@MainActor
final class AppCommandDispatcher: AppCommandDispatching {
    static let shared = AppCommandDispatcher()
    private static let logger = Logger(subsystem: "com.agentstudio", category: "AppCommandDispatcher")

    private(set) var definitions: [AppCommand: AppCommandSpec] = [:]
    weak var handler: WorkspaceCommandHandling?
    weak var appCommandRouter: ShellCommandHandling?
    var interactionProbe: AgentStudioInteractionPerformanceProbe?
    var onCommandRefreshAccepted: (@MainActor (UUID) -> Void)?

    private init() {
        for definition in AppCommand.allCases.map(\.definition) {
            definitions[definition.command] = definition
        }
    }

    @discardableResult
    func dispatch(_ command: AppCommand) -> Bool {
        guard canDispatch(command) else {
            Self.logger.warning("Command dispatch rejected: \(command.rawValue, privacy: .public)")
            return false
        }
        if appCommandRouter?.execute(command) == true {
            return true
        }
        guard let handler, handler.canExecute(command) else {
            Self.logger.warning("Command dispatch had no workspace handler: \(command.rawValue, privacy: .public)")
            return false
        }
        handler.execute(command)
        return true
    }

    func dispatchKeyboardShortcut(_ shortcut: AppShortcut) {
        guard shortcut == .toggleManagementLayer else {
            dispatch(shortcut.command)
            return
        }
        guard canDispatch(shortcut.command) else { return }

        let correlationId = UUIDv7.generate()
        interactionProbe?.beginInteraction(.commandRefresh, correlationId: correlationId)
        onCommandRefreshAccepted?(correlationId)
        dispatch(shortcut.command)
    }

    @discardableResult
    func dispatch(_ request: AppCommandExecutionRequest) -> AppCommandExecutionOutcome {
        guard canDispatch(request) else {
            Self.logger.warning("Command request rejected: \(request.command.rawValue, privacy: .public)")
            return .unsupportedCommand
        }
        guard request.arguments == .noArguments else { return .unsupportedCommand }

        if let appCommandRouter {
            let outcome = appCommandRouter.execute(request)
            if outcome != .unsupportedCommand {
                return outcome
            }
        }
        guard let handler else {
            return .unsupportedCommand
        }
        handler.execute(request.command)
        return .applied
    }

    func dispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) {
        guard
            dispatch(
                command,
                target: target,
                targetType: targetType,
                executionContext: .interactive
            )
        else {
            Self.logger.warning(
                "Targeted command dispatch rejected: \(command.rawValue, privacy: .public) targetType=\(targetType.rawValue, privacy: .public)"
            )
            return
        }
    }

    @discardableResult
    func dispatch(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType,
        executionContext: AppCommandExecutionContext
    ) -> Bool {
        guard
            canDispatch(
                command,
                target: target,
                targetType: targetType,
                executionContext: executionContext
            )
        else {
            return false
        }
        if appCommandRouter?.execute(command, target: target, targetType: targetType) == true {
            return true
        }
        guard let handler else {
            return false
        }
        handler.execute(command, target: target, targetType: targetType)
        return true
    }

    /// Typed `command.execute` delivery. The adapter has already admitted the
    /// command for this channel and canonicalized its identities; this gate
    /// re-checks the projection's exposure, execution mode and target kinds plus
    /// the one current workspace window, then routes to the shell owner before
    /// the workspace owner, exactly as the interactive path does.
    ///
    /// It deliberately does not apply the interactive `canExecute` enablement
    /// validators. Those answer "is this command enabled for the current focus
    /// and selection"; a typed request names its identities explicitly, so
    /// enablement is the owner's own capability check plus
    /// `WorkspaceCommandValidator` inside `WorkspaceActionExecutor`.
    func dispatchHeadlessIPC(_ request: AppCommandExecutionRequest) async -> AppCommandExecutionOutcome {
        guard case .headlessIPC(let admitsDebugTestingCommands) = request.executionContext,
            let arguments = request.typedIPCArguments
        else {
            return .unsupportedCommand
        }
        guard let definition = definitions[request.command],
            Self.supportsHeadlessIPCDispatch(
                definition: definition,
                admitsDebugTestingCommands: admitsDebugTestingCommands,
                targetType: arguments.durableTarget?.type
            )
        else {
            return .unsupportedCommand
        }
        if let workspaceWindowId = arguments.workspaceWindowId {
            let shellOwnsWindow = appCommandRouter?.ownsWorkspaceWindow(workspaceWindowId) ?? false
            let handlerOwnsWindow = handler?.ownsWorkspaceWindow(workspaceWindowId) ?? false
            guard shellOwnsWindow || handlerOwnsWindow else { return .stateUnavailable }
        }
        if let outcome = appCommandRouter?.execute(request), outcome != .unsupportedCommand {
            return outcome
        }
        guard let handler else { return .stateUnavailable }
        return await handler.executeHeadlessIPC(request)
    }

    /// The projection decides what a channel may reach. Stable and beta keep
    /// the admitted headless commands; debug additionally reaches interactive
    /// and presentation-only commands through their typed variants.
    static func supportsHeadlessIPCDispatch(
        definition: AppCommandSpec,
        admitsDebugTestingCommands: Bool,
        targetType: SearchItemType?
    ) -> Bool {
        let ipcSpec = definition.command.ipcSpec
        switch ipcSpec.exposure {
        case .allChannels:
            break
        case .debugTesting:
            guard admitsDebugTestingCommands else { return false }
        }
        guard ipcSpec.executionMode == .headless || admitsDebugTestingCommands else { return false }
        guard let targetType else { return true }
        guard let targetKind = ipcHandleKind(for: targetType) else { return true }
        return ipcSpec.allowedTargetKinds.contains(targetKind)
    }

    func dispatchExtractPaneToTab(tabId: UUID, paneId: UUID, targetTabInsertionIndex: Int?) {
        guard canDispatch(.extractPaneToTab) else { return }
        handler?.executeExtractPaneToTab(
            tabId: tabId,
            paneId: paneId,
            targetTabInsertionIndex: targetTabInsertionIndex
        )
    }

    func dispatchMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID) {
        guard let definition = definitions[.movePaneToTab],
            definition.targeting.supports(targetType: .pane),
            definition.targeting.supports(targetType: .tab),
            canDispatch(.movePaneToTab, target: sourcePaneId, targetType: .pane)
        else {
            return
        }
        handler?.executeMovePaneToTab(
            sourcePaneId: sourcePaneId,
            sourceTabId: sourceTabId,
            targetTabId: targetTabId
        )
    }

    /// Creation carries a typed request, so it bypasses the parameterless `execute`
    /// path and goes straight to the shell owner after the targeted preflight.
    @discardableResult
    func dispatchWorktreeCreation(_ request: WorktreeCreationRequest) -> Bool {
        let command = request.kind.command
        guard canDispatch(command, target: request.targetId, targetType: request.targetType) else {
            Self.logger.warning("Worktree creation dispatch rejected: \(command.rawValue, privacy: .public)")
            return false
        }
        switch appCommandRouter?.executeWorktreeCreation(request) {
        case .accepted, .applied:
            return true
        case .presented, .unavailable, .stateUnavailable, .unsupportedCommand, .outsideOwnPane, nil:
            return false
        }
    }

    func dispatchQuickOpenDirectory(
        _ directory: URL,
        placement: QuickOpenDirectoryPlacement
    ) {
        guard let handler else {
            Self.logger.warning("Quick Open directory dispatch had no workspace handler")
            return
        }
        handler.executeQuickOpenDirectory(directory, placement: placement)
    }

    func canDispatch(_ command: AppCommand) -> Bool {
        guard let definition = definitions[command],
            definition.targeting.supportsContextualInvocation
        else {
            return false
        }
        return canExecutionOwnersExecute(command, definition: definition)
    }

    func canDispatch(_ request: AppCommandExecutionRequest) -> Bool {
        guard let definition = definitions[request.command],
            definition.targeting.supportsContextualInvocation
        else {
            return false
        }
        guard request.arguments != .noArguments else {
            return canDispatch(request.command)
        }
        if definition.requiresManagementLayer,
            !atom(\.managementLayer).isActive
        {
            return false
        }
        return appCommandRouter?.canExecute(request) ?? false
    }

    func canDispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        canDispatch(
            command,
            target: target,
            targetType: targetType,
            executionContext: .interactive
        )
    }

    func canDispatch(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType,
        executionContext: AppCommandExecutionContext
    ) -> Bool {
        guard let definition = definitions[command],
            Self.supportsTargetedDispatch(
                definition: definition,
                executionContext: executionContext,
                targetType: targetType
            )
        else {
            return false
        }
        return canExecutionOwnersExecute(
            command,
            definition: definition,
            target: target,
            targetType: targetType
        )
    }

    static func supportsTargetedDispatch(
        definition: AppCommandSpec,
        executionContext: AppCommandExecutionContext,
        targetType: SearchItemType
    ) -> Bool {
        switch executionContext {
        case .interactive:
            return definition.targeting.supports(targetType: targetType)
        case .headlessIPC(let admitsDebugTestingCommands):
            return supportsHeadlessIPCDispatch(
                definition: definition,
                admitsDebugTestingCommands: admitsDebugTestingCommands,
                targetType: targetType
            )
        }
    }

    private static func ipcHandleKind(for targetType: SearchItemType) -> IPCHandleKind? {
        switch targetType {
        case .repo:
            .repo
        case .tab:
            .tab
        case .pane:
            .pane
        case .worktree, .floatingTerminal:
            nil
        }
    }

    private func canExecutionOwnersExecute(
        _ command: AppCommand,
        definition: AppCommandSpec,
        target: UUID,
        targetType: SearchItemType
    ) -> Bool {
        if definition.requiresManagementLayer,
            !atom(\.managementLayer).isActive
        {
            return false
        }
        let appCanExecute = appCommandRouter?.canExecute(command, target: target, targetType: targetType) ?? false
        let handlerCanExecute = handler?.canExecute(command, target: target, targetType: targetType) ?? false
        return appCanExecute || handlerCanExecute
    }

    func bridgePaneCommandTarget(worktreeId: UUID) -> BridgePaneCommandTarget? {
        handler?.bridgePaneCommandTarget(worktreeId: worktreeId)
    }

    func definition(for command: AppCommand) -> AppCommandSpec {
        guard let definition = definitions[command] else {
            fatalError("Missing command spec for \(command.rawValue)")
        }
        return definition
    }

    func commands(for itemType: SearchItemType) -> [AppCommandSpec] {
        definitions.values.filter { $0.targeting.supports(targetType: itemType) }
    }

    func repoExplorerCommandPresentationSnapshot(
        requests: Set<RepoExplorerCommandPresentationRequest>,
        generation: UInt64
    ) -> RepoExplorerCommandPresentationSnapshot {
        let handlerCapabilities = handler?.repoExplorerCommandCapabilities(requests) ?? [:]
        var results: [RepoExplorerCommandPresentationRequest: Bool] = [:]
        results.reserveCapacity(requests.count)

        for request in requests {
            guard let definition = definitions[request.command] else { continue }
            let presentationQuery: AppCommandPresentationQuery
            if let targetType = request.targetType {
                guard request.target != nil else { continue }
                presentationQuery = AppCommandPresentationQuery(
                    surface: request.surface,
                    subject: .targeted(targetType)
                )
            } else {
                guard request.target == nil else { continue }
                presentationQuery = AppCommandPresentationQuery(
                    surface: request.surface,
                    subject: .contextual(.empty)
                )
            }
            guard definition.shouldPresent(presentationQuery) else { continue }
            guard !definition.requiresManagementLayer || atom(\.managementLayer).isActive else {
                results[request] = false
                continue
            }

            let appCanExecute: Bool
            switch request.arguments {
            case .noArguments:
                if let target = request.target, let targetType = request.targetType {
                    appCanExecute =
                        appCommandRouter?.canExecute(
                            request.command,
                            target: target,
                            targetType: targetType
                        ) ?? false
                } else {
                    appCanExecute = appCommandRouter?.canExecute(request.command) ?? false
                }
            }
            results[request] = appCanExecute || (handlerCapabilities[request] ?? false)
        }

        return RepoExplorerCommandPresentationSnapshot(
            generation: generation,
            results: results
        )
    }

    private func canExecutionOwnersExecute(
        _ command: AppCommand,
        definition: AppCommandSpec
    ) -> Bool {
        if definition.requiresManagementLayer,
            !atom(\.managementLayer).isActive
        {
            return false
        }
        let appCanExecute = appCommandRouter?.canExecute(command) ?? false
        let handlerCanExecute = handler?.canExecute(command) ?? false
        return appCanExecute || handlerCanExecute
    }
}
