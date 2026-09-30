import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

/// Projects the exhaustive `AppCommand.ipcSpec` classification into the typed
/// `command.list` catalog for one server channel. It owns no command identity:
/// exposure, argument variants and result variants all come from the projection.
enum AgentStudioIPCCommandCatalogProjection {
    /// Commands the given channel admits. Stable and beta keep only the
    /// all-channel headless commands; debug additionally admits every
    /// `debugTesting` command.
    static func admitsCommand(_ command: AppCommand, on channel: AgentStudioIPCChannel) -> Bool {
        switch command.ipcSpec.exposure {
        case .allChannels:
            true
        case .debugTesting:
            channel == .debug
        }
    }

    static func admittedCommands(on channel: AgentStudioIPCChannel) -> [AppCommand] {
        AppCommand.allCases.filter { admitsCommand($0, on: channel) }
    }

    /// Captures only the admitted commands' immutable IPC spec values on
    /// MainActor. Example generation and descriptor/schema work happen in
    /// `AppIPCDescriptorCatalogBuilder.buildOffMain`.
    static func captureBuildInputs(on channel: AgentStudioIPCChannel) -> AppIPCCommandCatalogProjectionInputs {
        let commandDescriptorInputs = admittedCommands(on: channel).map { command in
            command.ipcSpec.descriptorInput(definition: command.definition, examples: [])
        }
        return AppIPCCommandCatalogProjectionInputs(
            commandDescriptorInputs: commandDescriptorInputs,
            recognizedCommands: recognizedCommands,
            recognizedUnexposedCommands: recognizedUnexposedCommands(on: channel)
        )
    }

    /// Every command on every channel, with its exposure and agent
    /// eligibility, so the registry can refuse a pane agent by command name.
    static var recognizedCommands: [AppIPCRecognizedEntry] {
        AppCommand.allCases.map {
            AppIPCRecognizedEntry(
                name: $0.rawValue,
                exposure: $0.ipcSpec.exposure,
                agentEligibility: $0.ipcSpec.agentEligibility
            )
        }
    }

    /// Commands this build recognizes that the channel hides, for discovery.
    static func recognizedUnexposedCommands(on channel: AgentStudioIPCChannel) -> [IPCRecognizedUnexposedName] {
        AppCommand.allCases.filter { !admitsCommand($0, on: channel) }.map {
            IPCRecognizedUnexposedName(name: $0.rawValue, agentEligibility: $0.ipcSpec.agentEligibility)
        }
    }

    static func makeDescriptor(from capturedInput: IPCCommandDescriptorInput) throws -> IPCCommandDescriptor {
        let examples = try capturedInput.argumentVariants.map { variant in
            let request = try exampleRequest(commandIdentifier: capturedInput.id, variant: variant)
            return IPCCommandExample(
                description: "Execute with explicit typed \(variant.rawValue) context.",
                request: request,
                result: exampleResult(for: capturedInput.resultVariants, request: request)
            )
        }
        return try IPCCommandDescriptorFactory.make(
            IPCCommandDescriptorInput(
                id: capturedInput.id,
                title: capturedInput.title,
                description: capturedInput.description,
                exposure: capturedInput.exposure,
                executionMode: capturedInput.executionMode,
                argumentVariants: capturedInput.argumentVariants,
                requiredPrivileges: capturedInput.requiredPrivileges,
                dataScope: capturedInput.dataScope,
                allowedTargetKinds: capturedInput.allowedTargetKinds,
                resultVariants: capturedInput.resultVariants,
                examples: examples,
                agentEligibility: capturedInput.agentEligibility
            )
        )
    }

    static func exampleResult(
        for resultVariants: [IPCCommandResultVariant],
        request: IPCCommandExecutionRequest
    ) -> IPCCommandExecutionResult {
        let commandId = request.commandId
        let correlationId = request.correlationId
        switch resultVariants.first {
        case .accepted:
            return .accepted(.init(commandId: commandId, correlationId: correlationId, operationId: nil))
        case .presented:
            return .presented(.init(commandId: commandId, correlationId: correlationId))
        case .unavailable:
            return .unavailable(
                .init(commandId: commandId, correlationId: correlationId, reason: .featureUnavailable))
        case .applied, .partial, .uncertain, .none:
            return .applied(.init(commandId: commandId, correlationId: correlationId))
        }
    }

