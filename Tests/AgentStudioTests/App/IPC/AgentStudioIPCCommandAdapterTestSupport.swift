import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

@testable import AgentStudio
@testable import AgentStudioCore

/// Shared harness for typed `command.execute` tests. It selects fixed shell and
/// workspace owners, creates one real dispatcher, and passes that dispatcher
/// into the adapter before any request is executed.
@MainActor
struct CommandAdapterHarness {
    /// Selects dispatcher shell access; the adapter's shell reference remains
    /// present for workspace-window authorization even when dispatch omits it.
    enum DispatcherShellOwnerAccess {
        case adapterWindowOwner
        case absent
    }

    let adapter: AgentStudioIPCCommandAdapter
    let commandDispatcher: AppCommandDispatcher
    let workspaceStore: WorkspaceStore
    let windowId: UUID
    let channel: AgentStudioIPCChannel
    let shellCommandHandler: RecordingShellCommandHandler

    init(
        windowId: UUID = UUIDv7.generate(),
        channel: AgentStudioIPCChannel = .stable,
        targetAuthorizer: (any WorkspaceDurableTargetAuthorizing)? = nil,
        shellCommandHandler: RecordingShellCommandHandler = RecordingShellCommandHandler(),
        workspaceCommandHandler: (any WorkspaceCommandHandling)? = nil,
        dispatcherShellOwnerAccess: DispatcherShellOwnerAccess = .adapterWindowOwner
    ) {
        workspaceStore = WorkspaceStore()
        self.windowId = windowId
        self.channel = channel
        self.shellCommandHandler = shellCommandHandler
        if shellCommandHandler.currentWindowId == nil {
            shellCommandHandler.currentWindowId = windowId
        }
        let selectedDispatcherShellOwner: (any ShellCommandHandling)?
        switch dispatcherShellOwnerAccess {
        case .adapterWindowOwner:
            selectedDispatcherShellOwner = shellCommandHandler
        case .absent:
            selectedDispatcherShellOwner = nil
        }
        let selectedWorkspaceOwner = workspaceCommandHandler
        let commandDispatcher = AppCommandDispatcher(
            dependencies: .init(
                shellOwnerAccess: { selectedDispatcherShellOwner },
                workspaceOwnerAccess: { selectedWorkspaceOwner },
                interactionProbeAccess: { nil },
                commandRefreshAccepted: { _ in }
            )
        )
        self.commandDispatcher = commandDispatcher
        adapter = AgentStudioIPCCommandAdapter(
            workspaceId: workspaceStore.identityAtom.workspaceId,
            channel: channel,
            targetAuthorizer: targetAuthorizer
                ?? WorkspaceDurableTargetAuthorizationPort(workspaceStore: workspaceStore),
            shellCommandHandler: shellCommandHandler,
            commandDispatcher: commandDispatcher
        )
    }
}

@MainActor
final class RecordingShellCommandHandler: ShellCommandHandling {
    var handledRequests: [AppCommandExecutionRequest] = []
    var currentWindowId: UUID?
    /// Outcome for any command this fake shell claims. Tests that want the
    /// workspace owner to receive the request set this to `.unsupportedCommand`.
    var defaultOutcome: AppCommandExecutionOutcome = .applied
    var outcomeByCommand: [AppCommand: AppCommandExecutionOutcome] = [:]

    init(currentWindowId: UUID? = nil) {
        self.currentWindowId = currentWindowId
    }

    func ownsWorkspaceWindow(_ workspaceWindowId: UUID) -> Bool {
        currentWindowId == workspaceWindowId
    }

    func canExecute(_: AppCommand) -> Bool { true }
    func canExecute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { true }
    func execute(_: AppCommand) -> Bool { false }
    func execute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }

    func execute(_ request: AppCommandExecutionRequest) -> AppCommandExecutionOutcome {
        handledRequests.append(request)
        return outcomeByCommand[request.command] ?? defaultOutcome
    }

    func showRepoCommandBar() {}
    func refreshWorktrees() {}
    func refocusActivePane() {}
}

/// Records the exact typed request a workspace owner received and reports the
/// strongest boundary the projection lets the command advertise, so adapter
/// tests assert owner arguments rather than a handler count.
@MainActor
final class RecordingWorkspaceIPCCommandHandler: WorkspaceCommandHandling {
    private(set) var headlessRequests: [AppCommandExecutionRequest] = []
    var currentWindowId: UUID?
    var refusesEveryCommand = false

