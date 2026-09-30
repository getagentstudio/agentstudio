import AgentStudioProgrammaticControl
import Foundation

/// The whole descriptor CLI except the process entry point.
///
/// `main.swift` is a shell that binds this to the real process: real argv, the
/// real environment, real stdio and `exit`. Keeping dispatch here is what lets a
/// test drive the exact path the shipped binary runs without spawning it. That
/// matters beyond convenience: a test that waits on a CLI subprocess blocks a
/// cooperative thread, and the in-process IPC server needs that same pool to
/// answer the request, so on a small machine the two starve each other.
package struct AgentStudioIPCClientCommandLineRunner {
    package struct Props: Sendable {
        package let arguments: [String]
        package let environment: [String: String]
        package let executablePath: String
        package let bundleExecutableURL: URL?
        package let standardInput: @Sendable () -> Data
        package let identifierGenerator: @Sendable () -> UUID
        package let standardOutputSink: @Sendable (String) -> Void
        package let standardErrorSink: @Sendable (String) -> Void

        package init(
            arguments: [String],
            environment: [String: String],
            executablePath: String,
            bundleExecutableURL: URL?,
            standardInput: @escaping @Sendable () -> Data,
            identifierGenerator: @escaping @Sendable () -> UUID,
            standardOutputSink: @escaping @Sendable (String) -> Void,
            standardErrorSink: @escaping @Sendable (String) -> Void
        ) {
            self.arguments = arguments
            self.environment = environment
            self.executablePath = executablePath
            self.bundleExecutableURL = bundleExecutableURL
            self.standardInput = standardInput
            self.identifierGenerator = identifierGenerator
            self.standardOutputSink = standardOutputSink
            self.standardErrorSink = standardErrorSink
        }
    }

    /// - Returns: the exit code the process should end with.
    package static func run(props: Props) -> Int32 {
        Self(props: props).dispatchCommandLine()
    }

    private let props: Props

    private func dispatchCommandLine() -> Int32 {
        var endpointCameFromDebugEscrow = false
        do {
            let readInput = props.standardInput
            if let code = providerCommandExit(readInput: readInput) {
                return code
            }
            let global = try AgentStudioIPCClientArguments.parseGlobal(
                props.arguments, environment: props.environment,
                standardInputProvider: readInput
            )
            endpointCameFromDebugEscrow = global.endpointCameFromDebugEscrow
            let offlineHandler = PaneNotificationOfflineHandler(environment: props.environment)
            let examples = IPCBuiltInMethodExampleContext(illustrativeIdentifier: props.identifierGenerator())
            let bootstrap = try IPCBuiltInMethodCatalog.bootstrapDescriptors(examples: examples)
            let discoveryClient = AgentStudioIPCClient(configuration: global.configuration, descriptors: bootstrap)
            if global.methodArguments == ["system.capabilities"] {
                try write(JSONEncoder().encode(discoveryClient.discoverCatalog()))
                return 0
            }
            let locallyResolvable = try IPCBuiltInMethodCatalog.locallyResolvableDescriptors(examples: examples)
            let descriptors: [IPCAnyMethodDescriptor]
            var commandCatalog: IPCDiscoveredCommandCatalog?
            // A method this binary was compiled with goes straight out. Only the
            // command verbs, whose arguments the running app defines, and
            // anything not compiled here need the catalog.
            if global.methodArguments.first != "command.list",
                global.methodArguments.first != "command.execute",
                IPCBuiltInMethodCatalog.resolvesLocally(
                    global.methodArguments, descriptors: locallyResolvable)
            {
                descriptors = locallyResolvable
            } else {
                let catalog: IPCMethodCatalogResult
                do {
                    catalog = try discoveryClient.discoverCatalog()
                } catch let unreachable as IPCDescriptorClientFailure where unreachable.permitsOfflineQueue {
                    try queueNotificationWhileOffline(
                        global: global, examples: examples, handler: offlineHandler,
                        standardInputProvider: readInput, unreachable: unreachable
                    )
                    return 0
                }
                if global.methodArguments.first == "command.list" || global.methodArguments.first == "command.execute" {
                    switch try resolveDiscoveredCommandDescriptors(
                        global: global, bootstrap: bootstrap, catalog: catalog,
                        standardInputProvider: readInput
                    ) {
                    case .completed:
                        return 0
                    case .resolved(let resolvedDescriptors, let resolvedCatalog):
                        descriptors = resolvedDescriptors
                        commandCatalog = resolvedCatalog
                    }
                } else {
                    descriptors = try IPCBuiltInMethodCatalog.matchingDiscoveredMethods(catalog, examples: examples)
                }
            }
            var invocation = try AgentStudioIPCClientArguments.parseMethod(
                global, descriptors: descriptors, correlationIDGenerator: props.identifierGenerator,
                standardInputProvider: readInput
            ).descriptorInvocation
            if let commandCatalog {
                let request = try JSONDecoder().decode(
                    IPCCommandExecutionRequest.self, from: invocation.normalizedParameters.data)
                invocation = try commandCatalog.makeInvocation(
                    commandId: request.commandId, correlationId: request.correlationId, arguments: request.arguments)
            }
            try deliver(
                invocation: invocation,
                client: AgentStudioIPCClient(
                    configuration: global.configuration, descriptors: descriptors),
                commandCatalog: commandCatalog,
                offlineHandler: offlineHandler
            )
            return 0
        } catch {
            return exitCode(forFailure: error, endpointCameFromDebugEscrow: endpointCameFromDebugEscrow)
        }
    }

    /// Sends one parsed invocation and writes whatever the app answers. A
    /// subscription streams; anything else is one call whose unreachable case is
    /// the offline queue.
    private func deliver(
        invocation: IPCDescriptorInvocation,
        client: AgentStudioIPCClient,
        commandCatalog: IPCDiscoveredCommandCatalog?,
        offlineHandler: PaneNotificationOfflineHandler
    ) throws {
        guard invocation.descriptor.metadata.responseDelivery != .subscription else {
            try client.stream(invocation) { frame in
                switch frame {
                case .initialResponse(let response): try write(response.normalizedResult.data)
                case .notification(let notification): props.standardOutputSink(notification)
                case .remoteFailure(let failure):
                    throw CLIExit.structured(CLIErrorPresentation(remoteFailure: failure))
                }
            }
            return
        }
        let result: IPCDescriptorClientCallResult
        do {
            result = try client.call(invocation)
        } catch let unreachable as IPCDescriptorClientFailure where unreachable.permitsOfflineQueue {
            try queueWhileOffline(
                invocation: invocation, handler: offlineHandler,
                requestLine: { try client.requestFrame(invocation) }, unreachable: unreachable
            )
            return
        }
        switch result {
        case .success(let response):
            if let commandCatalog {
                _ = try commandCatalog.decodeResult(response.normalizedResult, for: invocation)
            }
            if case .model(let presentation) = invocation.presentation, !presentation.showsDetail {
                props.standardOutputSink(presentation.successReply)
            } else {
                try write(response.normalizedResult.data)
            }
        case .remoteFailure(let failure):
            throw modelFailureExit(failure, invocation: invocation)
        }
    }

    /// A refused model call answers in the same one-line register it asked in.
    /// Tooling callers and `--detail` keep the structured envelope.
    private func modelFailureExit(
        _ failure: IPCDescriptorRemoteFailure,
        invocation: IPCDescriptorInvocation
    ) -> CLIExit {
        guard case .model(let presentation) = invocation.presentation,
            !presentation.showsDetail,
            let reply = IPCModelInvocationFailureReply.line(forDocumentedReason: failure.documentedReason)
        else {
            return .structured(CLIErrorPresentation(remoteFailure: failure))
        }
        return .modelReply(reply)
    }

    /// `command.list` answers from the discovery response itself, so it finishes
    /// here rather than continuing to a second call.
    private func resolveDiscoveredCommandDescriptors(
        global: IPCClientGlobalArguments,
        bootstrap: [IPCAnyMethodDescriptor],
        catalog: IPCMethodCatalogResult,
        standardInputProvider: () throws -> Data
    ) throws -> DiscoveredCommandDescriptors {
        let discovery = try IPCCommandDiscovery(methodCatalog: catalog)
        let authenticationDescriptors = bootstrap.filter { $0.metadata.name == "auth.login" }
        guard authenticationDescriptors.count == 1 else { throw CLIExit.rejected }
        let listClient = AgentStudioIPCClient(
            configuration: global.configuration,
            descriptors: authenticationDescriptors + [discovery.commandListInvocation.descriptor]
        )
        let response: IPCDescriptorClientResponse
        switch try listClient.call(discovery.commandListInvocation) {
        case .success(let successfulResponse):
            response = successfulResponse
        case .remoteFailure(let failure):
            throw CLIExit.structured(CLIErrorPresentation(remoteFailure: failure))
        }
        let commands = try discovery.decodeCommandCatalog(from: response.normalizedResult)
        guard global.methodArguments.first != "command.list" else {
            _ = try AgentStudioIPCClientArguments.parseMethod(
                global, descriptors: [discovery.commandListInvocation.descriptor],
                correlationIDGenerator: props.identifierGenerator,
                standardInputProvider: standardInputProvider)
            try write(response.normalizedResult.data)
            return .completed
        }
        // The payload is read with the compiled envelope so a recognized hidden
        // command's arguments survive parsing; the catalog then binds it.
        return .resolved(
            authenticationDescriptors + [commands.requestEnvelopeDescriptor], commandCatalog: commands)
    }

    /// Discovery never reached the app, so the notification is classified from
    /// the compiled descriptors. Anything that is not an eligible model
    /// notification keeps the original unreachable failure.
    private func queueNotificationWhileOffline(
        global: IPCClientGlobalArguments,
        examples: IPCBuiltInMethodExampleContext,
        handler: PaneNotificationOfflineHandler,
        standardInputProvider: () throws -> Data,
        unreachable: IPCDescriptorClientFailure
    ) throws {
        let descriptors = try IPCBuiltInMethodCatalog.offlineNotificationDescriptors(examples: examples)
        guard
            let invocation = try? AgentStudioIPCClientArguments.parseMethod(
                global, descriptors: descriptors, correlationIDGenerator: props.identifierGenerator,
                standardInputProvider: standardInputProvider
            ).descriptorInvocation
        else {
            throw unreachable
        }
        let client = AgentStudioIPCClient(configuration: global.configuration, descriptors: descriptors)
        try queueWhileOffline(
            invocation: invocation, handler: handler,
            requestLine: { try client.requestFrame(invocation) }, unreachable: unreachable
        )
    }

    private func queueWhileOffline(
        invocation: IPCDescriptorInvocation,
        handler: PaneNotificationOfflineHandler,
        requestLine: () throws -> String,
        unreachable: IPCDescriptorClientFailure
    ) throws {
        switch try handler.handleUnreachableApp(invocation: invocation, requestLine: requestLine) {
        case .queued(let reply):
            props.standardOutputSink(reply)
        case .clearUnavailableWhileOffline:
            throw CLIExit.message("Can't clear while Agent Studio is offline.")
        case .notQueued:
            throw unreachable
        }
    }

    /// Provider hooks and the package installer are not IPC methods, so they
    /// are dispatched before descriptor parsing: one runs as the provider's own
    /// child process and the other edits the provider's configuration on disk.
    ///
    /// Claude Code's router is asked first. The provider-keyed parser matches
    /// `hook <provider> <event>` and `package install <provider>` for every
    /// provider name, so running it first would answer a Claude Code invocation
    /// with "unknown provider" instead of letting Claude Code's own path run.
    ///
    /// - Returns: the process exit code when the arguments address a provider
    ///   command, and `nil` when they belong to the descriptor CLI.
    private func providerCommandExit(readInput: @escaping @Sendable () -> Data) -> Int32? {
        if let code = ClaudeCodeProviderRouter.exitCode(
            arguments: props.arguments, environment: props.environment,
            executablePath: props.executablePath, standardInput: readInput,
            identifierGenerator: props.identifierGenerator,
            noticeSink: props.standardOutputSink, diagnosticSink: props.standardErrorSink
        ) {
            return code
        }
        if let code = CursorProviderRouter.exitCode(
            arguments: props.arguments, environment: props.environment,
            executablePath: props.executablePath, standardInput: readInput,
            identifierGenerator: props.identifierGenerator,
            noticeSink: props.standardOutputSink, diagnosticSink: props.standardErrorSink
        ) {
            return code
        }
        guard let subcommand = AgentPackageSubcommand.parse(props.arguments) else { return nil }
        return AgentPackageCommandRunner.run(subcommand, props: agentPackageProps(readInput: readInput))
    }

    private func agentPackageProps(
        readInput: @escaping @Sendable () -> Data
    ) -> AgentPackageCommandRunner.Props {
        AgentPackageCommandRunner.Props(
            environment: props.environment,
            executableURL: props.bundleExecutableURL,
            standardInput: readInput,
            correlationIdProvider: props.identifierGenerator,
            exampleIdentifierProvider: props.identifierGenerator,
            standardOutputSink: props.standardOutputSink,
            standardErrorSink: props.standardErrorSink
        )
    }

    private func exitCode(forFailure error: Error, endpointCameFromDebugEscrow: Bool) -> Int32 {
        switch error {
        case let failure as PaneNotificationSpoolWriteError:
            props.standardErrorSink(
                "Agent Studio could not durably queue this notification: \(failure.reason.rawValue)")
        case let failure as IPCCommandDiscoveryError:
            writeStructuredError(CLIErrorPresentation(commandDiscoveryFailure: failure))
        case let failure as IPCDescriptorInvocationError:
            writeStructuredError(CLIErrorPresentation(invocationFailure: failure))
        case let correction as IPCSchemaValidationError:
            writeStructuredError(CLIErrorPresentation(schemaCorrection: correction))
        case let failure as IPCDescriptorRemoteFailure:
            writeStructuredError(CLIErrorPresentation(remoteFailure: failure))
        case let failure as AgentStudioIPCClientError where failure.reason == .invalidArguments:
            writeStructuredError(.localInvalidArguments)
        case let failure as AgentStudioIPCClientError where failure.reason == .debugAppNotRunning:
            props.standardErrorSink("Debug app not running; start it with the debug launcher.")
        case let failure as IPCDescriptorClientFailure
        where endpointCameFromDebugEscrow && failure.disposition == .endpointUnavailableBeforeSubmission:
            // The escrow named this socket; nothing answering there means the
            // debug app that wrote the file is gone.
            props.standardErrorSink("Debug app not running; start it with the debug launcher.")
        case let failure as IPCDescriptorClientFailure where failure.disposition == .deliveryUncertain:
            props.standardErrorSink("Delivery uncertain.")
        case let failure as IPCDescriptorClientFailure:
            if case .unsupportedVersion(let correction) = failure.reason {
                writeStructuredError(CLIErrorPresentation(unsupportedVersion: correction))
            } else {
                writeUnavailableError()
            }
        case let error as CLIExit:
            switch error {
            case .structured(let presentation): writeStructuredError(presentation)
            case .modelReply(let reply): props.standardErrorSink(reply)
            case .message(let message): props.standardErrorSink(message)
            case .rejected: writeUnavailableError()
            }
        default:
            writeUnavailableError()
        }
        return 1
    }

    private func writeUnavailableError() {
        props.standardErrorSink("Agent Studio request rejected or unavailable.")
    }

    private func write(_ data: Data) throws {
        guard let output = String(data: data, encoding: .utf8) else { throw CLIExit.rejected }
        props.standardOutputSink(output)
    }

    private func writeStructuredError(_ error: CLIErrorPresentation) {
        guard let encoded = try? JSONEncoder().encode(error),
            let output = String(data: encoded, encoding: .utf8)
        else {
            props.standardErrorSink("Agent Studio request rejected or unavailable.")
            return
        }
        props.standardErrorSink(output)
    }
}