    static func exampleRequest(
        for command: AppCommand,
        variant: IPCCommandArgumentVariant
    ) throws -> IPCCommandExecutionRequest {
        try exampleRequest(commandIdentifier: IPCCommandIdentifier(rawValue: command.rawValue), variant: variant)
    }

    private static func exampleRequest(
        commandIdentifier: IPCCommandIdentifier,
        variant: IPCCommandArgumentVariant
    ) throws -> IPCCommandExecutionRequest {
        IPCCommandExecutionRequest(
            commandId: commandIdentifier,
            correlationId: ExampleIdentities.correlation,
            arguments: try exampleArguments(for: variant)
        )
    }

    static func exampleArguments(for variant: IPCCommandArgumentVariant) throws -> IPCCommandArguments {
        try exampleLayoutArguments(for: variant) ?? exampleSurfaceArguments(for: variant)
    }

    /// Window, tab, pane, arrangement and drawer shapes.
    private static func exampleLayoutArguments(
        for variant: IPCCommandArgumentVariant
    ) throws -> IPCCommandArguments? {
        let window = ExampleIdentities.window
        let tab = ExampleIdentities.tab
        let pane = try ExampleIdentities.paneSelector
        let secondaryPane = try ExampleIdentities.secondaryPaneSelector
        switch variant {
        case .noArguments:
            return .noArguments
        case .workspaceWindow:
            return .workspaceWindow(.init(workspaceWindowId: window))
        case .tab:
            return .tab(.init(workspaceWindowId: window, tabId: tab))
        case .renamedTab:
            return .renamedTab(.init(workspaceWindowId: window, tabId: tab, name: ExampleIdentities.name))
        case .newTab:
            return .newTab(.init(workspaceWindowId: window, launchDirectory: ExampleIdentities.directoryPath))
        case .tabAnchor:
            return .tabAnchor(.init(workspaceWindowId: window, anchorTabId: tab))
        case .pane:
            return .pane(.init(workspaceWindowId: window, paneSelector: pane))
        case .sourcePane:
            return .sourcePane(.init(workspaceWindowId: window, sourcePaneSelector: pane))
        case .movePaneToTab:
            return .movePaneToTab(
                .init(workspaceWindowId: window, sourcePaneSelector: pane, destinationTabId: tab))
        case .arrangement:
            return .arrangement(
                .init(workspaceWindowId: window, tabId: tab, arrangementId: ExampleIdentities.arrangement))
        case .newArrangement:
            return .newArrangement(.init(workspaceWindowId: window, tabId: tab, name: ExampleIdentities.name))
        case .renamedArrangement:
            return .renamedArrangement(
                .init(
                    workspaceWindowId: window,
                    tabId: tab,
                    arrangementId: ExampleIdentities.arrangement,
                    name: ExampleIdentities.name
                ))
        case .drawerParent:
            return .drawerParent(.init(workspaceWindowId: window, parentPaneSelector: pane))
        case .drawerSourcePane:
            return .drawerSourcePane(
                .init(
                    workspaceWindowId: window,
                    parentPaneSelector: pane,
                    sourceDrawerPaneSelector: secondaryPane
                ))
        case .drawerPane:
            return .drawerPane(
                .init(workspaceWindowId: window, parentPaneSelector: pane, drawerPaneSelector: secondaryPane))
        case .detachedDrawerPane:
            return .detachedDrawerPane(.init(workspaceWindowId: window, drawerPaneSelector: secondaryPane))
        case .directory, .repository, .standalonePane, .worktree, .worktreeInPane,
            .terminalFromWorktree, .terminalFromPane, .managementFromMainPane,
            .managementFromDrawerPane, .floatingTerminal, .webview:
            // Owned by `exampleSurfaceArguments`. Spelled out rather than
            // defaulted so a new variant fails this build instead of failing a
            // discovery call at runtime.
            return nil
        }
    }

