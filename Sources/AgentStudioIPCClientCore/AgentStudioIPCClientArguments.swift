import AgentStudioProgrammaticControl
import Foundation

package struct AgentStudioIPCClientInvocation: Sendable {
    package let configuration: AgentStudioIPCClientConfiguration
    package let descriptorInvocation: IPCDescriptorInvocation
}

package struct IPCClientGlobalArguments: Sendable {
    package let configuration: AgentStudioIPCClientConfiguration
    package let methodArguments: [String]
    package let consumesTokenInput: Bool
    /// The endpoint came from the debug escrow file rather than a flag, the pane
    /// environment or runtime metadata. A stale escrow names a socket nobody is
    /// listening on, and that reads as "the debug app is gone", not as a
    /// transport fault the caller should decode.
    package let endpointCameFromDebugEscrow: Bool

    package init(
        configuration: AgentStudioIPCClientConfiguration,
        methodArguments: [String],
        consumesTokenInput: Bool,
        endpointCameFromDebugEscrow: Bool = false
    ) {
        self.configuration = configuration
        self.methodArguments = methodArguments
        self.consumesTokenInput = consumesTokenInput
        self.endpointCameFromDebugEscrow = endpointCameFromDebugEscrow
    }
}

package enum AgentStudioIPCClientArguments {
    package static func parseGlobal(
        _ arguments: [String],
        environment: [String: String],
        standardInputProvider: () throws -> Data
    ) throws -> IPCClientGlobalArguments {
        var index = 0
        var explicitSocketPath: String?
        var metadataURL: URL?
        var consumesTokenInput = false
        while index < arguments.count, arguments[index].hasPrefix("--") {
            let option = arguments[index]
            index += 1
            switch option {
            case "--socket":
                explicitSocketPath = try takeValue(arguments, index: &index)
            case "--metadata":
                metadataURL = URL(fileURLWithPath: try takeValue(arguments, index: &index))
            case "--token-stdin":
                guard !consumesTokenInput else { throw invalidArguments() }
                consumesTokenInput = true
            default:
                throw invalidArguments()
            }
        }
        guard index < arguments.count else { throw invalidArguments() }
        let methodArguments = Array(arguments[index...])
        if let verb = methodArguments.first.flatMap(PaneCLIVerb.init(rawValue:)),
            PaneSessionReportingPolicy.isBackgroundSession(environment: environment)
        {
            switch verb {
            case .line, .title, .notify, .ask: throw PaneCLICommandFailure.backgroundSession
            case .withdraw, .answers, .pane: break
            }
        }
        guard !(consumesTokenInput && methodArguments.dropFirst().first == "--stdin") else {
            throw invalidArguments()
        }
        let debugEscrowCredential = try AgentStudioIPCClientDiscovery.debugEscrowCredential(
            explicitSocketPath: explicitSocketPath, environment: environment, metadataURL: metadataURL
        )
        let socket =
            try debugEscrowCredential?.socketPath
            ?? AgentStudioIPCClientDiscovery.socketPath(
                explicitSocketPath: explicitSocketPath, environment: environment, metadataURL: metadataURL
            )
        let token: String?
        if consumesTokenInput {
            guard
                let value = String(data: try standardInputProvider(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { throw invalidArguments() }
            token = value
        } else {
            token = environment["AGENTSTUDIO_PANE_TOKEN"] ?? debugEscrowCredential?.token
        }
        return IPCClientGlobalArguments(
            configuration: .init(socketPath: socket, authToken: token),
            methodArguments: methodArguments, consumesTokenInput: consumesTokenInput,
            endpointCameFromDebugEscrow: debugEscrowCredential != nil
        )
    }

    package static func parse(
        _ arguments: [String],
        descriptors: [IPCAnyMethodDescriptor],
        environment: [String: String],
        correlationIDGenerator: @Sendable () -> UUID,
        standardInputProvider: () throws -> Data
    ) throws -> AgentStudioIPCClientInvocation {
        let global = try parseGlobal(arguments, environment: environment, standardInputProvider: standardInputProvider)
        return try parseMethod(
            global, descriptors: descriptors, correlationIDGenerator: correlationIDGenerator,
            standardInputProvider: standardInputProvider
        )
    }

    package static func parseMethod(
        _ global: IPCClientGlobalArguments,
        descriptors: [IPCAnyMethodDescriptor],
        correlationIDGenerator: @Sendable () -> UUID,
        standardInputProvider: () throws -> Data
    ) throws -> AgentStudioIPCClientInvocation {
        if global.methodArguments == ["auth.login"], let token = global.configuration.authToken,
            let descriptor = descriptors.first(where: { $0.metadata.name == "auth.login" })
        {
            return try AgentStudioIPCClientInvocation(
                configuration: global.configuration,
                descriptorInvocation: IPCDescriptorInvocation(
                    descriptor: descriptor,
                    normalizedParameters: descriptor.normalizeParameters(
                        JSONEncoder().encode(IPCAuthLoginParams(token: token))),
                    presentation: .tooling
                )
            )
        }
        if global.methodArguments.first == "auth.login", global.methodArguments != ["auth.login", "--stdin"] {
            throw invalidArguments()
        }
        let readsMethodInput =
            descriptors.contains { $0.metadata.name == global.methodArguments.first }
            && global.methodArguments.dropFirst().first == "--stdin"
        guard !(global.consumesTokenInput && readsMethodInput) else { throw invalidArguments() }
        let input = try readsMethodInput ? standardInputProvider() : nil
        return try AgentStudioIPCClientInvocation(
            configuration: global.configuration,
            descriptorInvocation: IPCDescriptorInvocationParser.parse(
                global.methodArguments, descriptors: descriptors, correlationIDGenerator: correlationIDGenerator,
                standardInput: input
            )
        )
    }

    private static func takeValue(_ arguments: [String], index: inout Int) throws -> String {
        guard index < arguments.count else { throw invalidArguments() }
        defer { index += 1 }
        return arguments[index]
    }

    private static func invalidArguments() -> AgentStudioIPCClientError {
        AgentStudioIPCClientError(reason: .invalidArguments)
    }
}
