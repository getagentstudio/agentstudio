import AgentStudioProgrammaticControl
import Foundation

/// Parses only the compiled raw envelope, never the app's command arguments.
enum IPCCommandCLIInvocationParser {
    static func parse(
        global: IPCClientGlobalArguments, descriptor: IPCAnyMethodDescriptor,
        readInput: () -> Data, correlationIDGenerator: @Sendable () -> UUID
    ) throws -> IPCDescriptorInvocation {
        let arguments = Array(global.methodArguments.dropFirst())
        if arguments.first == "--json" || arguments.first == "--stdin" {
            return try AgentStudioIPCClientArguments.parseMethod(
                global, descriptors: [descriptor], correlationIDGenerator: correlationIDGenerator,
                standardInputProvider: readInput
            ).descriptorInvocation
        }
        var commandId: String?
        var correlationId: UUID?
        var raw: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw invalidArguments(field: "$", expected: "an option value") }
            let value = arguments[index + 1]
            switch option {
            case "--command-id":
                guard commandId == nil, !value.isEmpty else {
                    throw invalidArguments(field: "$.commandId", expected: "one nonempty command identifier")
                }
                commandId = value
            case "--correlation-id":
                guard correlationId == nil, let parsed = UUID(uuidString: value) else {
                    throw invalidArguments(field: "$.correlationId", expected: "one UUID")
                }
                correlationId = parsed
            case "--arg":
                guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                    throw invalidArguments(field: "$.arguments", expected: "key=value")
                }
                let key = String(value[..<separator])
                guard raw[key] == nil else {
                    throw invalidArguments(field: "$.arguments.\(key)", expected: "one value per key")
                }
                raw[key] = String(value[value.index(after: separator)...])
            default: throw invalidArguments(field: "$", expected: "--command-id, --correlation-id or --arg key=value")
            }
            index += 2
        }
        guard let commandId else { throw invalidArguments(field: "$.commandId", expected: "a command identifier") }
        let request = IPCRawCommandExecutionRequest(
            commandId: .init(rawValue: commandId), correlationId: correlationId ?? correlationIDGenerator(),
            arguments: raw)
        return try IPCDescriptorInvocation(
            descriptor: descriptor,
            normalizedParameters: descriptor.normalizeParameters(JSONEncoder().encode(request)), presentation: .tooling)
    }

    private static func invalidArguments(field: String, expected: String) -> IPCDescriptorInvocationError {
        .init(reason: .invalidValue, fieldPath: field, expected: expected)
    }
}
