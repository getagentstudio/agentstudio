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

/// The accepted auth.login method forms and where each obtains its parameters.
/// Global credential resolution remains owned by parseGlobal.
enum IPCAuthLoginMethodSyntax: CaseIterable {
    case resolvedCredential
    case jsonStandardInput

    static let methodName = "auth.login"

    var methodArguments: [String] {
        switch self {
        case .resolvedCredential: [Self.methodName]
        case .jsonStandardInput: [Self.methodName, "--stdin"]
        }
    }

    var commandLine: String { "agentstudio " + methodArguments.joined(separator: " ") }

    var inputDescription: String {
        switch self {
        case .resolvedCredential:
            "\(commandLine) uses the resolved credential: the pane's inherited token, or a raw token from agentstudio --token-stdin \(Self.methodName)."
        case .jsonStandardInput:
            "\(commandLine) reads the JSON parameter object from standard input."
        }
    }

    init?(arguments: [String]) {
        guard let syntax = Self.allCases.first(where: { $0.methodArguments == arguments }) else { return nil }
        self = syntax
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
        if let method = methodArguments.first, PaneSessionReportingPolicy.isPaneReportingMethod(method),
            PaneSessionReportingPolicy.isBackgroundSession(environment: environment)
        {
            throw PaneCLICommandFailure.backgroundSession
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
        if global.methodArguments.first == IPCAuthLoginMethodSyntax.methodName {
            guard let syntax = IPCAuthLoginMethodSyntax(arguments: global.methodArguments) else {
                throw invalidArguments()
            }
            switch syntax {
            case .resolvedCredential:
                guard let token = global.configuration.authToken,
                    let descriptor = descriptors.first(where: {
                        $0.metadata.name == IPCAuthLoginMethodSyntax.methodName
                    })
                else { throw invalidArguments() }
                return try AgentStudioIPCClientInvocation(
                    configuration: global.configuration,
                    descriptorInvocation: IPCDescriptorInvocation(
                        descriptor: descriptor,
                        normalizedParameters: descriptor.normalizeParameters(
                            JSONEncoder().encode(IPCAuthLoginParams(token: token))),
                        presentation: .tooling))
            case .jsonStandardInput:
                break
            }
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