private enum DiscoveredCommandDescriptors {
    case completed
    case resolved([IPCAnyMethodDescriptor], commandCatalog: IPCDiscoveredCommandCatalog)
}

private enum CLIExit: Error {
    case rejected
    case message(String)
    case structured(CLIErrorPresentation)
    case modelReply(String)
}

private struct CLIErrorPresentation: Codable {
    let reason: String
    let fieldPath: String?
    let expected: String?
    let catalogMethod: String?
    let requiredScope: IPCPermissionScope?
    /// The method or command a pane agent was refused, for the agent outcomes.
    var refusedName: String?

    /// Every discovery failure already carries a field path and an expectation.
    /// Dropping them left a catalog mismatch indistinguishable from a bad
    /// argument, which is why a whole-catalog failure read as a bare
    /// `invalidParams`. The switch is exhaustive so a new reason has to be
    /// classified rather than silently losing its diagnostics.
    init(commandDiscoveryFailure: IPCCommandDiscoveryError) {
        fieldPath = commandDiscoveryFailure.fieldPath
        expected = commandDiscoveryFailure.expected
        switch commandDiscoveryFailure.reason {
        case .unknownCommandIdentifier:
            reason = "unknownCommand"
            catalogMethod = "command.list"
        case .argumentVariantNotAllowed, .invalidCommandCatalog:
            reason = "invalidParams"
            catalogMethod = "command.list"
        case .missingCommandList, .missingCommandExecute, .incompatibleMethodMetadata:
            reason = "invalidParams"
            catalogMethod = "system.capabilities"
        case .invalidCommandResult, .resultVariantNotAllowed, .resultCommandIdentifierMismatch,
            .resultCorrelationMismatch:
            reason = "invalidParams"
            catalogMethod = "command.execute"
        }
        requiredScope = nil
    }

