import AgentStudioCLIStore
import AgentStudioIPCTransport
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
package struct AgentStudioIPCClientCommandLineRunner: Sendable {
    package struct Props: Sendable {
        package let arguments: [String]
        package let environment: [String: String]
        package let executablePath: String
        package let bundleExecutableURL: URL?
        package let standardInput: @Sendable () -> Data
        package let identifierGenerator: @Sendable () -> UUID
        package let standardOutputSink: @Sendable (String) -> Void
        package let standardErrorSink: @Sendable (String) -> Void
        package let now: @Sendable () -> Date
        package let standardInputFileDescriptor: Int32
        package let deadlineTiming: (any CallDeadlineTiming)?

        package init(
            arguments: [String],
            environment: [String: String],
            executablePath: String,
            bundleExecutableURL: URL?,
            standardInput: @escaping @Sendable () -> Data,
            identifierGenerator: @escaping @Sendable () -> UUID,
            standardOutputSink: @escaping @Sendable (String) -> Void,
            standardErrorSink: @escaping @Sendable (String) -> Void,
            now: @escaping @Sendable () -> Date = { Date() },
            standardInputFileDescriptor: Int32 = FileHandle.standardInput.fileDescriptor,
            deadlineTiming: (any CallDeadlineTiming)? = nil
        ) {
            self.arguments = arguments
            self.environment = environment
            self.executablePath = executablePath
            self.bundleExecutableURL = bundleExecutableURL
            self.standardInput = standardInput
            self.identifierGenerator = identifierGenerator
            self.standardOutputSink = standardOutputSink
            self.standardErrorSink = standardErrorSink
            self.now = now
            self.standardInputFileDescriptor = standardInputFileDescriptor
            self.deadlineTiming = deadlineTiming
        }
    }

    /// - Returns: the exit code the process should end with.
    package static func run(props: Props) -> Int32 {
        let hookDeadline: CallDeadline?
        if props.arguments.first == "hook" {
            if let timing = props.deadlineTiming {
                hookDeadline = CallDeadline(limit: CLIPolicy.hookCallLimit, timing: timing)
            } else {
                hookDeadline = CallDeadline(limit: CLIPolicy.hookCallLimit)
            }
        } else {
            hookDeadline = nil
        }
        return Self(props: props, hookDeadline: hookDeadline).dispatchCommandLine()
    }

    private let props: Props
    private let hookDeadline: CallDeadline?

    private func dispatchCommandLine() -> Int32 {
        var endpointCameFromDebugEscrow = false
        do {
            let readInput = props.standardInput
            if let code = providerCommandExit(readInput: readInput) {
                return code
            }
            let resolver = IPCCompiledInvocationResolver()
            if let help = try resolver.localHelp(arguments: props.arguments) {
                props.standardOutputSink(help)
                return 0
            }
            let global = try AgentStudioIPCClientArguments.parseGlobal(
                props.arguments, environment: props.environment,
                standardInputProvider: readInput
            )
            endpointCameFromDebugEscrow = global.endpointCameFromDebugEscrow
            let examples = IPCBuiltInMethodExampleContext(illustrativeIdentifier: props.identifierGenerator())
            let inputs = IPCBuiltInMethodCatalogInputs(examples: examples)
            let offlineHandler = PaneNotificationOfflineHandler(environment: props.environment)
            if try writeExplicitDiscovery(global: global, resolver: resolver, inputs: inputs, readInput: readInput) {
                return 0
            }
            let invocation: IPCDescriptorInvocation
            let descriptors = try resolver.resolve(
                arguments: global.methodArguments, authenticated: global.configuration.authToken != nil,
                inputs: inputs)
            if global.methodArguments.first == "command.execute" {
                guard let descriptor = descriptors.first(where: { $0.metadata.name == "command.execute" }) else {
                    throw IPCMethodDescriptorRepresentationLookupError.missingMethod("command.execute")
                }
                invocation = try IPCCommandCLIInvocationParser.parse(
                    global: global, descriptor: descriptor, readInput: readInput,
                    correlationIDGenerator: props.identifierGenerator)
            } else {
                invocation = try AgentStudioIPCClientArguments.parseMethod(
                    global, descriptors: descriptors, correlationIDGenerator: props.identifierGenerator,
                    standardInputProvider: readInput
                ).descriptorInvocation
            }
            try deliver(
                invocation: invocation,
                client: makeClient(
                    configuration: global.configuration, descriptors: descriptors),
                offlineHandler: offlineHandler
            )
            return 0
        } catch {
            return exitCode(forFailure: error, endpointCameFromDebugEscrow: endpointCameFromDebugEscrow)
        }
    }

    private func writeExplicitDiscovery(
        global: IPCClientGlobalArguments, resolver: IPCCompiledInvocationResolver,
        inputs: IPCBuiltInMethodCatalogInputs, readInput: () -> Data
    ) throws -> Bool {
        guard
            global.methodArguments.first == "system.capabilities"
                || global.methodArguments == ["help", "--live"]
                || global.methodArguments.first == "command.list"
        else { return false }
        let authentication = try resolver.resolve(arguments: ["auth.login"], authenticated: false, inputs: inputs)
        let discoveryClient = makeClient(configuration: global.configuration, descriptors: authentication)
        if global.methodArguments.first == "system.capabilities" {
            try validateCapabilitiesParameters(global: global, readInput: readInput)
            try write(discoveryClient.discoverCatalogBytes())
        } else if global.methodArguments == ["help", "--live"] {
            try writeLiveHelp(discoveryClient: discoveryClient)
        } else {
            let schema = try IPCEmptyParams.ipcSchema()
            let arguments = Array(global.methodArguments.dropFirst())
            _ = try schema.normalize(
                IPCDescriptorInvocationParser.toolingParameterData(
                    arguments: arguments, schema: schema,
                    standardInput: arguments.first == "--stdin" ? readInput() : nil))
            try write(discoveryClient.discoverCommandBytes())
        }
        return true
    }

    private func validateCapabilitiesParameters(
        global: IPCClientGlobalArguments, readInput: () -> Data
    ) throws {
        let arguments = Array(global.methodArguments.dropFirst())
        let input = arguments.first == "--stdin" ? readInput() : nil
        let schema = try IPCEmptyParams.ipcSchema()
        _ = try schema.normalize(
            IPCDescriptorInvocationParser.toolingParameterData(
                arguments: arguments, schema: schema, standardInput: input))
    }

    private func writeLiveHelp(discoveryClient: AgentStudioIPCClient) throws {
        let resultBytes = try discoveryClient.discoverCommandBytes()
        let metadata = try JSONDecoder().decode(IPCLiveCommandHelp.self, from: resultBytes)
        props.standardOutputSink(IPCDescriptorCLIHelp.liveCommands(metadata.commands))
    }

    /// Sends one parsed invocation and writes whatever the app answers. A
    /// subscription streams; anything else is one call whose unreachable case is
    /// the offline queue.
    private func deliver(
        invocation: IPCDescriptorInvocation,
        client: AgentStudioIPCClient,
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
            if invocation.descriptor.metadata.name == "command.execute" {
                let request = try JSONDecoder().decode(
                    IPCRawCommandExecutionRequest.self, from: invocation.normalizedParameters.data)
                let result = try JSONDecoder().decode(
                    IPCCommandExecutionResult.self, from: response.normalizedResult.data)
                guard result.commandId == request.commandId, result.correlationId == request.correlationId else {
                    throw CLIExit.rejected
                }
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

    private func makeClient(configuration: AgentStudioIPCClientConfiguration, descriptors: [IPCAnyMethodDescriptor])
        -> AgentStudioIPCClient
    {
        let cleanup = CLIStoreCleanupHandler(environment: props.environment, now: props.now)
        return AgentStudioIPCClient(
            configuration: configuration, descriptors: descriptors,
            onCallCompletion: { cleanup.handle(readThrough: $0) })
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
        let isHook: Bool = props.arguments.first == "hook"
        let readHookInput: @Sendable () throws -> Data = {
            if let hookDeadline {
                return try hookDeadline.readInputToEnd(fileDescriptor: props.standardInputFileDescriptor)
            }
            return readInput()
        }
        let providerDiagnostics: @Sendable (String) -> Void
        if isHook {
            providerDiagnostics = { _ in CLIDiagnostics.record(.providerHookFailed) }
        } else {
            providerDiagnostics = props.standardErrorSink
        }
        if let code = ClaudeCodeProviderRouter.exitCode(
            arguments: props.arguments, environment: props.environment,
            executablePath: props.executablePath, standardInput: readHookInput,
            identifierGenerator: props.identifierGenerator,
            noticeSink: props.standardOutputSink, diagnosticSink: providerDiagnostics,
            deadline: hookDeadline
        ) {
            return code
        }
        if let code = CursorProviderRouter.exitCode(
            arguments: props.arguments, environment: props.environment,
            executablePath: props.executablePath, standardInput: readHookInput,
            identifierGenerator: props.identifierGenerator,
            noticeSink: props.standardOutputSink, diagnosticSink: providerDiagnostics,
            deadline: hookDeadline
        ) {
            return code
        }
        guard let subcommand = AgentPackageSubcommand.parse(props.arguments) else { return nil }
        return AgentPackageCommandRunner.run(subcommand, props: agentPackageProps(readInput: readInput))
    }

    private func agentPackageProps(
        readInput: @escaping @Sendable () -> Data
    ) -> AgentPackageCommandRunner.Props {
        let isHook: Bool = props.arguments.first == "hook"
        let packageDiagnostics: @Sendable (String) -> Void
        if isHook {
            packageDiagnostics = { _ in CLIDiagnostics.record(.providerHookFailed) }
        } else {
            packageDiagnostics = props.standardErrorSink
        }
        let packageInput: @Sendable () throws -> Data = {
            if let hookDeadline {
                return try hookDeadline.readInputToEnd(fileDescriptor: props.standardInputFileDescriptor)
            }
            return readInput()
        }
        let packageProps = AgentPackageCommandRunner.Props(
            environment: props.environment,
            executableURL: props.bundleExecutableURL,
            standardInput: packageInput,
            correlationIdProvider: props.identifierGenerator,
            exampleIdentifierProvider: props.identifierGenerator,
            standardOutputSink: props.standardOutputSink,
            standardErrorSink: packageDiagnostics,
            deadline: hookDeadline
        )
        return packageProps
    }

    private func exitCode(forFailure error: Error, endpointCameFromDebugEscrow: Bool) -> Int32 {
        switch error {
        case let failure as CLIStoreFailure:
            props.standardErrorSink(
                "Agent Studio could not durably queue this notification: \(String(describing: failure))")
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
        case is IPCDescriptorClientFailure:
            writeUnavailableError()
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
    var commandId: String?
    var closestMatches: [String]?

    init(remoteFailure: IPCDescriptorRemoteFailure) {
        if let correction = remoteFailure.commandCorrection {
            catalogMethod = nil
            requiredScope = nil
            switch correction {
            case .invalidArguments(let path, let expectation):
                reason = "invalidArguments"
                fieldPath = path
                expected = expectation
            case .unknownCommand(let identifier, let matches):
                reason = "unknownCommand"
                fieldPath = nil
                expected = nil
                commandId = identifier
                closestMatches = matches
            }
            return
        }
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
            expected = invocationFailure.expected
            catalogMethod = nil
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