    init(currentWindowId: UUID? = nil) {
        self.currentWindowId = currentWindowId
    }

    func ownsWorkspaceWindow(_ workspaceWindowId: UUID) -> Bool {
        currentWindowId == nil || currentWindowId == workspaceWindowId
    }

    func execute(_: AppCommand) {}
    func execute(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canExecute(_: AppCommand) -> Bool { true }
    func canExecute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { true }
    func executeExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}
    func executeMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}

    func executeHeadlessIPC(_ request: AppCommandExecutionRequest) async -> AppCommandExecutionOutcome {
        headlessRequests.append(request)
        if refusesEveryCommand { return .stateUnavailable }
        return Self.declaredOutcome(for: request.command)
    }

    /// The first boundary `AppCommand.ipcSpec` declares. The adapter must accept
    /// it unchanged, so a mismatch is a real projection or mapping defect.
    static func declaredOutcome(for command: AppCommand) -> AppCommandExecutionOutcome {
        switch command.ipcSpec.resultVariants.first {
        case .accepted: .accepted(operationId: nil)
        case .presented: .presented
        case .unavailable: .unavailable(.featureUnavailable)
        default: .applied
        }
    }
}

@MainActor
func makeIPCCommandCatalogOffMain(
    from adapter: AgentStudioIPCCommandAdapter,
    channel: AgentStudioIPCChannel = .stable
) async throws -> IPCCommandCatalogResult {
    try await makeIPCCommandCompositionOffMain(from: adapter, channel: channel).catalogResult
}

@MainActor
func makeIPCCommandCompositionOffMain(
    from adapter: AgentStudioIPCCommandAdapter,
    channel: AgentStudioIPCChannel = .stable
) async throws -> IPCCommandMethodComposition {
    let buildDescriptorCatalog:
        @Sendable (AppIPCDescriptorCatalogBuildInputs) async throws -> AppIPCDescriptorCatalogBuildResult =
            AppIPCDescriptorCatalogBuilder.buildOffMain
    let result = try await buildDescriptorCatalog(
        AppIPCDescriptorCatalogBuildInputs(
            builtInCatalogInputs: appIPCTestBuiltInMethodCatalogInputs(),
            channel: channel,
            commandCatalogProjectionInputs: adapter.commandCatalogProjectionInputs()
        ))
    return result.commandComposition
}

private func appIPCTestBuiltInMethodCatalogInputs() -> IPCBuiltInMethodCatalogInputs {
    IPCBuiltInMethodCatalogInputs(
        relationships: IPCBuiltInMethodRelationshipInputs(
            paneFocus: .appCommand(identifier: AppCommand.focusPane.rawValue),
            paneClose: .appCommand(identifier: AppCommand.closePane.rawValue),
            drawerToggle: .appCommand(identifier: AppCommand.toggleDrawer.rawValue),
            drawerAddPane: .appCommand(identifier: AppCommand.addDrawerPane.rawValue),
            bridgeDiffLoad: .appCommand(identifier: AppCommand.showBridgeReview.rawValue),
            bridgeFileViewOpen: .appCommand(identifier: AppCommand.showBridgeFiles.rawValue)
        ),
        examples: .init(illustrativeIdentifier: UUIDv7.generate())
    )
}

func commandAdapterTestPrincipal() -> IPCPrincipal {
    IPCPrincipal(
        principalId: UUIDv7.generate(),
        runtimeId: UUIDv7.generate(),
        accessMode: .unsafeDebug,
        kind: .unsafeDebugClient,
        approvalAuthority: .noApprovalAuthority
    )
}

let retiredPanesOrganizationCommands: [AppCommand] = [
    .setPanesSortFieldName,
    .setPanesSortFieldActivity,
    .togglePanesSortDirection,
]

/// Runs the raw adapter body with its already-owned command dispatcher.
@MainActor
func withRawCommandAdapterDispatcher<Output>(
    harness: CommandAdapterHarness, body: @MainActor () async throws -> Output
) async throws -> Output {
    _ = harness.commandDispatcher
    return try await body()
}

@MainActor
func rawCommandOwnerArguments(from harness: CommandAdapterHarness) -> [IPCCommandArguments] {
    harness.shellCommandHandler.handledRequests.compactMap { request in
        guard case .typedIPC(let arguments) = request.arguments else { return nil }
        return arguments
    }
}
