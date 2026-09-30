import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

@MainActor
protocol WorkspaceDurableTargetAuthorizing: AnyObject {
    func containsRepository(id: UUID) -> Bool
    func containsTab(id: UUID) -> Bool
    func containsPane(id: UUID) -> Bool
    func containsWorktree(id: UUID) -> Bool
    func containsArrangement(tabId: UUID, arrangementId: UUID) -> Bool
}

/// The typed `command.execute` port. It owns no command identity and no owner
/// logic: `AppCommand.ipcSpec` decides exposure, argument variants and the
/// result boundaries a command may report, and `AppCommandDispatcher` routes
/// every request to the existing interactive owner.
@MainActor
struct AgentStudioIPCCommandAdapter: AppIPCCommandPort, @unchecked Sendable {
    private let channel: AgentStudioIPCChannel
    private let targetResolver: AgentStudioIPCCommandTargetResolver
    private weak var shellCommandHandler: (any ShellCommandHandling)?

    init(
        workspaceId: UUID,
        channel: AgentStudioIPCChannel,
        targetAuthorizer: any WorkspaceDurableTargetAuthorizing,
        shellCommandHandler: any ShellCommandHandling
    ) {
        self.channel = channel
        self.shellCommandHandler = shellCommandHandler
        targetResolver = AgentStudioIPCCommandTargetResolver(
            workspaceId: workspaceId,
            targetAuthorizer: targetAuthorizer,
            ownsWorkspaceWindow: { [weak shellCommandHandler] workspaceWindowId in
                shellCommandHandler?.ownsWorkspaceWindow(workspaceWindowId) ?? false
            }
        )
    }

    func commandCatalogProjectionInputs() -> AppIPCCommandCatalogProjectionInputs {
        AgentStudioIPCCommandCatalogProjection.captureBuildInputs(on: channel)
    }

    func prepareCommand(
        _ request: IPCCommandExecutionRequest,
        principal _: IPCPrincipal,
        tools: AppIPCTargetResolutionTools
    ) async throws -> AppIPCPreparedCommand {
        let command = try activeCommand(for: request)
        let resolved = try await targetResolver.resolve(request.arguments, tools: tools)
        let privilege = command.ipcSpec.requiredPrivilege
        return AppIPCPreparedCommand(
            request: IPCCommandExecutionRequest(
                commandId: request.commandId,
                correlationId: request.correlationId,
                arguments: resolved.arguments
            ),
            canonicalHandle: resolved.handle,
            target: resolved.target,
            requiredScopes: [
                IPCPermissionScope(
                    privilege: privilege,
                    target: resolved.target,
                    dataScope: PermissionScopeCanonicalizer.dataScope(for: privilege)
                )
            ],
            resolvedPaneIds: resolved.paneIds,
            agentArgumentRule: Self.agentArgumentRule(for: command, arguments: resolved.arguments)
        )
    }

    /// Commands whose effect, not only their target, decides agent admission.
    private static func agentArgumentRule(
        for command: AppCommand,
        arguments: IPCCommandArguments
    ) -> AppIPCAgentArgumentRule {
        switch (command, arguments) {
        case (.closeDrawerPane, .drawerPane(let value)):
            AppCommandTypedIPCPane.canonicalId(value.drawerPaneSelector).map(AppIPCAgentArgumentRule.closesPane)
                ?? .targetOnly
        default:
            .targetOnly
        }
    }

    func executeCommand(
        _ request: IPCCommandExecutionRequest,
        ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) async throws -> IPCCommandExecutionResult {
        let command = try activeCommand(for: request)
        guard shellCommandHandler != nil else { throw AppIPCCommandError(reason: .stateUnavailable) }
        try targetResolver.validateForExecution(request.arguments)

        let outcome = await AppCommandDispatcher.shared.dispatchHeadlessIPC(
            AppCommandExecutionRequest(
                command: command,
                arguments: .typedIPC(request.arguments),
                executionContext: .headlessIPC(admitsDebugTestingCommands: channel == .debug),
                ownPaneAssertion: ownPaneAssertion.map { WorkspaceOwnPaneAssertion(boundPaneId: $0.boundPaneId) }
            )
        )
        return try makeResult(command: command, request: request, outcome: outcome)
    }

    private func activeCommand(for request: IPCCommandExecutionRequest) throws -> AppCommand {
        guard let command = AppCommand(rawValue: request.commandId.rawValue) else {
            throw AppIPCCommandError(reason: .unknownCommand)
        }
        guard AgentStudioIPCCommandCatalogProjection.admitsCommand(command, on: channel) else {
            throw AppIPCCommandError(reason: .unsupportedCommand)
        }
        guard command.ipcSpec.argumentVariants.contains(request.arguments.variant) else {
            throw IPCSchemaValidationError(
                fieldPath: "$.arguments.kind",
                reason: .invalidValue,
                expected: "one argument variant declared by the selected command"
            )
        }
        return command
    }

    /// Owners report the boundary they reached; the projection decides which
    /// boundaries a command may advertise. An owner outcome the projection does
    /// not declare is a state failure, never a stronger receipt.
    private func makeResult(
        command: AppCommand,
        request: IPCCommandExecutionRequest,
        outcome: AppCommandExecutionOutcome
    ) throws -> IPCCommandExecutionResult {
        let commandId = request.commandId
        let correlationId = request.correlationId
        let declared = command.ipcSpec.resultVariants
        switch outcome {
        case .applied where declared.contains(.applied):
            return .applied(.init(commandId: commandId, correlationId: correlationId))
        case .accepted(let operationId) where declared.contains(.accepted):
            return .accepted(
                .init(commandId: commandId, correlationId: correlationId, operationId: operationId))
        case .presented where declared.contains(.presented):
            return .presented(.init(commandId: commandId, correlationId: correlationId))
        case .unavailable(let reason) where declared.contains(.unavailable):
            return .unavailable(.init(commandId: commandId, correlationId: correlationId, reason: reason))
        case .unsupportedCommand:
            throw AppIPCCommandError(reason: .unsupportedCommand)
        case .outsideOwnPane:
            throw AuthorizationError.notYetAllowed(command.rawValue)
        case .applied, .accepted, .presented, .unavailable, .stateUnavailable:
            throw AppIPCCommandError(reason: .stateUnavailable)
        }
    }
}