    init(remoteFailure: IPCDescriptorRemoteFailure) {
        refusedName = remoteFailure.agentRefusal?.name
        if let agentRefusal = remoteFailure.agentRefusal {
            reason = agentRefusal.reason.rawValue
            fieldPath = nil
            expected = nil
            catalogMethod = nil
            requiredScope = nil
            return
        }
        if let requiredScope = remoteFailure.requiredScope {
            reason = "missingGrant"
            fieldPath = "$.authorization"
            expected = nil
            catalogMethod = nil
            self.requiredScope = requiredScope
            return
        }
        if let correction = remoteFailure.correction {
            reason = "invalidParams"
            fieldPath = correction.fieldPath
            expected = correction.expected
            catalogMethod = nil
            requiredScope = nil
            return
        }
        reason = remoteFailure.documentedReason ?? "requestRejected"
        fieldPath = Self.knownFieldPath(for: reason)
        expected = nil
        catalogMethod = nil
        requiredScope = nil
    }

    init(invocationFailure: IPCDescriptorInvocationError) {
        if invocationFailure.reason == .unknownMethod {
            reason = "unknownMethod"
            fieldPath = "$.method"
            expected = "a method advertised by system.capabilities"
            catalogMethod = "system.capabilities"
        } else {
            reason = "invalidParams"
            fieldPath = invocationFailure.fieldPath
            expected = invocationFailure.expected
            catalogMethod = nil
        }
        requiredScope = nil
    }