    /// Repository, worktree, terminal-creation, management and webview shapes.
    private static func exampleSurfaceArguments(
        for variant: IPCCommandArgumentVariant
    ) throws -> IPCCommandArguments {
        let window = ExampleIdentities.window
        let pane = try ExampleIdentities.paneSelector
        let secondaryPane = try ExampleIdentities.secondaryPaneSelector
        switch variant {
        case .directory:
            return .directory(.init(workspaceWindowId: window, directoryPath: ExampleIdentities.directoryPath))
        case .repository:
            return .repository(.init(repoId: ExampleIdentities.repository))
        case .standalonePane:
            return .standalonePane(.init(paneSelector: pane))
        case .worktree:
            return .worktree(.init(workspaceWindowId: window, worktreeId: ExampleIdentities.worktree))
        case .worktreeInPane:
            return .worktreeInPane(
                .init(
                    workspaceWindowId: window,
                    worktreeId: ExampleIdentities.worktree,
                    targetPaneSelector: pane
                ))
        case .terminalFromWorktree:
            return .terminalFromWorktree(
                .init(
                    workspaceWindowId: window,
                    worktreeId: ExampleIdentities.worktree,
                    launchDirectory: ExampleIdentities.directoryPath,
                    title: ExampleIdentities.name
                ))
        case .terminalFromPane:
            return .terminalFromPane(
                .init(
                    workspaceWindowId: window,
                    sourcePaneSelector: pane,
                    launchDirectory: ExampleIdentities.directoryPath,
                    title: ExampleIdentities.name
                ))
        case .managementFromMainPane:
            return .managementFromMainPane(.init(workspaceWindowId: window, mainPaneSelector: pane))
        case .managementFromDrawerPane:
            return .managementFromDrawerPane(
                .init(
                    workspaceWindowId: window,
                    parentPaneSelector: pane,
                    drawerPaneSelector: secondaryPane
                ))
        case .floatingTerminal:
            return .floatingTerminal(
                .init(
                    workspaceWindowId: window,
                    launchDirectory: ExampleIdentities.directoryPath,
                    title: ExampleIdentities.name
                ))
        case .webview:
            return .webview(.init(workspaceWindowId: window, url: ExampleIdentities.webviewURL))
        case .noArguments, .workspaceWindow, .tab, .renamedTab, .newTab, .tabAnchor, .pane,
            .sourcePane, .movePaneToTab, .arrangement, .newArrangement, .renamedArrangement,
            .drawerParent, .drawerSourcePane, .drawerPane, .detachedDrawerPane:
            // `exampleLayoutArguments` answered these before this call, so the
            // branch is unreachable. It is spelled out rather than defaulted so a
            // new variant fails this build instead of reaching it.
            throw AppIPCCommandError(reason: .validationRejected)
        }
    }

    /// Illustrative identities. They are documentation values only; no admission
    /// path ever resolves them.
    enum ExampleIdentities {
        static let window = fixedUUID("01994abc-4000-7000-8000-000000000001")
        static let pane = fixedUUID("01994abc-4000-7000-8000-000000000002")
        static let correlation = fixedUUID("01994abc-4000-7000-8000-000000000003")
        static let tab = fixedUUID("01994abc-4000-7000-8000-000000000004")
        static let repository = fixedUUID("01994abc-4000-7000-8000-000000000005")
        static let worktree = fixedUUID("01994abc-4000-7000-8000-000000000006")
        static let arrangement = fixedUUID("01994abc-4000-7000-8000-000000000007")
        static let secondaryPane = fixedUUID("01994abc-4000-7000-8000-000000000008")
        static let name = "Example"
        static let directoryPath = "/tmp/example"
        static let webviewURL = "https://github.com"

        static var paneSelector: IPCPaneSelector {
            get throws { try .init(rawValue: pane.uuidString) }
        }

        static var secondaryPaneSelector: IPCPaneSelector {
            get throws { try .init(rawValue: secondaryPane.uuidString) }
        }

        private static func fixedUUID(_ raw: String) -> UUID {
            guard let value = UUID(uuidString: raw) else {
                preconditionFailure("Invalid command example UUID")
            }
            return value
        }
    }
}