    init(schemaCorrection: IPCSchemaValidationError) {
        reason = "invalidParams"
        fieldPath = schemaCorrection.fieldPath
        expected = schemaCorrection.expected
        catalogMethod = nil
        requiredScope = nil
    }

    init(unsupportedVersion correction: IPCSchemaValidationError) {
        reason = "unsupportedVersion"
        fieldPath = Self.safeFieldPath(correction.fieldPath)
        expected = correction.expected
        catalogMethod = nil
        requiredScope = nil
    }

    static let localInvalidArguments = Self(
        reason: "invalidParams", fieldPath: "$", expected: "valid CLI arguments",
        catalogMethod: nil, requiredScope: nil
    )

    private init(
        reason: String, fieldPath: String?, expected: String?, catalogMethod: String?,
        requiredScope: IPCPermissionScope?
    ) {
        self.reason = reason
        self.fieldPath = fieldPath
        self.expected = expected
        self.catalogMethod = catalogMethod
        self.requiredScope = requiredScope
    }

    private static func knownFieldPath(for reason: String) -> String? {
        switch reason {
        case "stateUnavailable", "unknownCommand", "unsupportedCommand": "$.commandId"
        case "missingGrant": "$.authorization"
        default: nil
        }
    }

    private static func safeFieldPath(_ fieldPath: String?) -> String? {
        guard let fieldPath,
            ["$.arguments.kind", "$.authorization", "$.commandId", "$.compatibility"].contains(fieldPath)
        else {
            return nil
        }
        return fieldPath
    }
}
